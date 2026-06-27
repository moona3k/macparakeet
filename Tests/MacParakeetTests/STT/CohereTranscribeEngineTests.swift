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

    func testMergeCompletesPartialTrailingWordWhenOverlapIsStrong() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "the quick brown fo",
            "quick brown fox jumps over the lazy dog"
        )
        XCTAssertEqual(merged, "the quick brown fox jumps over the lazy dog")
    }

    func testMergeCompletesPartialTrailingWordWithCaseAndPunctuationDrift() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "the quick brown fo,",
            "quick brown Fox jumps over the lazy dog"
        )
        XCTAssertEqual(merged, "the quick brown Fox jumps over the lazy dog")
    }

    func testMergeDropsPartialLeadingWordWhenOverlapIsStrong() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "the quick brown fox",
            "own fox jumps over the lazy dog"
        )
        XCTAssertEqual(merged, "the quick brown fox jumps over the lazy dog")
    }

    func testMergeDropsPartialLeadingWordWithCaseAndPunctuationDrift() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "the quick Brown fox",
            "own, Fox jumps over the lazy dog"
        )
        XCTAssertEqual(merged, "the quick Brown fox jumps over the lazy dog")
    }

    func testMergeDoesNotUsePartialBoundaryWithoutStrongOverlap() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "alpha fo",
            "fox beta"
        )
        XCTAssertEqual(merged, "alpha fo fox beta")
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

    func testMergeDropsJapaneseOverlapWithoutInsertingSpace() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "今日はいい天気ですね明日も",
            "明日も晴れるでしょう"
        )
        XCTAssertEqual(merged, "今日はいい天気ですね明日も晴れるでしょう")
        XCTAssertFalse(merged.contains(" "))
        XCTAssertEqual(merged.components(separatedBy: "明日も").count - 1, 1)
    }

    func testMergeDropsChineseOverlapWithoutInsertingSpace() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "我今天去了商店买东西",
            "买东西然后回家了"
        )
        XCTAssertEqual(merged, "我今天去了商店买东西然后回家了")
        XCTAssertFalse(merged.contains(" "))
        XCTAssertEqual(merged.components(separatedBy: "买东西").count - 1, 1)
    }

    func testMergeDropsMixedSpaceChineseOverlap() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "今天 buy coffee 然后回家",
            "coffee 然后回家休息"
        )
        XCTAssertEqual(merged, "今天 buy coffee 然后回家休息")
        XCTAssertEqual(merged.components(separatedBy: "coffee 然后回家").count - 1, 1)
    }

    func testMergeDropsLongChineseCharacterOverlap() {
        let overlap = "这是一个很长的中文重叠片段用于模拟四秒钟的快速讲话内容并且继续包含更多文字"
        XCTAssertGreaterThan(overlap.count, 30)

        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "开头内容" + overlap,
            overlap + "结尾内容"
        )
        XCTAssertEqual(merged, "开头内容" + overlap + "结尾内容")
    }

    func testMergeDropsCJKCompatibilityIdeographOverlapWithoutInsertingSpace() throws {
        let first = try XCTUnwrap(UnicodeScalar(0xF900).map(String.init))
        let second = try XCTUnwrap(UnicodeScalar(0xF901).map(String.init))

        let merged = CohereTranscribeEngine.mergeOnOverlap(
            first + first + first + second,
            first + second + second
        )

        XCTAssertEqual(merged, first + first + first + second + second)
        XCTAssertFalse(merged.contains(" "))
    }

    func testMergeDropsSupplementaryCJKOverlapWithoutInsertingSpace() throws {
        let first = try XCTUnwrap(UnicodeScalar(0x20000).map(String.init))
        let second = try XCTUnwrap(UnicodeScalar(0x20001).map(String.init))

        let merged = CohereTranscribeEngine.mergeOnOverlap(
            first + first + first + second,
            first + second + second
        )

        XCTAssertEqual(merged, first + first + first + second + second)
        XCTAssertFalse(merged.contains(" "))
    }

    func testMergeDoesNotTreatDifferentPunctuationAsOverlap() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "hello 。",
            "、 world"
        )
        XCTAssertEqual(merged, "hello 。 、 world")
    }

    func testMergeDoesNotTreatMatchingPunctuationOnlyAsOverlap() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "hello 。",
            "。 world"
        )
        XCTAssertEqual(merged, "hello 。 。 world")
    }

    func testMergeAllowsPunctuationInsideLexicalOverlap() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "你好。",
            "好。明天见"
        )
        XCTAssertEqual(merged, "你好。明天见")
    }

    func testMergeUsesTailOfLongAccumulatedTranscript() {
        let prefix = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            prefix + " alpha beta",
            "alpha beta gamma"
        )
        XCTAssertEqual(merged, prefix + " alpha beta gamma")
    }

    func testMergeTailBoundKeepsLongWordOverlapIntact() {
        let prefix = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let overlap = (0..<30)
            .map { "overlapsegment\($0)abc" }
            .joined(separator: " ")
        XCTAssertGreaterThan(overlap.count, 450)
        XCTAssertLessThan(overlap.count, 1000)

        let merged = CohereTranscribeEngine.mergeOnOverlap(
            prefix + " " + overlap,
            overlap + " tail"
        )

        XCTAssertEqual(merged, prefix + " " + overlap + " tail")
    }

    func testMergeHandlesEmptyFragments() {
        XCTAssertEqual(CohereTranscribeEngine.mergeOnOverlap("", "only b"), "only b")
        XCTAssertEqual(CohereTranscribeEngine.mergeOnOverlap("only a", ""), "only a")
    }

    func testComputePolicyDefaultsToANEWhenUnset() throws {
        let suiteName = "cohere-compute-policy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(CohereTranscribeEngine.ComputePolicy.current(defaults: defaults), .ane)

        defaults.set("gpu", forKey: CohereTranscribeEngine.ComputePolicy.defaultsKey)
        XCTAssertEqual(CohereTranscribeEngine.ComputePolicy.current(defaults: defaults), .gpu)
    }

    func testRequireModelCachedFailsFastWhenCohereCacheIsMissing() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cohere-cache-\(UUID().uuidString)", isDirectory: true)

        XCTAssertThrowsError(try CohereTranscribeEngine.requireModelCached(cacheRoot: cacheRoot)) { error in
            guard case STTError.engineStartFailed(let reason) = error else {
                return XCTFail("Expected engineStartFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("Cohere Transcribe is not downloaded"))
            XCTAssertTrue(reason.contains("models download cohere-transcribe"))
        }
    }

    func testRequireModelCachedAcceptsCompleteCohereCache() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cohere-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        try FileManager.default.createDirectory(
            at: cacheRoot.appendingPathComponent("cohere_encoder.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cacheRoot.appendingPathComponent("cohere_decoder_cache_external_v2.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "{}".write(
            to: cacheRoot.appendingPathComponent("vocab.json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertNoThrow(try CohereTranscribeEngine.requireModelCached(cacheRoot: cacheRoot))
    }

    func testSharedInitializationAwaiterCancellationDoesNotCancelSharedTask() async throws {
        let shared = Task<Void, Error> {
            try await Task.sleep(for: .milliseconds(500))
        }
        let waiter = Task<Void, Error> {
            try await CohereTranscribeEngine.awaitSharedInitializationTask(shared)
        }

        let clock = ContinuousClock()
        let started = clock.now
        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("Cancelled waiter should throw CancellationError")
        } catch is CancellationError {
            let elapsed = started.duration(to: clock.now)
            XCTAssertLessThan(elapsed, .milliseconds(200))
        }

        try await shared.value
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
        XCTAssertNil(SpeechEnginePreference.normalizeCohereLanguage("eng"))
        XCTAssertNil(SpeechEnginePreference.normalizeCohereLanguage("xx"))
    }

    func testCohereDefaultLanguageRoundTrips() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "cohere-lang-test-\(UUID().uuidString)"))
        XCTAssertNil(SpeechEnginePreference.cohereDefaultLanguage(defaults: defaults))
        SpeechEnginePreference.saveCohereDefaultLanguage("ja", defaults: defaults)
        XCTAssertEqual(SpeechEnginePreference.cohereDefaultLanguage(defaults: defaults), "ja")
        defaults.set("eng", forKey: SpeechEnginePreference.cohereDefaultLanguageKey)
        XCTAssertNil(SpeechEnginePreference.cohereDefaultLanguage(defaults: defaults))
        SpeechEnginePreference.saveCohereDefaultLanguage(nil, defaults: defaults)
        XCTAssertNil(SpeechEnginePreference.cohereDefaultLanguage(defaults: defaults))
    }

    /// Guards the mapper that the string-code initializer (used by the CLI to thread a
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
