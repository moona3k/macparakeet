import XCTest

@testable import MacParakeetCore

/// Unit tests for `CohereTranscribeEngine`'s overlap-stitch used by the
/// truncation guard (long/dense utterances are chunked into overlapping windows
/// and re-joined). The transcription path itself needs the CoreML model and is
/// exercised manually; this covers the pure stitching logic.
final class CohereTranscribeEngineTests: XCTestCase {

    func testMergeDropsDuplicatedOverlapWords() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "the quick brown fox",
            "brown fox jumps over the lazy dog"
        )
        XCTAssertEqual(merged, "the quick brown fox jumps over the lazy dog")
    }

    func testMergeIsCaseAndPunctuationInsensitiveAtTheSeam() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "send me your feedback before the end of the day.",
            "Day, we should also review the draft"
        )
        // "the day." / "Day," overlap by one word and must not duplicate.
        XCTAssertEqual(
            merged,
            "send me your feedback before the end of the day. we should also review the draft"
        )
    }

    func testMergeConcatenatesWhenNoOverlap() {
        let merged = CohereTranscribeEngine.mergeOnOverlap("hello world", "foo bar")
        XCTAssertEqual(merged, "hello world foo bar")
    }

    func testMergeHandlesFullPrefixOverlap() {
        let merged = CohereTranscribeEngine.mergeOnOverlap("one two three", "two three")
        XCTAssertEqual(merged, "one two three")
    }

    func testMergeHandlesEmptyFragments() {
        XCTAssertEqual(CohereTranscribeEngine.mergeOnOverlap("", "only b"), "only b")
        XCTAssertEqual(CohereTranscribeEngine.mergeOnOverlap("only a", ""), "only a")
    }

    /// On-device end-to-end guard: a long/dense (>98-token) utterance must come
    /// back complete, not silently cut at the decode cap. Skipped unless
    /// `COHERE_E2E_CLIP` points at a suitable wav and the model is downloaded,
    /// so normal/CI runs are unaffected. Loads the real CoreML model.
    func testLongDictationIsNotTruncated() async throws {
        guard let clipPath = ProcessInfo.processInfo.environment["COHERE_E2E_CLIP"],
            FileManager.default.fileExists(atPath: clipPath)
        else {
            throw XCTSkip("Set COHERE_E2E_CLIP to a long (>98-token) .wav to run this on-device check.")
        }
        guard CohereTranscribeEngine.isModelCached() else {
            throw XCTSkip("Cohere model not downloaded.")
        }
        let expectedMinWords = Int(ProcessInfo.processInfo.environment["COHERE_E2E_MIN_WORDS"] ?? "90") ?? 90

        let engine = CohereTranscribeEngine(computePolicy: .ane)
        let result = try await engine.transcribe(audioPath: clipPath, job: .fileTranscription)
        let wordCount = result.text.split(whereSeparator: { $0 == " " }).count
        XCTAssertGreaterThanOrEqual(
            wordCount, expectedMinWords,
            "Transcript looks truncated (\(wordCount) words). Got: \(result.text)")
    }

    // MARK: - Language picker

    func testSupportedLanguagesAreFourteenWithEnglish() {
        let languages = CohereTranscribeEngine.supportedLanguages
        XCTAssertEqual(languages.count, 14)
        XCTAssertTrue(languages.contains { $0.code == "en" && $0.name == "English" })
        XCTAssertTrue(languages.allSatisfy { $0.code.count == 2 && $0.code == $0.code.lowercased() })
    }

    func testNormalizeCohereLanguageFoldsToPrimarySubtag() {
        XCTAssertEqual(SpeechEnginePreference.normalizeCohereLanguage("en"), "en")
        XCTAssertEqual(SpeechEnginePreference.normalizeCohereLanguage("EN"), "en")
        XCTAssertEqual(SpeechEnginePreference.normalizeCohereLanguage("en-US"), "en")
        XCTAssertEqual(SpeechEnginePreference.normalizeCohereLanguage("fr_FR"), "fr")
        XCTAssertNil(SpeechEnginePreference.normalizeCohereLanguage("auto"))
        XCTAssertNil(SpeechEnginePreference.normalizeCohereLanguage(""))
        XCTAssertNil(SpeechEnginePreference.normalizeCohereLanguage(nil))
        XCTAssertNil(SpeechEnginePreference.normalizeCohereLanguage("12"))
    }

    func testCohereDefaultLanguageRoundTrips() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "cohere-lang-test-\(UUID().uuidString)"))
        XCTAssertNil(SpeechEnginePreference.cohereDefaultLanguage(defaults: defaults))
        SpeechEnginePreference.saveCohereDefaultLanguage("ja", defaults: defaults)
        XCTAssertEqual(SpeechEnginePreference.cohereDefaultLanguage(defaults: defaults), "ja")
        SpeechEnginePreference.saveCohereDefaultLanguage(nil, defaults: defaults)
        XCTAssertNil(SpeechEnginePreference.cohereDefaultLanguage(defaults: defaults))
    }

    /// Guards the mapper the string-code initializer (used by the CLI to thread a
    /// resolved language into the engine) relies on: known BCP-47-ish codes map,
    /// unknown/empty/nil fall through to the caller's default.
    func testCohereLanguageMapsCodes() {
        XCTAssertNotNil(CohereTranscribeEngine.cohereLanguage("fr"))
        XCTAssertNotNil(CohereTranscribeEngine.cohereLanguage("fr-FR"))
        XCTAssertNotNil(CohereTranscribeEngine.cohereLanguage("EN"))
        XCTAssertNil(CohereTranscribeEngine.cohereLanguage("zz"))
        XCTAssertNil(CohereTranscribeEngine.cohereLanguage(""))
        XCTAssertNil(CohereTranscribeEngine.cohereLanguage(nil))
    }
}
