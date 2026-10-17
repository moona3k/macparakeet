import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private final class MockTranscriptTranslator: TranscriptTranslating, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [[String]] = []
    private var _error: Error?
    private var _failuresRemaining = 0

    var requests: [[String]] {
        lock.withLock { _requests }
    }

    func failAlways(with error: Error) {
        lock.withLock { _error = error }
    }

    func translate(
        _ segments: [TranslationSourceSegment],
        to language: TranslationLanguage,
        onBatch: @Sendable ([TranslatedSegment]) async -> Void
    ) async throws -> [TranslatedSegment] {
        let error = lock.withLock { () -> Error? in
            _requests.append(segments.map(\.text))
            return _error
        }
        if let error { throw error }
        let translated = segments.map {
            TranslatedSegment(
                startMs: $0.startMs,
                endMs: $0.endMs,
                speakerId: $0.speakerId,
                text: "\(language.rawValue):\($0.text)"
            )
        }
        await onBatch(translated)
        return translated
    }
}

private struct TranslatorFailure: LocalizedError {
    var errorDescription: String? { "provider unavailable" }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            XCTFail("Timed out waiting for condition", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
final class TranscriptTranslationViewModelTests: XCTestCase {
    private var translator: MockTranscriptTranslator!
    private var repo: TranscriptTranslationRepository!
    private var transcriptionRepo: TranscriptionRepository!
    private var viewModel: TranscriptTranslationViewModel!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = TranscriptTranslationRepository(dbQueue: manager.dbQueue)
        transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
        translator = MockTranscriptTranslator()
        viewModel = TranscriptTranslationViewModel()
        viewModel.configure(translator: translator, repository: repo, modelNameProvider: { "test-model" })
    }

    private func makeTranscription(text: String = "Hello there.\nHow are you?") throws -> Transcription {
        let transcription = Transcription(fileName: "talk", rawTranscript: text, status: .completed)
        try transcriptionRepo.save(transcription)
        return transcription
    }

    func testTranslateSavesTranslationAndExposesTab() async throws {
        let transcription = try makeTranscription()
        var changes: [Bool] = []
        viewModel.onTranslationsChanged = { _, hasTabs in changes.append(hasTabs) }
        viewModel.load(transcription: transcription)
        XCTAssertFalse(viewModel.hasTranslationTabs)

        viewModel.translate(to: .persian)
        XCTAssertEqual(viewModel.tabLanguages, [.persian], "A running job has a tab immediately")
        await waitUntil { self.viewModel.translation(for: .persian) != nil }

        let saved = try XCTUnwrap(repo.fetch(transcriptionId: transcription.id, languageCode: "fa"))
        XCTAssertEqual(saved.segments.map(\.text), ["fa:Hello there.", "fa:How are you?"])
        XCTAssertEqual(saved.modelName, "test-model")
        XCTAssertNil(viewModel.job(for: .persian))
        XCTAssertFalse(viewModel.isStale(saved))
        XCTAssertEqual(changes.last, true)
    }

    func testFailureKeepsJobWithErrorUntilDismissed() async throws {
        translator.failAlways(with: TranslatorFailure())
        viewModel.load(transcription: try makeTranscription())

        viewModel.translate(to: .german)
        await waitUntil { self.viewModel.job(for: .german)?.errorMessage != nil }

        XCTAssertEqual(viewModel.job(for: .german)?.errorMessage, "provider unavailable")
        XCTAssertFalse(viewModel.isTranslating(.german))
        XCTAssertNil(viewModel.translation(for: .german))

        viewModel.cancel(.german)
        XCTAssertNil(viewModel.job(for: .german))
        XCTAssertFalse(viewModel.hasTranslationTabs)
    }

    func testTranslationBecomesStaleWhenTranscriptTextChanges() async throws {
        var transcription = try makeTranscription()
        viewModel.load(transcription: transcription)
        viewModel.translate(to: .english)
        await waitUntil { self.viewModel.translation(for: .english) != nil }

        transcription.cleanTranscript = "Completely different text."
        transcription.isTranscriptEdited = true
        viewModel.load(transcription: transcription)

        let saved = try XCTUnwrap(viewModel.translation(for: .english))
        XCTAssertTrue(viewModel.isStale(saved))
    }

    func testDeleteRemovesSavedTranslation() async throws {
        let transcription = try makeTranscription()
        viewModel.load(transcription: transcription)
        viewModel.translate(to: .german)
        await waitUntil { self.viewModel.translation(for: .german) != nil }

        viewModel.delete(.german)

        XCTAssertNil(viewModel.translation(for: .german))
        XCTAssertTrue(try repo.fetchAll(transcriptionId: transcription.id).isEmpty)
    }

    func testJobFinishingForAnotherTranscriptStillSaves() async throws {
        let first = try makeTranscription(text: "First transcript.")
        let second = try makeTranscription(text: "Second transcript.")
        viewModel.load(transcription: first)
        viewModel.translate(to: .german)
        viewModel.load(transcription: second)

        await waitUntil {
            (try? self.repo.fetch(transcriptionId: first.id, languageCode: "de")) != nil
        }
        XCTAssertTrue(viewModel.translations.isEmpty, "The other transcript's translation must not leak in")
    }

    func testTranslateWithoutTranslatorDoesNothing() throws {
        viewModel.updateTranslator(nil)
        viewModel.load(transcription: try makeTranscription())

        viewModel.translate(to: .german)

        XCTAssertFalse(viewModel.canTranslate)
        XCTAssertNil(viewModel.job(for: .german))
    }
}

@MainActor
final class PromptResultTranslationTests: XCTestCase {
    func testTranslatingAResultSavesANewResultAndKeepsTheOriginal() async throws {
        let manager = try DatabaseManager()
        let resultRepo = PromptResultRepository(dbQueue: manager.dbQueue)
        let transcription = Transcription(fileName: "talk", rawTranscript: "Hello.", status: .completed)
        try TranscriptionRepository(dbQueue: manager.dbQueue).save(transcription)
        let original = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Summary",
            promptContent: "Summarize.",
            content: "## Summary\n\n- First point"
        )
        try resultRepo.save(original)

        let viewModel = PromptResultsViewModel()
        viewModel.configure(
            llmService: nil,
            promptRepo: PromptRepository(dbQueue: manager.dbQueue),
            promptResultRepo: resultRepo
        )
        viewModel.loadPromptResults(transcriptionId: transcription.id)
        XCTAssertFalse(viewModel.canTranslatePromptResults)
        viewModel.updateResultTranslator(MockTranscriptTranslator())
        var translatedID: UUID?
        viewModel.onPromptResultTranslated = { _, id in translatedID = id }

        viewModel.translatePromptResult(original, to: .persian)
        XCTAssertTrue(viewModel.translatingPromptResultIDs.contains(original.id))
        await waitUntil { translatedID != nil }

        let saved = try resultRepo.fetchAll(transcriptionId: transcription.id)
        XCTAssertEqual(saved.count, 2)
        let translated = try XCTUnwrap(saved.first { $0.id == translatedID })
        XCTAssertEqual(translated.promptName, "Summary · Persian")
        XCTAssertEqual(translated.content, "fa:## Summary\n\nfa:- First point")
        XCTAssertNil(translated.promptId)
        XCTAssertEqual(saved.first { $0.id == original.id }?.content, original.content)
        XCTAssertTrue(viewModel.translatingPromptResultIDs.isEmpty)
        XCTAssertEqual(viewModel.promptResults.first?.id, translatedID)
    }

    func testFailedResultTranslationReportsErrorAndSavesNothing() async throws {
        let manager = try DatabaseManager()
        let resultRepo = PromptResultRepository(dbQueue: manager.dbQueue)
        let transcription = Transcription(fileName: "talk", rawTranscript: "Hello.", status: .completed)
        try TranscriptionRepository(dbQueue: manager.dbQueue).save(transcription)
        let original = PromptResult(
            transcriptionId: transcription.id, promptName: "Summary", promptContent: "Summarize.", content: "Text")
        try resultRepo.save(original)

        let translator = MockTranscriptTranslator()
        translator.failAlways(with: TranslatorFailure())
        let viewModel = PromptResultsViewModel()
        viewModel.configure(
            llmService: nil, promptRepo: PromptRepository(dbQueue: manager.dbQueue), promptResultRepo: resultRepo)
        viewModel.updateResultTranslator(translator)

        viewModel.translatePromptResult(original, to: .german)
        await waitUntil { viewModel.promptResultTranslationErrors[original.id] != nil }

        XCTAssertEqual(viewModel.promptResultTranslationErrors[original.id], "provider unavailable")
        XCTAssertEqual(try resultRepo.fetchAll(transcriptionId: transcription.id).count, 1)
    }
}

@MainActor
final class LiveTranslationViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var translator: MockTranscriptTranslator!

    override func setUp() async throws {
        suiteName = "test.live-translation.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        translator = MockTranscriptTranslator()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeViewModel(settleDelay: Duration = .zero) -> LiveTranslationViewModel {
        let viewModel = LiveTranslationViewModel(
            defaults: defaults,
            settleDelay: settleDelay,
            retryDelay: .milliseconds(1)
        )
        viewModel.updateTranslator(translator)
        return viewModel
    }

    private func line(_ id: String, _ text: String) -> LiveTranslationViewModel.Line {
        .init(id: id, text: text)
    }

    func testOffByDefaultAndDoesNotCallTranslator() async {
        let viewModel = makeViewModel()
        viewModel.update(lines: [line("1", "Hello")])

        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(viewModel.language)
        XCTAssertFalse(viewModel.isActive)
        XCTAssertTrue(translator.requests.isEmpty)
        XCTAssertNil(viewModel.translation(forLineID: "1"))
    }

    func testTranslatesSettledLines() async {
        let viewModel = makeViewModel()
        viewModel.language = .german
        viewModel.update(lines: [line("1", "Hello"), line("2", "World")])

        await waitUntil { viewModel.translation(forLineID: "2") != nil }
        XCTAssertEqual(viewModel.translation(forLineID: "1"), "de:Hello")
        XCTAssertEqual(viewModel.translation(forLineID: "2"), "de:World")
    }

    func testNewestLineWaitsUntilItSettles() async {
        let viewModel = makeViewModel(settleDelay: .milliseconds(150))
        viewModel.language = .german
        viewModel.update(lines: [line("1", "Hello"), line("2", "Wor")])

        await waitUntil { viewModel.translation(forLineID: "1") != nil }
        XCTAssertNil(viewModel.translation(forLineID: "2"), "The still-changing line is not translated yet")

        await waitUntil { viewModel.translation(forLineID: "2") != nil }
        XCTAssertEqual(viewModel.translation(forLineID: "2"), "de:Wor")
    }

    func testChangedLineIsRetranslated() async {
        let viewModel = makeViewModel()
        viewModel.language = .english
        viewModel.update(lines: [line("1", "Hallo")])
        await waitUntil { viewModel.translation(forLineID: "1") == "en:Hallo" }

        viewModel.update(lines: [line("1", "Hallo Welt")])
        await waitUntil { viewModel.translation(forLineID: "1") == "en:Hallo Welt" }
    }

    func testSwitchingLanguageDropsOldTranslations() async {
        let viewModel = makeViewModel()
        viewModel.language = .german
        viewModel.update(lines: [line("1", "Hello")])
        await waitUntil { viewModel.translation(forLineID: "1") == "de:Hello" }

        viewModel.language = .persian
        await waitUntil { viewModel.translation(forLineID: "1") == "fa:Hello" }

        viewModel.language = nil
        XCTAssertNil(viewModel.translation(forLineID: "1"))
    }

    func testRepeatedFailuresPauseTranslationUntilRetry() async {
        translator.failAlways(with: TranslatorFailure())
        let viewModel = makeViewModel()
        viewModel.language = .german
        viewModel.update(lines: [line("1", "Hello")])

        await waitUntil { self.translator.requests.count == LiveTranslationViewModel.maxConsecutiveFailures }
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(translator.requests.count, LiveTranslationViewModel.maxConsecutiveFailures)
        XCTAssertEqual(viewModel.errorMessage, "provider unavailable")

        viewModel.update(lines: [line("1", "Hello"), line("2", "Again")])
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(
            translator.requests.count, LiveTranslationViewModel.maxConsecutiveFailures,
            "No further requests until the user retries"
        )
    }

    func testLanguageChoiceIsPersistedAndResetKeepsIt() async {
        let viewModel = makeViewModel()
        viewModel.language = .persian
        viewModel.update(lines: [line("1", "Hello")])
        await waitUntil { viewModel.translation(forLineID: "1") != nil }

        viewModel.reset()
        XCTAssertNil(viewModel.translation(forLineID: "1"))
        XCTAssertEqual(viewModel.language, .persian)
        XCTAssertEqual(makeViewModel().language, .persian)
    }

    func testDisplayModeAndSpeedArePersisted() {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.displayMode, .originalAndTranslation)
        XCTAssertEqual(viewModel.speed, .balanced)

        viewModel.displayMode = .translationOnly
        viewModel.speed = .fast

        let reloaded = makeViewModel()
        XCTAssertEqual(reloaded.displayMode, .translationOnly)
        XCTAssertEqual(reloaded.speed, .fast)
        XCTAssertLessThan(
            LiveTranslationViewModel.Speed.fast.settleDelay,
            LiveTranslationViewModel.Speed.balanced.settleDelay
        )
    }

    func testTranslationOnlyModeReplacesLineTextOnceTranslated() async {
        let panel = MeetingRecordingPanelViewModel()
        let translation = panel.liveTranslation
        let previousLanguage = translation.language
        let previousMode = translation.displayMode
        defer {
            translation.language = previousLanguage
            translation.displayMode = previousMode
        }
        translation.updateTranslator(translator)
        translation.language = .german
        translation.displayMode = .translationOnly

        panel.updatePreviewLines([
            MeetingRecordingPreviewLine(
                id: "1", timestamp: "0:01", speakerLabel: "Me", text: "Hello", source: .microphone),
            MeetingRecordingPreviewLine(
                id: "2", timestamp: "0:02", speakerLabel: "Me", text: "World", source: .microphone),
        ])
        XCTAssertEqual(panel.displayLines.first?.text, "Hello", "Original text shows until translated")

        await waitUntil { panel.displayLines.first?.text == "de:Hello" }
        XCTAssertNil(panel.displayLines.first?.translation)

        translation.displayMode = .originalAndTranslation
        XCTAssertEqual(panel.displayLines.first?.text, "Hello")
        XCTAssertEqual(panel.displayLines.first?.translation, "de:Hello")
    }
}
