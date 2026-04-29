import XCTest
@testable import MacParakeetCore
#if canImport(WhisperKit)
import WhisperKit
#endif

final class STTClientTests: XCTestCase {

    func testSTTResultCreation() {
        let words = [
            TimestampedWord(word: "Hello", startMs: 0, endMs: 500, confidence: 0.98),
            TimestampedWord(word: "world", startMs: 520, endMs: 1000, confidence: 0.95),
        ]
        let result = STTResult(text: "Hello world", words: words)

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.words.count, 2)
        XCTAssertEqual(result.words[0].word, "Hello")
        XCTAssertEqual(result.words[1].startMs, 520)
        XCTAssertNil(result.language)
    }

    func testSTTResultStoresDetectedLanguage() {
        let result = STTResult(text: "hello", language: "ko")
        XCTAssertEqual(result.language, "ko")
    }

    func testSTTResultEmptyWords() {
        let result = STTResult(text: "Hello")
        XCTAssertEqual(result.text, "Hello")
        XCTAssertTrue(result.words.isEmpty)
    }

    func testSpeechEnginePreferenceDefaultsToParakeet() {
        let suiteName = "com.macparakeet.tests.speech-engine.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(SpeechEnginePreference.current(defaults: defaults), .parakeet)
    }

    func testSpeechEnginePreferencePersistsWhisperLanguage() {
        let suiteName = "com.macparakeet.tests.whisper-language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SpeechEnginePreference.whisper.save(to: defaults)
        SpeechEnginePreference.saveWhisperDefaultLanguage("KO_kr", defaults: defaults)

        XCTAssertEqual(SpeechEnginePreference.current(defaults: defaults), .whisper)
        XCTAssertEqual(SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults), "ko")

        SpeechEnginePreference.saveWhisperDefaultLanguage("auto", defaults: defaults)
        XCTAssertNil(SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults))
    }

    func testWhisperTimestampMappingUsesMillisecondsAndProbability() {
        let word = WhisperEngine.makeTimestampedWord(
            word: "hello",
            startSeconds: 1.25,
            endSeconds: 2.5,
            probability: 0.42
        )

        XCTAssertEqual(word.word, "hello")
        XCTAssertEqual(word.startMs, 1250)
        XCTAssertEqual(word.endMs, 2500)
        XCTAssertEqual(word.confidence, 0.42, accuracy: 0.0001)
    }

    func testWhisperTimestampMappingClampsInvertedTiming() {
        let word = WhisperEngine.makeTimestampedWord(
            word: "hello",
            startSeconds: 2.92,
            endSeconds: 2.0,
            probability: 0.91
        )

        XCTAssertEqual(word.startMs, 2920)
        XCTAssertEqual(word.endMs, 2920)
    }

    func testWhisperDecodeOptionsForForcedLanguageUsesPrefillPrompt() {
        #if canImport(WhisperKit)
        let options = WhisperEngine.makeDecodingOptions(language: "KO_kr")

        XCTAssertEqual(options.language, "ko")
        XCTAssertTrue(options.usePrefillPrompt)
        XCTAssertFalse(options.detectLanguage)
        XCTAssertTrue(options.wordTimestamps)
        #endif
    }

    func testWhisperDecodeOptionsForAutoLanguageDetectsWithoutPrefillPrompt() {
        #if canImport(WhisperKit)
        let options = WhisperEngine.makeDecodingOptions(language: "auto")

        XCTAssertNil(options.language)
        XCTAssertFalse(options.usePrefillPrompt)
        XCTAssertTrue(options.detectLanguage)
        XCTAssertTrue(options.wordTimestamps)
        #endif
    }

    func testWhisperForcedLanguageFallbackOnlyRetriesEmptyResults() {
        #if canImport(WhisperKit)
        let empty = TranscriptionResult(text: "  \n", segments: [], language: "ko", timings: TranscriptionTimings())
        XCTAssertTrue(WhisperEngine.shouldRetryWithoutForcedLanguage(empty))

        let textOnly = TranscriptionResult(text: "hello", segments: [], language: "en", timings: TranscriptionTimings())
        XCTAssertFalse(WhisperEngine.shouldRetryWithoutForcedLanguage(textOnly))

        let withWords = TranscriptionResult(
            text: "",
            segments: [
                TranscriptionSegment(
                    text: "",
                    words: [WordTiming(word: "hello", tokens: [], start: 0, end: 0.5, probability: 0.9)]
                ),
            ],
            language: "en",
            timings: TranscriptionTimings()
        )
        XCTAssertFalse(WhisperEngine.shouldRetryWithoutForcedLanguage(withWords))
        #endif
    }

    func testWhisperModelVariantNormalization() {
        XCTAssertEqual(
            WhisperEngine.normalizeModelVariant("whisper-large-v3-v20240930-turbo"),
            "large-v3-v20240930_turbo"
        )
        XCTAssertEqual(
            WhisperEngine.normalizeModelVariant("whisper-large-v3-v20240930-turbo-632MB"),
            "large-v3-v20240930_turbo_632MB"
        )
        XCTAssertEqual(
            WhisperEngine.normalizeModelVariant("large-v3-v20240930_turbo_632MB"),
            "large-v3-v20240930_turbo_632MB"
        )
    }

    func testWhisperModelDownloadedDetectsNestedNormalizedFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelFolder = root
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-large-v3-v20240930_turbo_632MB", isDirectory: true)
        try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)

        XCTAssertTrue(WhisperEngine.isModelDownloaded(
            model: "whisper-large-v3-v20240930-turbo-632MB",
            downloadBase: root
        ))
        XCTAssertEqual(
            WhisperEngine.localModelFolder(
                model: "large-v3-v20240930_turbo_632MB",
                downloadBase: root
            )?.lastPathComponent,
            "openai_whisper-large-v3-v20240930_turbo_632MB"
        )
    }

    func testWhisperModelFolderPrefersExactMatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let boundaryMatch = root
            .appendingPathComponent("openai_whisper-large-v3-v20240930_turbo_632MB", isDirectory: true)
        let exactMatch = root
            .appendingPathComponent("large-v3-v20240930_turbo_632MB", isDirectory: true)
        try FileManager.default.createDirectory(at: boundaryMatch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exactMatch, withIntermediateDirectories: true)

        XCTAssertEqual(
            WhisperEngine.localModelFolder(
                model: "whisper-large-v3-v20240930-turbo-632MB",
                downloadBase: root
            )?.resolvingSymlinksInPath(),
            exactMatch.resolvingSymlinksInPath()
        )
    }

    func testWhisperModelFolderRejectsPartialNonBoundaryMatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partialMatch = root
            .appendingPathComponent("notlarge-v3-v20240930_turbo_632MBsuffix", isDirectory: true)
        try FileManager.default.createDirectory(at: partialMatch, withIntermediateDirectories: true)

        XCTAssertNil(WhisperEngine.localModelFolder(
            model: "whisper-large-v3-v20240930-turbo-632MB",
            downloadBase: root
        ))
    }

    func testWhisperModelFolderFindsLaterBoundaryMatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let nestedMatch = root
            .appendingPathComponent("notlarge-v3-v20240930_turbo_632MBsuffix-openai_whisper-large-v3-v20240930_turbo_632MB", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedMatch, withIntermediateDirectories: true)

        XCTAssertEqual(
            WhisperEngine.localModelFolder(
                model: "whisper-large-v3-v20240930-turbo-632MB",
                downloadBase: root
            )?.resolvingSymlinksInPath(),
            nestedMatch.resolvingSymlinksInPath()
        )
    }

    func testSTTErrorDescriptions() {
        XCTAssertNotNil(STTError.engineNotRunning.errorDescription)
        XCTAssertNotNil(STTError.timeout.errorDescription)
        XCTAssertNotNil(STTError.modelNotLoaded.errorDescription)
        XCTAssertNotNil(STTError.outOfMemory.errorDescription)
        XCTAssertNotNil(STTError.invalidResponse.errorDescription)
        XCTAssertNotNil(STTError.engineBusy.errorDescription)
        XCTAssertNotNil(STTError.transcriptionFailed("test").errorDescription)
        XCTAssertNotNil(STTError.engineStartFailed("test").errorDescription)
    }

    func testMockSTTClientTranscribe() async throws {
        let mock = MockSTTClient()
        let expectedResult = STTResult(text: "Hello from mock")
        await mock.configure(result: expectedResult)

        let result = try await mock.transcribe(audioPath: "/tmp/test.wav", job: .fileTranscription)
        XCTAssertEqual(result.text, "Hello from mock")

        let callCount = await mock.transcribeCallCount
        XCTAssertEqual(callCount, 1)

        let lastPath = await mock.lastAudioPath
        XCTAssertEqual(lastPath, "/tmp/test.wav")
    }

    func testMockSTTClientError() async {
        let mock = MockSTTClient()
        await mock.configure(error: STTError.transcriptionFailed("test error"))

        do {
            _ = try await mock.transcribe(audioPath: "/tmp/test.wav", job: .fileTranscription)
            XCTFail("Should have thrown")
        } catch let error as STTError {
            if case .transcriptionFailed(let reason) = error {
                XCTAssertEqual(reason, "test error")
            } else {
                XCTFail("Wrong error type")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testMockSTTClientWarmUp() async throws {
        let mock = MockSTTClient()
        try await mock.warmUp()
        let called = await mock.warmUpCalled
        XCTAssertTrue(called)
    }

    func testMockSTTClientShutdown() async {
        let mock = MockSTTClient()
        await mock.shutdown()
        let called = await mock.shutdownCalled
        XCTAssertTrue(called)
    }

    func testMockSTTClientClearModelCache() async {
        let mock = MockSTTClient()
        await mock.clearModelCache()
        let called = await mock.clearModelCacheCalled
        XCTAssertTrue(called)
    }

}
