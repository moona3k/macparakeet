import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

@MainActor
final class DictationLiveTranslatorTests: XCTestCase {
    func testChangingTextExtendsDebounceAndUnchangedTextDoesNot() async throws {
        let clock = DictationTranslationTestClock()
        let provider = DictationTranslationProbe()
        let translator = DictationLiveTranslator(now: { clock.now }, sleep: { await clock.sleep($0) })
        translator.settingsProvider = { DictationTranslationSettings(language: .german, output: .translation) }
        translator.translatorProvider = { provider }
        translator.update("First")
        await waitFor { clock.waits.count == 1 }

        clock.now = clock.now.advanced(by: .milliseconds(300))
        translator.update("First second")
        clock.now = clock.now.advanced(by: .milliseconds(100))
        translator.update("First second")
        clock.now = clock.now.advanced(by: .milliseconds(50))
        clock.resume(0)
        await waitFor { clock.waits.count == 2 }
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(clock.waits.last, .milliseconds(300))

        clock.now = clock.now.advanced(by: .milliseconds(300))
        clock.resume(1)
        await waitFor { provider.requests.count == 1 }
        XCTAssertEqual(provider.requests, ["First second"])
        provider.finish(0)
        translator.reset()
    }

    func testResetRevokesNoncooperativeProviderWithoutClearingReplacement() async {
        let provider = DictationTranslationProbe()
        let translator = DictationLiveTranslator(debounce: .zero)
        translator.settingsProvider = { DictationTranslationSettings(language: .german, output: .translation) }
        translator.translatorProvider = { provider }
        var output: [String] = []
        translator.onTranslation = { text, _ in output.append(text) }
        translator.update("Old")
        await waitFor { provider.requests.count == 1 }
        translator.reset()
        translator.update("New")
        await waitFor { provider.requests.count == 2 }
        provider.finish(0)
        await waitFor { provider.returned.contains(0) }
        XCTAssertTrue(output.isEmpty)
        provider.finish(1)
        await waitFor { output == ["translated:New"] }
        translator.reset()
    }

    func testLanguageChangeDuringRequestRetranslatesSameSource() async {
        let provider = DictationTranslationProbe()
        let translator = DictationLiveTranslator(debounce: .zero)
        var language = TranslationLanguage.german
        translator.settingsProvider = { DictationTranslationSettings(language: language, output: .translation) }
        translator.translatorProvider = { provider }
        var output: [TranslationLanguage] = []
        translator.onTranslation = { _, language in output.append(language) }
        translator.update("Same words")
        await waitFor { provider.requests.count == 1 }
        language = .persian
        provider.finish(0)
        await waitFor { provider.requests.count == 2 }
        XCTAssertTrue(output.isEmpty)
        XCTAssertEqual(provider.languages, [.german, .persian])
        provider.finish(1)
        await waitFor { output == [.persian] }
        translator.reset()
    }

    private func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition())
    }
}

@MainActor
final class DictationTranslationProbe: TranscriptTranslating {
    private(set) var requests: [String] = []
    private(set) var languages: [TranslationLanguage] = []
    private(set) var returned: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<[TranslatedSegment], Never>] = [:]

    func translate(
        _ segments: [TranslationSourceSegment], to language: TranslationLanguage,
        onBatch: @Sendable ([TranslatedSegment]) async -> Void
    ) async throws -> [TranslatedSegment] {
        let index = requests.count
        requests.append(segments.map(\.text).joined())
        languages.append(language)
        defer { returned.insert(index) }
        return await withCheckedContinuation { continuations[index] = $0 }
    }

    func finish(_ index: Int) {
        continuations.removeValue(forKey: index)?.resume(
            returning: [TranslatedSegment(text: "translated:" + requests[index])])
    }
}

@MainActor
private final class DictationTranslationTestClock {
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
