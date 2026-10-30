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

/// Deliberately ignores cancellation so tests control when an obsolete provider
/// returns or sends progress. No wall-clock sleeps drive the interleavings.
@MainActor
private final class ControlledTranscriptTranslator: TranscriptTranslating {
    private enum Action: Sendable {
        case progress([TranslatedSegment], CheckedContinuation<Void, Never>)
        case finish(Result<[TranslatedSegment], Error>)
    }

    private struct Pending {
        var actions: [Action] = []
        var waiter: CheckedContinuation<Action, Never>?
    }

    private var pending: [Int: Pending] = [:]
    private(set) var requestCount = 0
    private(set) var returnedRequests: Set<Int> = []

    func translate(
        _ segments: [TranslationSourceSegment],
        to language: TranslationLanguage,
        onBatch: @Sendable ([TranslatedSegment]) async -> Void
    ) async throws -> [TranslatedSegment] {
        let request = requestCount
        requestCount += 1
        pending[request] = Pending()
        defer {
            pending[request] = nil
            returnedRequests.insert(request)
        }
        while true {
            switch await nextAction(request) {
            case .progress(let segments, let acknowledged):
                await onBatch(segments)
                acknowledged.resume()
            case .finish(let result):
                return try result.get()
            }
        }
    }

    private func nextAction(_ request: Int) async -> Action {
        if pending[request]?.actions.isEmpty == false {
            return pending[request]!.actions.removeFirst()
        }
        return await withCheckedContinuation { pending[request]?.waiter = $0 }
    }

    private func send(_ action: Action, request: Int) {
        if let waiter = pending[request]?.waiter {
            pending[request]?.waiter = nil
            waiter.resume(returning: action)
        } else {
            pending[request]?.actions.append(action)
        }
    }

    func emit(_ segments: [TranslatedSegment], request: Int) async {
        guard pending[request] != nil else {
            XCTFail("No pending translation request \(request)")
            return
        }
        await withCheckedContinuation { acknowledged in
            send(.progress(segments, acknowledged), request: request)
        }
    }

    func finish(_ request: Int, result: Result<[TranslatedSegment], Error>) {
        send(.finish(result), request: request)
    }
}

private struct TranslatorFailure: LocalizedError {
    var errorDescription: String? { "provider unavailable" }
}

@MainActor
private final class LiveTranslationTestClock {
    var now = ContinuousClock.now
    private(set) var waits: [Duration] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func sleep(_ duration: Duration) async {
        let index = waits.count
        waits.append(duration)
        await withCheckedContinuation { continuations[index] = $0 }
    }

    func resume(_ index: Int) { continuations.removeValue(forKey: index)?.resume() }
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
        XCTAssertNil(saved.modelName, "Configured model names do not prove which model translated every batch")
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

    func testSubtitleSelectionRejectsStaleTimingAndKeepsSavedTranslation() async throws {
        var transcription = try makeTranscription(text: "Hello there.")
        transcription.wordTimestamps = [
            WordTimestamp(word: "Hello there.", startMs: 0, endMs: 1_000, confidence: 1, speakerId: "speaker-1")
        ]
        viewModel.load(transcription: transcription)
        viewModel.translate(to: .german)
        await waitUntil { self.viewModel.translation(for: .german) != nil }
        let saved = try XCTUnwrap(viewModel.subtitleTranslation(for: .german))
        let originalFingerprint = viewModel.currentSourceHash

        transcription.wordTimestamps?[0].endMs = 2_000
        viewModel.load(transcription: transcription)

        XCTAssertNotEqual(viewModel.currentSourceHash, originalFingerprint)
        XCTAssertNil(
            viewModel.subtitleTranslation(for: .german), "Old cues must stop being selectable after timing changes")
        XCTAssertEqual(viewModel.translation(for: .german), saved, "Stale translations remain durable and readable")
        XCTAssertEqual(try repo.fetch(transcriptionId: transcription.id, languageCode: "de"), saved)

        viewModel.translate(to: .german)
        await waitUntil { self.viewModel.subtitleTranslation(for: .german) != nil }
        XCTAssertEqual(viewModel.subtitleTranslation(for: .german)?.segments.first?.endMs, 2_000)
    }

    func testSubtitleSelectionRejectsCurrentUntimedTranslation() async throws {
        viewModel.load(transcription: try makeTranscription())
        XCTAssertNil(viewModel.subtitleTranslation(for: .german))
        viewModel.translate(to: .german)
        await waitUntil { self.viewModel.translation(for: .german) != nil }

        let saved = try XCTUnwrap(viewModel.translation(for: .german))
        XCTAssertFalse(viewModel.isStale(saved))
        XCTAssertNil(viewModel.subtitleTranslation(for: .german))
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

    func testCancelledProviderReturningSuccessDoesNotSave() async throws {
        let controlled = ControlledTranscriptTranslator()
        viewModel.updateTranslator(controlled)
        let transcription = try makeTranscription(text: "Original text.")
        viewModel.load(transcription: transcription)
        viewModel.translate(to: .german)
        await waitUntil { controlled.requestCount == 1 }

        viewModel.cancel(.german)
        controlled.finish(0, result: .success([TranslatedSegment(text: "Obsolete result")]))
        await waitUntil { controlled.returnedRequests.contains(0) }

        XCTAssertNil(viewModel.job(for: .german))
        XCTAssertFalse(viewModel.hasTranslationTabs)
        XCTAssertTrue(try repo.fetchAll(transcriptionId: transcription.id).isEmpty)
    }

    func testCancelledJobCannotPublishProgressOrClearOrFailItsReplacement() async throws {
        for oldFails in [false, true] {
            let controlled = ControlledTranscriptTranslator()
            viewModel.updateTranslator(controlled)
            let transcription = try makeTranscription(text: "Replacement source.")
            viewModel.load(transcription: transcription)
            viewModel.translate(to: .german)
            await waitUntil { controlled.requestCount == 1 }
            viewModel.cancel(.german)
            viewModel.translate(to: .german)
            await waitUntil { controlled.requestCount == 2 }

            await controlled.emit([TranslatedSegment(text: "Old progress")], request: 0)
            XCTAssertEqual(viewModel.job(for: .german)?.segments, [])
            await controlled.emit([TranslatedSegment(text: "New progress")], request: 1)
            XCTAssertEqual(viewModel.job(for: .german)?.segments.map(\.text), ["New progress"])

            controlled.finish(
                0,
                result: oldFails ? .failure(TranslatorFailure()) : .success([TranslatedSegment(text: "Old result")])
            )
            await waitUntil { controlled.returnedRequests.contains(0) }
            XCTAssertTrue(viewModel.isTranslating(.german))
            XCTAssertNil(viewModel.job(for: .german)?.errorMessage)
            XCTAssertEqual(viewModel.job(for: .german)?.segments.map(\.text), ["New progress"])
            XCTAssertTrue(try repo.fetchAll(transcriptionId: transcription.id).isEmpty)

            controlled.finish(1, result: .success([TranslatedSegment(text: "New result")]))
            await waitUntil { self.viewModel.translation(for: .german) != nil }
            let saved = try XCTUnwrap(repo.fetch(transcriptionId: transcription.id, languageCode: "de"))
            XCTAssertEqual(saved.segments.map(\.text), ["New result"])
            XCTAssertNil(viewModel.job(for: .german))
        }
    }

    func testPartialFailurePreservesSavedTranslationAndRetryCanReplaceIt() async throws {
        let transcription = try makeTranscription(text: "Source text.")
        viewModel.load(transcription: transcription)
        viewModel.translate(to: .german)
        await waitUntil { self.viewModel.translation(for: .german) != nil }
        let original = try XCTUnwrap(viewModel.translation(for: .german))
        let controlled = ControlledTranscriptTranslator()
        viewModel.updateTranslator(controlled)
        viewModel.translate(to: .german)
        await waitUntil { controlled.requestCount == 1 }
        await controlled.emit([TranslatedSegment(text: "Partial result")], request: 0)
        controlled.finish(0, result: .failure(TranslatorFailure()))
        await waitUntil { self.viewModel.job(for: .german)?.errorMessage != nil }

        XCTAssertEqual(viewModel.job(for: .german)?.segments.map(\.text), ["Partial result"])
        XCTAssertEqual(try repo.fetch(transcriptionId: transcription.id, languageCode: "de")?.id, original.id)
        XCTAssertEqual(viewModel.translation(for: .german)?.segments, original.segments)
        XCTAssertFalse(viewModel.isTranslating(.german))

        viewModel.translate(to: .german)
        await waitUntil { controlled.requestCount == 2 }
        XCTAssertNil(viewModel.job(for: .german)?.errorMessage)
        controlled.finish(1, result: .success([TranslatedSegment(text: "Complete replacement")]))
        await waitUntil { self.viewModel.job(for: .german) == nil }
        let saved = try repo.fetchAll(transcriptionId: transcription.id)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.segments.map(\.text), ["Complete replacement"])
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
            content: "## Summary\n\n- First point",
            inferenceSettingsSnapshot: PromptInferenceSettings(temperature: 0.5, maxTokens: 600),
            providerSnapshot: "original-provider",
            modelSnapshot: "original-model"
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
        XCTAssertNil(translated.providerSnapshot)
        XCTAssertNil(translated.modelSnapshot)
        XCTAssertNil(translated.inferenceSettingsSnapshot)
        let retained = try XCTUnwrap(saved.first { $0.id == original.id })
        XCTAssertEqual(retained.content, original.content)
        XCTAssertEqual(retained.providerSnapshot, original.providerSnapshot)
        XCTAssertEqual(retained.modelSnapshot, original.modelSnapshot)
        XCTAssertEqual(retained.inferenceSettingsSnapshot, original.inferenceSettingsSnapshot)
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

    func testSpeedChangeWakesWaitingWorkerAndPreservesSettledLines() async {
        let clock = LiveTranslationTestClock()
        let viewModel = LiveTranslationViewModel(
            defaults: defaults, now: { clock.now }, sleepForSettle: { await clock.sleep($0) })
        viewModel.updateTranslator(translator)
        viewModel.language = .german
        viewModel.update(lines: [line("1", "Settled"), line("2", "Newest")])
        await waitUntil { clock.waits.count == 1 }
        XCTAssertEqual(viewModel.translation(forLineID: "1"), "de:Settled")
        clock.now = clock.now.advanced(by: .milliseconds(500))
        viewModel.speed = .fast
        // The new 400ms deadline already elapsed; no release of the obsolete
        // 1500ms sleep is needed for this request to finish.
        await waitUntil { viewModel.translation(forLineID: "2") == "de:Newest" }
        XCTAssertEqual(translator.requests, [["Settled"], ["Newest"]])
        clock.resume(0)
        await Task.yield()
        XCTAssertEqual(viewModel.translation(forLineID: "1"), "de:Settled")
        viewModel.reset()
    }

    func testUnchangedRouteRefreshPreservesSettledTranslations() async {
        let viewModel = makeViewModel()
        let route = LLMModelSelectionRoute(
            config: LLMProviderConfig(
                id: .openai, baseURL: URL(string: "https://example.invalid")!, apiKey: nil,
                modelName: "first", isLocal: false), isOverride: false)
        viewModel.updateTranslator(translator, route: route)
        viewModel.language = .german
        viewModel.update(lines: [line("1", "Hello")])
        await waitUntil { viewModel.translation(forLineID: "1") != nil }
        viewModel.updateTranslator(translator, route: route)
        await Task.yield()
        XCTAssertEqual(translator.requests.count, 1, "Showing the same window must not repeat settled requests")
        XCTAssertEqual(viewModel.translation(forLineID: "1"), "de:Hello")

        let changed = LLMModelSelectionRoute(
            config: LLMProviderConfig(
                id: .openai, baseURL: route.config.baseURL, apiKey: nil, modelName: "second", isLocal: false),
            isOverride: false)
        viewModel.updateTranslator(translator, route: changed)
        await waitUntil { self.translator.requests.count == 2 }
        viewModel.updateTranslator(nil, route: changed)
        XCTAssertFalse(viewModel.isActive, "Availability changes must revoke the same route")
        XCTAssertNil(viewModel.translation(forLineID: "1"))
        viewModel.updateTranslator(translator, route: changed)
        await waitUntil { self.translator.requests.count == 3 }
        viewModel.reset()
    }

    func testObsoleteWorkerCannotPublishOrClearReplacementState() async {
        let controlled = ControlledTranscriptTranslator()
        let viewModel = makeViewModel()
        viewModel.updateTranslator(controlled)
        viewModel.language = .german
        viewModel.update(lines: [line("1", "Hello")])
        await waitUntil { controlled.requestCount == 1 }
        viewModel.language = .persian
        await waitUntil { controlled.requestCount == 2 }
        controlled.finish(0, result: .success([TranslatedSegment(text: "old")]))
        await waitUntil { controlled.returnedRequests.contains(0) }
        XCTAssertNil(viewModel.translation(forLineID: "1"))
        XCTAssertTrue(viewModel.isTranslating, "An obsolete worker cannot clear the replacement's progress")
        controlled.finish(1, result: .success([TranslatedSegment(text: "new")]))
        await waitUntil { viewModel.translation(forLineID: "1") == "new" }
        viewModel.reset()
    }

    func testStopRetainsEntriesAndBlocksEveryRestartUntilNewSession() async {
        let controlled = ControlledTranscriptTranslator()
        let viewModel = makeViewModel()
        viewModel.updateTranslator(controlled)
        viewModel.language = .german
        viewModel.update(lines: [line("1", "Saved")])
        await waitUntil { controlled.requestCount == 1 }
        controlled.finish(0, result: .success([TranslatedSegment(text: "Gespeichert")]))
        await waitUntil { viewModel.translation(forLineID: "1") == "Gespeichert" }
        viewModel.update(lines: [line("1", "Saved"), line("2", "Pending")])
        await waitUntil { controlled.requestCount == 2 }

        viewModel.stop()
        XCTAssertEqual(viewModel.translation(forLineID: "1"), "Gespeichert")
        viewModel.speed = .fast
        viewModel.retry()
        viewModel.updateTranslator(controlled)
        viewModel.language = .persian
        XCTAssertNil(viewModel.translation(forLineID: "1"), "Retained German must not be labelled Persian")
        viewModel.language = .german
        viewModel.update(lines: [line("1", "Saved"), line("2", "Pending"), line("3", "Later")])
        controlled.finish(1, result: .success([TranslatedSegment(text: "Late")]))
        await waitUntil { controlled.returnedRequests.contains(1) }
        XCTAssertEqual(controlled.requestCount, 2)
        XCTAssertFalse(viewModel.isTranslating)
        XCTAssertNil(viewModel.translation(forLineID: "2"))
        XCTAssertEqual(viewModel.translation(forLineID: "1"), "Gespeichert")

        viewModel.start()
        XCTAssertNil(viewModel.translation(forLineID: "1"))
        viewModel.update(lines: [line("new", "New session")])
        await waitUntil { controlled.requestCount == 3 }
        controlled.finish(2, result: .success([TranslatedSegment(text: "Neu")]))
        await waitUntil { viewModel.translation(forLineID: "new") == "Neu" }
        viewModel.stop()
    }

    func testCaptionStopAndClearKeepTranslationStopped() async {
        let translation = makeViewModel()
        let captions = LiveCaptionsViewModel(
            sessionFactory: { nil }, liveTranslation: translation, defaults: defaults)
        translation.language = .german
        translation.start()
        translation.update(lines: [line("1", "Saved")])
        await waitUntil { translation.translation(forLineID: "1") == "de:Saved" }
        captions.stop()
        XCTAssertEqual(translation.translation(forLineID: "1"), "de:Saved")
        captions.clear()
        translation.update(lines: [line("2", "Must wait")])
        translation.retry()
        await Task.yield()
        XCTAssertEqual(translator.requests.count, 1)
        XCTAssertNil(translation.translation(forLineID: "2"))
        captions.start()  // No session is available; translation must stay stopped.
        translation.retry()
        await Task.yield()
        XCTAssertEqual(translator.requests.count, 1)
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
