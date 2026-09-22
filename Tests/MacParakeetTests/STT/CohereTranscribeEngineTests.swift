import XCTest

@testable import MacParakeetCore

#if MACPARAKEET_HAS_TRANSCRIBE_CPP
import TranscribeCpp
#endif

/// Unit tests for `CohereTranscribeEngine`'s overlap-stitch used by the
/// truncation guard (long/dense utterances are chunked into overlapping windows
/// and re-joined). Native execution is covered through an injected backend so
/// the lifecycle contract remains deterministic without a downloaded model.
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

    func testMergeDropsApproximateJapaneseOverlapWithRecognizerDrift() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "6番マックスパラキートで確認しています。7番コヒアの日本語テストです。",
            "7番コヒアの2本5テストです。8番最後まで静かに録音します。"
        )

        XCTAssertEqual(
            merged,
            "6番マックスパラキートで確認しています。7番コヒアの日本語テストです。8番最後まで静かに録音します。"
        )
        XCTAssertEqual(merged.components(separatedBy: "7番").count - 1, 1)
    }

    func testMergeDropsApproximateJapaneseNumberedOverlapWithKanaDrift() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "16番最後まで静かに録音します。17番今日はいい天気です。",
            "17番きょうはいい天気です。おはこあしたも晴れるでしょう。"
        )

        XCTAssertEqual(
            merged,
            "16番最後まで静かに録音します。17番今日はいい天気です。おはこあしたも晴れるでしょう。"
        )
        XCTAssertEqual(merged.components(separatedBy: "17番").count - 1, 1)
    }

    func testMergeDoesNotApproximateDifferentNumberedJapanesePhrases() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "1番今日はいい天気です。",
            "2番今日はいい天気です。"
        )

        XCTAssertEqual(merged, "1番今日はいい天気です。2番今日はいい天気です。")
    }

    func testMergeDropsApproximateChineseOverlapWithRecognizerDrift() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "前半内容然后去商店买东西",
            "然后去商店买东息结尾内容"
        )

        XCTAssertEqual(merged, "前半内容然后去商店买东西结尾内容")
    }

    func testMergeDropsApproximateHangulOverlapWithRecognizerDrift() {
        let merged = CohereTranscribeEngine.mergeOnOverlap(
            "앞부분오늘날씨가정말좋습니다",
            "오늘날씨가정말조습니다끝부분"
        )

        XCTAssertEqual(merged, "앞부분오늘날씨가정말좋습니다끝부분")
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

    func testComputePolicyDefaultsToMetalAndMigratesLegacyValues() throws {
        let suiteName = "cohere-compute-policy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(CohereTranscribeEngine.ComputePolicy.current(defaults: defaults), .metal)

        defaults.set("gpu", forKey: CohereTranscribeEngine.ComputePolicy.defaultsKey)
        XCTAssertEqual(CohereTranscribeEngine.ComputePolicy.current(defaults: defaults), .metal)

        defaults.set("ane", forKey: CohereTranscribeEngine.ComputePolicy.defaultsKey)
        XCTAssertEqual(CohereTranscribeEngine.ComputePolicy.current(defaults: defaults), .cpu)

        CohereTranscribeEngine.ComputePolicy.metal.save(to: defaults)
        XCTAssertEqual(
            defaults.string(forKey: CohereTranscribeEngine.ComputePolicy.defaultsKey),
            "metal"
        )
    }

    func testModelAndRuntimePinsMatchReviewedArtifacts() {
        XCTAssertEqual(CohereTranscribePins.upstreamTag, "v0.1.3")
        XCTAssertEqual(
            CohereTranscribePins.upstreamTagObject,
            "d503d6a239e2a290a03ab72dbd3b40460d87acb0"
        )
        XCTAssertEqual(
            CohereTranscribePins.upstreamCommit,
            "a94e021ef658dc7c788837341a13f6acea3baf3c"
        )
        XCTAssertEqual(
            CohereTranscribePins.ownedForkCommit,
            "51aa23592167cc32f8f3c5d2155d9f9937324c8d"
        )
        XCTAssertEqual(CohereTranscribePins.ownedForkRepository, "DudeMeister23/transcribe.cpp")
        XCTAssertEqual(CohereTranscribePins.ownedReleaseTag, "macparakeet-v0.1.3-arm64.1")
        XCTAssertEqual(
            CohereTranscribePins.ownedArtifactFileName,
            "TranscribeCpp-macOS-arm64-v0.1.3-macparakeet.1.xcframework.zip"
        )
        XCTAssertEqual(
            CohereTranscribePins.ownedArtifactURL,
            "https://github.com/dudemeister23/transcribe.cpp/releases/download/macparakeet-v0.1.3-arm64.1/TranscribeCpp-macOS-arm64-v0.1.3-macparakeet.1.xcframework.zip"
        )
        XCTAssertEqual(
            CohereTranscribePins.ownedArtifactSHA256,
            "caad2e1ce80801e5d0adb7e2bb9bcf8e7d1fd295657af281d8260d5dcc629350"
        )
        XCTAssertEqual(CohereTranscribePins.swiftWrapperVersion, "0.1.3")
        XCTAssertEqual(CohereTranscribePins.modelArchitecture, "cohere_asr")
        XCTAssertEqual(
            CohereTranscribePins.upstreamReferenceArtifactSHA256,
            "b7a3442e2f3552cac1ee71b5e164934dd4db243f6b4b16b1e3e3ed5d1645eefd"
        )
        XCTAssertEqual(
            CohereTranscribeModelCatalog.manifest.revision,
            "dfa4adebb64f3076b7b6b90b721275cc069cb421"
        )
        XCTAssertEqual(CohereTranscribeModelCatalog.manifest.totalBytes, 1_770_270_208)
        XCTAssertEqual(
            CohereTranscribeModelCatalog.manifest.files.first?.sha256,
            "14d02f1ad6dd77b3a60f82639879012c3adb4fe25c50a5a47a2c4c661daf1558"
        )
    }

    #if MACPARAKEET_HAS_TRANSCRIBE_CPP
    func testLinkedNativeRuntimeReportsPinnedVersionAndCommit() {
        XCTAssertEqual(Transcribe.version(), CohereTranscribePins.swiftWrapperVersion)
        let actualCommit = Transcribe.versionCommit().lowercased()
        XCTAssertGreaterThanOrEqual(actualCommit.count, 7)
        XCTAssertTrue(
            CohereTranscribePins.requiredRuntimeCommit.lowercased().hasPrefix(actualCommit)
        )
    }
    #endif

    func testRequireModelCachedFailsFastWhenCohereCacheIsMissing() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cohere-cache-\(UUID().uuidString)", isDirectory: true)

        XCTAssertThrowsError(try CohereTranscribeEngine.requireModelCached(cacheRoot: cacheRoot)) { error in
            guard case STTError.engineStartFailed(let reason) = error else {
                return XCTFail("Expected engineStartFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("not downloaded or failed verification"))
            XCTAssertTrue(reason.contains("models download cohere-transcribe"))
        }
    }

    func testNativeCapabilityValidationRejectsAdapterWithoutAutomaticLanguageMetadata() {
        var capabilities = makeCapabilities()
        capabilities = CohereNativeCapabilities(
            runtimeVersion: capabilities.runtimeVersion,
            runtimeCommit: capabilities.runtimeCommit,
            architecture: capabilities.architecture,
            variant: capabilities.variant,
            computeBackend: capabilities.computeBackend,
            nativeSampleRate: capabilities.nativeSampleRate,
            maxAudioMilliseconds: capabilities.maxAudioMilliseconds,
            supportedLanguages: capabilities.supportedLanguages,
            supportsLanguageDetection: false,
            providesTimestamps: capabilities.providesTimestamps
        )

        XCTAssertThrowsError(
            try CohereTranscribeEngine.validateNativeCapabilities(capabilities)
        ) { error in
            XCTAssertEqual(
                error as? CohereNativeBackendError,
                .languageDetectionUnavailable
            )
        }
    }

    func testNativeCapabilityValidationAcceptsPinnedShortCommitAndRejectsMismatch() throws {
        let original = makeCapabilities()
        let shortCommit = String(CohereTranscribePins.requiredRuntimeCommit.prefix(7))
        let pinned = CohereNativeCapabilities(
            runtimeVersion: original.runtimeVersion,
            runtimeCommit: shortCommit,
            architecture: original.architecture,
            variant: original.variant,
            computeBackend: original.computeBackend,
            nativeSampleRate: original.nativeSampleRate,
            maxAudioMilliseconds: original.maxAudioMilliseconds,
            supportedLanguages: original.supportedLanguages,
            supportsLanguageDetection: original.supportsLanguageDetection,
            providesTimestamps: original.providesTimestamps
        )

        XCTAssertNoThrow(try CohereTranscribeEngine.validateNativeCapabilities(pinned))

        let mismatched = CohereNativeCapabilities(
            runtimeVersion: pinned.runtimeVersion,
            runtimeCommit: "deadbee",
            architecture: pinned.architecture,
            variant: pinned.variant,
            computeBackend: pinned.computeBackend,
            nativeSampleRate: pinned.nativeSampleRate,
            maxAudioMilliseconds: pinned.maxAudioMilliseconds,
            supportedLanguages: pinned.supportedLanguages,
            supportsLanguageDetection: pinned.supportsLanguageDetection,
            providesTimestamps: pinned.providesTimestamps
        )
        XCTAssertThrowsError(
            try CohereTranscribeEngine.validateNativeCapabilities(mismatched)
        ) { error in
            guard let backendError = error as? CohereNativeBackendError,
                case .incompatibleCommit = backendError
            else {
                return XCTFail("Expected incompatibleCommit, got \(error)")
            }
        }
    }

    func testNativeCapabilityValidationRejectsLanguageSetDrift() {
        let original = makeCapabilities()
        let capabilities = CohereNativeCapabilities(
            runtimeVersion: original.runtimeVersion,
            runtimeCommit: original.runtimeCommit,
            architecture: original.architecture,
            variant: original.variant,
            computeBackend: original.computeBackend,
            nativeSampleRate: original.nativeSampleRate,
            maxAudioMilliseconds: original.maxAudioMilliseconds,
            supportedLanguages: ["en", "de"],
            supportsLanguageDetection: true,
            providesTimestamps: false
        )

        XCTAssertThrowsError(
            try CohereTranscribeEngine.validateNativeCapabilities(capabilities)
        ) { error in
            guard let backendError = error as? CohereNativeBackendError,
                case .unsupportedLanguages = backendError
            else {
                return XCTFail("Expected unsupportedLanguages, got \(error)")
            }
        }
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

    func testConcurrentPrepareCallsShareOneNativeLoad() async throws {
        let backend = MockCohereTranscribeBackend()
        let engine = makeEngine(backend: backend)

        async let first: Void = engine.prepare()
        async let second: Void = engine.prepare()
        _ = try await (first, second)

        let loadCount = await backend.loadCount()
        XCTAssertEqual(loadCount, 1)
    }

    func testCancellationDuringLoadReturnsPromptlyWithoutPublishingReadiness() async throws {
        let backend = MockCohereTranscribeBackend(blockLoad: true)
        let engine = makeEngine(backend: backend)
        let task = Task { try await engine.prepare() }
        try await backend.waitUntilLoadStarted()

        let clock = ContinuousClock()
        let started = clock.now
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(300))
        }
        let readyAfterCancellation = await engine.isReady()
        XCTAssertFalse(readyAfterCancellation)

        await backend.releaseLoad()
        await engine.unload()
        let unloadCount = await backend.unloadCount()
        XCTAssertEqual(unloadCount, 1)
    }

    func testCancellationDuringTranscriptionCancelsNativeRun() async throws {
        let backend = MockCohereTranscribeBackend(blockTranscription: true)
        let engine = makeEngine(backend: backend)
        let task = Task {
            try await engine.transcribeSamplesForTesting(
                [Float](repeating: 0, count: 8_000)
            )
        }
        try await backend.waitUntilTranscriptionStarted()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        await engine.unload()
        let unloadCount = await backend.unloadCount()
        XCTAssertEqual(unloadCount, 1)
    }

    func testUnloadDeterministicallyTearsDownNativeContext() async throws {
        let backend = MockCohereTranscribeBackend()
        let engine = makeEngine(backend: backend)
        try await engine.prepare()
        let readyBeforeUnload = await engine.isReady()
        XCTAssertTrue(readyBeforeUnload)

        await engine.unload()

        let readyAfterUnload = await engine.isReady()
        let unloadCount = await backend.unloadCount()
        XCTAssertFalse(readyAfterUnload)
        XCTAssertEqual(unloadCount, 1)
    }

    func testMultilingualTranscriptionNeverPassesManualLanguageHints() async throws {
        let backend = MockCohereTranscribeBackend(
            transcripts: [
                CohereNativeTranscript(text: "hello", detectedLanguage: "EN-US", wasTruncated: false),
                CohereNativeTranscript(text: "hallo", detectedLanguage: "de", wasTruncated: false),
                CohereNativeTranscript(text: "こんにちは", detectedLanguage: "ja", wasTruncated: false),
                CohereNativeTranscript(text: "你好", detectedLanguage: "zh", wasTruncated: false),
            ]
        )
        let engine = makeEngine(backend: backend)

        var detectedLanguages: [String?] = []
        for language in ["en", "de", "ja", "zh"] {
            let result = try await engine.transcribeSamplesForTesting(
                [Float](repeating: 0, count: 8_000),
                language: language
            )
            detectedLanguages.append(result.language)
        }

        let languages = await backend.languages()
        XCTAssertEqual(languages, [nil, nil, nil, nil])
        XCTAssertEqual(detectedLanguages, ["en", "de", "ja", "zh"])
    }

    func testLongAudioUsesBoundedChunksAndStitchesOverlap() async throws {
        let capabilities = makeCapabilities(maxAudioMilliseconds: 1_000)
        let backend = MockCohereTranscribeBackend(
            capabilities: capabilities,
            transcripts: [
                CohereNativeTranscript(
                    text: "alpha boundary",
                    detectedLanguage: "en",
                    wasTruncated: false
                ),
                CohereNativeTranscript(
                    text: "boundary beta",
                    detectedLanguage: "en",
                    wasTruncated: false
                ),
                CohereNativeTranscript(
                    text: "beta gamma",
                    detectedLanguage: "en",
                    wasTruncated: false
                ),
            ]
        )
        let engine = makeEngine(backend: backend)

        let result = try await engine.transcribeSamplesForTesting(
            [Float](repeating: 0, count: 25_000)
        )

        XCTAssertEqual(result.text, "alpha boundary beta gamma")
        XCTAssertEqual(result.language, "en")
        let chunkSizes = await backend.sampleCounts()
        XCTAssertEqual(chunkSizes.count, 3)
        XCTAssertTrue(chunkSizes.allSatisfy { $0 <= 14_400 })
    }

    func testTruncationAtMinimumChunkFailsInsteadOfReturningPartialText() async throws {
        let truncated = CohereNativeTranscript(
            text: "partial",
            detectedLanguage: "en",
            wasTruncated: true
        )
        let backend = MockCohereTranscribeBackend(
            capabilities: makeCapabilities(maxAudioMilliseconds: 1_000),
            transcripts: Array(repeating: truncated, count: 12)
        )
        let engine = makeEngine(backend: backend)

        do {
            _ = try await engine.transcribeSamplesForTesting(
                [Float](repeating: 0, count: 8_000)
            )
            XCTFail("Expected minimum-size truncation to fail")
        } catch let STTError.transcriptionFailed(message) {
            XCTAssertTrue(message.contains("minimum safe size"))
        }
    }

    func testMissingNativeFrameworkReportsUnavailableWhenNotLinked() async throws {
        guard !CohereTranscribeEngine.isNativeFrameworkAvailable else {
            throw XCTSkip("The native transcribe.cpp package is linked in this test build.")
        }
        let engine = CohereTranscribeEngine(
            backend: CohereTranscribeBackendFactory.makeDefault(),
            modelURLProvider: {
                URL(fileURLWithPath: "/tmp/unreachable.gguf")
            }
        )

        do {
            try await engine.prepare()
            XCTFail("Expected the missing framework to fail")
        } catch let STTError.engineStartFailed(message) {
            XCTAssertTrue(message.contains("framework is unavailable"))
        }
    }

    // MARK: - Language compatibility

    func testSupportedLanguagesAreFourteenWithEnglish() {
        let languages = CohereTranscribeEngine.supportedLanguages
        XCTAssertEqual(languages.count, 14)
        XCTAssertTrue(languages.contains { $0.code == "en" && $0.name == "English" })
        XCTAssertTrue(languages.contains { $0.code == "el" && $0.name == "Greek" })
        XCTAssertTrue(languages.contains { $0.code == "vi" && $0.name == "Vietnamese" })
        XCTAssertFalse(languages.contains { $0.code == "hi" })
        XCTAssertFalse(languages.contains { $0.code == "ru" })
        XCTAssertTrue(languages.allSatisfy { !$0.code.isEmpty && $0.code == $0.code.lowercased() })
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

    func testNormalizeCohereLanguageAcceptsEverySupportedCode() {
        for (code, _) in CohereTranscribeEngine.supportedLanguages {
            XCTAssertEqual(
                SpeechEnginePreference.normalizeCohereLanguage(code), code,
                "supported Cohere code '\(code)' must normalize to itself")
        }
    }

    func testNormalizeCohereLanguageRetainsLegacyHindiAndRussianValues() {
        XCTAssertEqual(SpeechEnginePreference.normalizeCohereLanguage("hi"), "hi")
        XCTAssertEqual(SpeechEnginePreference.normalizeCohereLanguage("ru-RU"), "ru")
    }

    func testTranscriptLanguageDetectorRecognizesRepresentativeLanguages() {
        let supported = CohereTranscribeEngine.supportedLanguages.map(\.code)
        let fixtures = [
            (
                "And so, my fellow Americans, ask not what your country can do for you.",
                "en"
            ),
            (
                "Am Strand liegen die Badehose, die Sandalen und das Handtuch.",
                "de"
            ),
            (
                "うちの中学は弁当制で、持って行けない場合は学校販売のパンを買う。",
                "ja"
            ),
            (
                "开放时间早上九点至下午五点。",
                "zh"
            ),
        ]

        for (text, expected) in fixtures {
            XCTAssertEqual(
                CohereTranscriptLanguageDetector.detect(
                    text,
                    supportedLanguages: supported
                ),
                expected
            )
        }
    }

    func testTranscriptLanguageDetectorReturnsNilForEmptyText() {
        XCTAssertNil(
            CohereTranscriptLanguageDetector.detect(
                "  \n ",
                supportedLanguages: CohereTranscribeEngine.supportedLanguages.map(\.code)
            )
        )
    }

    func testCohereDefaultLanguageRoundTrips() throws {
        let suiteName = "cohere-lang-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertNil(SpeechEnginePreference.cohereDefaultLanguage(defaults: defaults))
        SpeechEnginePreference.saveCohereDefaultLanguage("ja", defaults: defaults)
        XCTAssertEqual(SpeechEnginePreference.cohereDefaultLanguage(defaults: defaults), "ja")
        defaults.set("eng", forKey: SpeechEnginePreference.cohereDefaultLanguageKey)
        XCTAssertNil(SpeechEnginePreference.cohereDefaultLanguage(defaults: defaults))
        SpeechEnginePreference.saveCohereDefaultLanguage(nil, defaults: defaults)
        XCTAssertNil(SpeechEnginePreference.cohereDefaultLanguage(defaults: defaults))
    }

    func testCohereLanguageMapsCodes() {
        XCTAssertNotNil(CohereTranscribeEngine.cohereLanguage("fr"))
        XCTAssertNotNil(CohereTranscribeEngine.cohereLanguage("fr-FR"))
        XCTAssertNotNil(CohereTranscribeEngine.cohereLanguage("EN"))
        XCTAssertNil(CohereTranscribeEngine.cohereLanguage("zz"))
        XCTAssertNil(CohereTranscribeEngine.cohereLanguage(""))
        XCTAssertNil(CohereTranscribeEngine.cohereLanguage(nil))
    }

    private func makeEngine(
        backend: MockCohereTranscribeBackend
    ) -> CohereTranscribeEngine {
        CohereTranscribeEngine(
            computePolicy: .metal,
            backend: backend,
            modelURLProvider: {
                URL(fileURLWithPath: "/tmp/cohere-test.gguf")
            }
        )
    }

    private func makeCapabilities(
        maxAudioMilliseconds: Int64 = 400_000
    ) -> CohereNativeCapabilities {
        CohereNativeCapabilities(
            runtimeVersion: CohereTranscribePins.swiftWrapperVersion,
            runtimeCommit: CohereTranscribePins.requiredRuntimeCommit,
            architecture: CohereTranscribePins.modelArchitecture,
            variant: CohereTranscribePins.modelVariant,
            computeBackend: "metal",
            nativeSampleRate: 16_000,
            maxAudioMilliseconds: maxAudioMilliseconds,
            supportedLanguages: CohereTranscribeEngine.supportedLanguages.map(\.code),
            supportsLanguageDetection: true,
            providesTimestamps: false
        )
    }
}

private enum MockCohereTranscribeBackendError: Error {
    case waitTimedOut(String)
}

private actor MockCohereTranscribeBackend: CohereTranscribeBackend {
    private let capabilities: CohereNativeCapabilities
    private var queuedTranscripts: [CohereNativeTranscript]
    private let blockLoad: Bool
    private let blockTranscription: Bool
    private var loadCalls = 0
    private var unloadCalls = 0
    private var observedLanguages: [String?] = []
    private var observedSampleCounts: [Int] = []
    private var loadStarted = false
    private var transcriptionStarted = false
    private var loadContinuation: CheckedContinuation<Void, Never>?

    init(
        capabilities: CohereNativeCapabilities? = nil,
        transcripts: [CohereNativeTranscript] = [],
        blockLoad: Bool = false,
        blockTranscription: Bool = false
    ) {
        self.capabilities =
            capabilities
            ?? CohereNativeCapabilities(
                runtimeVersion: CohereTranscribePins.swiftWrapperVersion,
                runtimeCommit: CohereTranscribePins.requiredRuntimeCommit,
                architecture: CohereTranscribePins.modelArchitecture,
                variant: CohereTranscribePins.modelVariant,
                computeBackend: "metal",
                nativeSampleRate: 16_000,
                maxAudioMilliseconds: 400_000,
                supportedLanguages: CohereTranscribeEngine.supportedLanguages.map(\.code),
                supportsLanguageDetection: true,
                providesTimestamps: false
            )
        queuedTranscripts = transcripts
        self.blockLoad = blockLoad
        self.blockTranscription = blockTranscription
    }

    func load(
        modelURL _: URL,
        computePolicy _: CohereTranscribeEngine.ComputePolicy
    ) async throws -> CohereNativeCapabilities {
        loadCalls += 1
        loadStarted = true
        if blockLoad {
            await withCheckedContinuation { continuation in
                loadContinuation = continuation
            }
        }
        return capabilities
    }

    func transcribe(
        samples: [Float],
        language: String?
    ) async throws -> CohereNativeTranscript {
        transcriptionStarted = true
        observedLanguages.append(language)
        observedSampleCounts.append(samples.count)
        if blockTranscription {
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        if !queuedTranscripts.isEmpty {
            return queuedTranscripts.removeFirst()
        }
        return CohereNativeTranscript(
            text: "test",
            detectedLanguage: "en",
            wasTruncated: false
        )
    }

    func unload() async {
        unloadCalls += 1
    }

    func waitUntilLoadStarted() async throws {
        try await wait(
            for: "native load",
            until: { loadStarted }
        )
    }

    func waitUntilTranscriptionStarted() async throws {
        try await wait(
            for: "native transcription",
            until: { transcriptionStarted }
        )
    }

    private func wait(
        for operation: String,
        timeout: Duration = .seconds(2),
        until condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                throw MockCohereTranscribeBackendError.waitTimedOut(operation)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func releaseLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func loadCount() -> Int {
        loadCalls
    }

    func unloadCount() -> Int {
        unloadCalls
    }

    func languages() -> [String?] {
        observedLanguages
    }

    func sampleCounts() -> [Int] {
        observedSampleCounts
    }
}
