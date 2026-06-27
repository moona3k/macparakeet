import XCTest
@testable import MacParakeetCore

/// Covers the pure file-removal cores behind per-model delete. The telemetry
/// wrappers (`STTRuntime.deleteParakeetModel` / `deleteWhisperModel`) resolve
/// the real cache paths, so they're exercised through these injectable pieces
/// against temp directories rather than the live FluidAudio cache.
final class ModelDeletionTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDeletionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    // MARK: - Parakeet build file removal

    func testRemoveParakeetModelFilesDeletesPopulatedDirectory() throws {
        let modelDir = tempRoot.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try "model".write(to: modelDir.appendingPathComponent("Decoder.mlmodelc"), atomically: true, encoding: .utf8)

        XCTAssertTrue(STTRuntime.removeParakeetModelFiles(at: modelDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDir.path))
    }

    func testRemoveParakeetModelFilesIsNoOpWhenAbsent() {
        let missing = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertFalse(STTRuntime.removeParakeetModelFiles(at: missing))
    }

    func testRemoveParakeetModelFilesLeavesSiblingBuildIntact() throws {
        let v2Dir = tempRoot.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml", isDirectory: true)
        let v3Dir = tempRoot.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
        for dir in [v2Dir, v3Dir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "x".write(to: dir.appendingPathComponent("Decoder.mlmodelc"), atomically: true, encoding: .utf8)
        }

        XCTAssertTrue(STTRuntime.removeParakeetModelFiles(at: v2Dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: v2Dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: v3Dir.path))
    }

    // MARK: - Parakeet Unified cache validation

    func testParakeetUnifiedRequiredModelFilesTrackOfflineDownloadSet() {
        let requiredFiles = ParakeetUnifiedEngine.requiredModelFiles()

        XCTAssertTrue(requiredFiles.contains("parakeet_unified_preprocessor.mlmodelc"))
        XCTAssertTrue(requiredFiles.contains("parakeet_unified_encoder_int8.mlmodelc"))
        XCTAssertTrue(requiredFiles.contains("parakeet_unified_decoder.mlmodelc"))
        XCTAssertTrue(requiredFiles.contains("parakeet_unified_joint_decision_single_step.mlmodelc"))
        XCTAssertTrue(requiredFiles.contains("vocab.json"))
        XCTAssertTrue(requiredFiles.contains("metadata.json"))
    }

    func testParakeetUnifiedRequiredStreamingModelFilesTrackStreamingDownloadSet() {
        let requiredFiles = ParakeetUnifiedEngine.requiredStreamingModelFiles()

        XCTAssertTrue(requiredFiles.contains("parakeet_unified_preprocessor.mlmodelc"))
        XCTAssertTrue(requiredFiles.contains("parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc"))
        XCTAssertTrue(requiredFiles.contains("parakeet_unified_decoder.mlmodelc"))
        XCTAssertTrue(requiredFiles.contains("parakeet_unified_joint_decision_single_step.mlmodelc"))
        XCTAssertTrue(requiredFiles.contains("vocab.json"))
        XCTAssertTrue(requiredFiles.contains("metadata.json"))
    }

    func testParakeetUnifiedIsModelCachedFalseWhenOnlyMetadataAndEncoderExist() throws {
        let cacheRoot = tempRoot.appendingPathComponent("parakeet-unified-en-0.6b-coreml", isDirectory: true)
        try writeUnifiedModelFile("metadata.json", in: cacheRoot)
        try writeUnifiedModelFile("parakeet_unified_encoder_int8.mlmodelc", in: cacheRoot)

        XCTAssertFalse(ParakeetUnifiedEngine.isModelCached(cacheRoot: cacheRoot))
    }

    func testParakeetUnifiedIsModelCachedFalseWhenAnyRequiredFileIsMissing() throws {
        let requiredFiles = ParakeetUnifiedEngine.requiredAllModelFiles()
        for missingFile in requiredFiles {
            let cacheRoot = tempRoot
                .appendingPathComponent("parakeet-unified-\(missingFile)-\(UUID().uuidString)", isDirectory: true)
            for fileName in requiredFiles where fileName != missingFile {
                try writeUnifiedModelFile(fileName, in: cacheRoot)
            }

            XCTAssertFalse(
                ParakeetUnifiedEngine.isModelCached(cacheRoot: cacheRoot),
                "Cache should be invalid when \(missingFile) is missing"
            )
        }
    }

    func testParakeetUnifiedIsModelCachedTrueWhenAllRequiredFilesExist() throws {
        let cacheRoot = tempRoot.appendingPathComponent("parakeet-unified-en-0.6b-coreml", isDirectory: true)
        for fileName in ParakeetUnifiedEngine.requiredAllModelFiles() {
            try writeUnifiedModelFile(fileName, in: cacheRoot)
        }

        XCTAssertTrue(ParakeetUnifiedEngine.isModelCached(cacheRoot: cacheRoot))
    }

    // MARK: - Nemotron repo file removal

    func testRemoveNemotronModelFilesDeletesWholeRepoRoot() throws {
        let repoRoot = tempRoot.appendingPathComponent("NemotronMultilingual", isDirectory: true)
        let autoDir = repoRoot
            .appendingPathComponent("auto", isDirectory: true)
            .appendingPathComponent("1120ms", isDirectory: true)
        let japaneseDir = repoRoot
            .appendingPathComponent("ja", isDirectory: true)
            .appendingPathComponent("1120ms", isDirectory: true)
        for dir in [autoDir, japaneseDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "weights".write(to: dir.appendingPathComponent("model.bin"), atomically: true, encoding: .utf8)
        }

        XCTAssertTrue(STTRuntime.removeNemotronModelFiles(at: repoRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoRoot.path))
    }

    func testRemoveNemotronModelFilesIsNoOpWhenAbsent() {
        let missing = tempRoot.appendingPathComponent("missing-nemotron", isDirectory: true)
        XCTAssertFalse(STTRuntime.removeNemotronModelFiles(at: missing))
    }

    func testDeleteNemotronModelCachesRemovesEveryLanguageForVariant() throws {
        let repoRoot = tempRoot.appendingPathComponent("NemotronMultilingual", isDirectory: true)
        let autoVariant = repoRoot
            .appendingPathComponent("auto", isDirectory: true)
            .appendingPathComponent("1120ms", isDirectory: true)
        let japaneseVariant = repoRoot
            .appendingPathComponent("ja", isDirectory: true)
            .appendingPathComponent("1120ms", isDirectory: true)
        let siblingVariant = repoRoot
            .appendingPathComponent("ja", isDirectory: true)
            .appendingPathComponent("80ms", isDirectory: true)
        for dir in [autoVariant, japaneseVariant, siblingVariant] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "weights".write(to: dir.appendingPathComponent("model.bin"), atomically: true, encoding: .utf8)
        }

        XCTAssertTrue(NemotronEngine.deleteModelCaches(modelVariant: .multilingual1120, cacheRoot: repoRoot))

        XCTAssertFalse(FileManager.default.fileExists(atPath: autoVariant.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: japaneseVariant.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingVariant.path))
    }

    func testDeleteNemotronModelWithInvalidLanguageDoesNotDeleteAllCaches() throws {
        let repoRoot = tempRoot.appendingPathComponent("NemotronMultilingual", isDirectory: true)
        let autoVariant = repoRoot
            .appendingPathComponent("auto", isDirectory: true)
            .appendingPathComponent("1120ms", isDirectory: true)
        try FileManager.default.createDirectory(at: autoVariant, withIntermediateDirectories: true)
        try "weights".write(to: autoVariant.appendingPathComponent("model.bin"), atomically: true, encoding: .utf8)

        XCTAssertFalse(
            NemotronEngine.deleteModel(
                modelVariant: .multilingual1120,
                language: "definitely-not-a-language",
                cacheRoot: repoRoot
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: autoVariant.path))
    }

    func testDownloadNemotronModelEmitsRuntimeTelemetryOnSuccess() async throws {
        let telemetry = ModelDeletionTelemetrySpy()
        Telemetry.configure(telemetry)
        defer { Telemetry.configure(NoOpTelemetryService()) }
        let modelURL = tempRoot!

        try await STTRuntime.downloadNemotronModel(
            modelVariant: .multilingual1120,
            language: "ja",
            emitTelemetry: true,
            downloader: { _, _, _ in
                modelURL
            }
        )

        let events = telemetry.snapshot()
        XCTAssertTrue(events.containsNemotronDownloadStarted(engineVariant: .multilingual1120))
        XCTAssertTrue(events.containsNemotronDownloadCompleted(engineVariant: .multilingual1120))
        XCTAssertTrue(events.containsNemotronDownloadOperation(outcome: .success, engineVariant: .multilingual1120))
    }

    func testDownloadNemotronModelCanSuppressRuntimeTelemetryForUIOwnedFlows() async throws {
        let telemetry = ModelDeletionTelemetrySpy()
        Telemetry.configure(telemetry)
        defer { Telemetry.configure(NoOpTelemetryService()) }
        let modelURL = tempRoot!

        try await STTRuntime.downloadNemotronModel(
            modelVariant: .multilingual1120,
            language: "ja",
            emitTelemetry: false,
            downloader: { _, _, _ in
                modelURL
            }
        )

        XCTAssertTrue(telemetry.snapshot().isEmpty)
    }

    // MARK: - Nemotron English tier file removal

    func testNemotronEnglishIsModelCachedFalseWhenOnlyMetadataExists() throws {
        let tierDir = tempRoot
            .appendingPathComponent("nemotron-streaming", isDirectory: true)
            .appendingPathComponent("1120ms", isDirectory: true)
        try FileManager.default.createDirectory(at: tierDir, withIntermediateDirectories: true)
        try "config".write(to: tierDir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)

        XCTAssertFalse(NemotronEnglishEngine.isModelCached(cacheRoot: tierDir))
    }

    func testNemotronEnglishIsModelCachedFalseWhenOnlyEncoderExists() throws {
        let tierDir = tempRoot
            .appendingPathComponent("nemotron-streaming", isDirectory: true)
            .appendingPathComponent("1120ms", isDirectory: true)
        let encoderDir = tierDir.appendingPathComponent("encoder", isDirectory: true)
        try FileManager.default.createDirectory(at: encoderDir, withIntermediateDirectories: true)
        try "weights".write(to: encoderDir.appendingPathComponent("encoder_int8.mlmodelc"), atomically: true, encoding: .utf8)

        XCTAssertFalse(NemotronEnglishEngine.isModelCached(cacheRoot: tierDir))
    }

    func testNemotronEnglishIsModelCachedTrueWhenMetadataAndEncoderExist() throws {
        let tierDir = tempRoot
            .appendingPathComponent("nemotron-streaming", isDirectory: true)
            .appendingPathComponent("1120ms", isDirectory: true)
        let encoderDir = tierDir.appendingPathComponent("encoder", isDirectory: true)
        try FileManager.default.createDirectory(at: encoderDir, withIntermediateDirectories: true)
        try "config".write(to: tierDir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        try "weights".write(to: encoderDir.appendingPathComponent("encoder_int8.mlmodelc"), atomically: true, encoding: .utf8)

        XCTAssertTrue(NemotronEnglishEngine.isModelCached(cacheRoot: tierDir))
    }

    func testNemotronEnglishDeleteModelRemovesTierAndEmptyFamilyRoot() throws {
        let familyRoot = tempRoot.appendingPathComponent("nemotron-streaming", isDirectory: true)
        let tierDir = familyRoot.appendingPathComponent("1120ms", isDirectory: true)
        let encoderDir = tierDir.appendingPathComponent("encoder", isDirectory: true)
        try FileManager.default.createDirectory(at: encoderDir, withIntermediateDirectories: true)
        try "config".write(to: tierDir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        try "weights".write(to: encoderDir.appendingPathComponent("encoder_int8.mlmodelc"), atomically: true, encoding: .utf8)

        XCTAssertTrue(NemotronEnglishEngine.deleteModel(cacheRoot: tierDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tierDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: familyRoot.path))
    }

    func testNemotronEnglishDeleteModelIsNoOpWhenAbsent() {
        let missing = tempRoot
            .appendingPathComponent("nemotron-streaming", isDirectory: true)
            .appendingPathComponent("1120ms", isDirectory: true)
        XCTAssertFalse(NemotronEnglishEngine.deleteModel(cacheRoot: missing))
    }

    func testNemotronEnglishDeleteModelKeepsFamilyRootWithSiblingTier() throws {
        let familyRoot = tempRoot.appendingPathComponent("nemotron-streaming", isDirectory: true)
        let tierDir = familyRoot.appendingPathComponent("1120ms", isDirectory: true)
        let siblingTier = familyRoot.appendingPathComponent("2240ms", isDirectory: true)
        for dir in [tierDir, siblingTier] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "weights".write(to: dir.appendingPathComponent("model.bin"), atomically: true, encoding: .utf8)
        }

        XCTAssertTrue(NemotronEnglishEngine.deleteModel(cacheRoot: tierDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tierDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: familyRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingTier.path))
    }

    /// The multilingual build caches under its own `nemotron-multilingual`
    /// family root (a sibling of `nemotron-streaming`), so deleting the English
    /// tier -- including the empty-parent cleanup -- must never touch it.
    func testNemotronEnglishDeleteModelLeavesMultilingualFamilyRootIntact() throws {
        let englishTier = tempRoot
            .appendingPathComponent("nemotron-streaming", isDirectory: true)
            .appendingPathComponent("1120ms", isDirectory: true)
        let multilingualVariant = tempRoot
            .appendingPathComponent("nemotron-multilingual", isDirectory: true)
            .appendingPathComponent("auto", isDirectory: true)
            .appendingPathComponent("1120ms", isDirectory: true)
        for dir in [englishTier, multilingualVariant] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "weights".write(to: dir.appendingPathComponent("model.bin"), atomically: true, encoding: .utf8)
        }

        XCTAssertTrue(NemotronEnglishEngine.deleteModel(cacheRoot: englishTier))
        XCTAssertFalse(FileManager.default.fileExists(atPath: englishTier.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: multilingualVariant.path))
    }

    // MARK: - Cohere cache file removal

    func testCohereCacheDirectoryExistsForPartialDownloadDirectory() throws {
        let tierDir = tempRoot
            .appendingPathComponent("cohere-transcribe", isDirectory: true)
            .appendingPathComponent("q8", isDirectory: true)
        try FileManager.default.createDirectory(at: tierDir, withIntermediateDirectories: true)
        try "partial".write(to: tierDir.appendingPathComponent("encoder.mlmodelc"), atomically: true, encoding: .utf8)

        XCTAssertTrue(CohereTranscribeEngine.hasModelCacheDirectory(cacheRoot: tierDir))
        XCTAssertFalse(CohereTranscribeEngine.isModelCached(cacheRoot: tierDir))
    }

    func testCohereDeleteModelPrunesParentWithOnlyFinderDotfiles() throws {
        let familyRoot = tempRoot.appendingPathComponent("cohere-transcribe", isDirectory: true)
        let tierDir = familyRoot.appendingPathComponent("q8", isDirectory: true)
        try FileManager.default.createDirectory(at: tierDir, withIntermediateDirectories: true)
        try "weights".write(to: tierDir.appendingPathComponent("model.bin"), atomically: true, encoding: .utf8)
        try "finder".write(to: familyRoot.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        XCTAssertTrue(CohereTranscribeEngine.deleteModel(cacheRoot: tierDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tierDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: familyRoot.path))
    }

    func testCohereDeleteModelKeepsParentWithVisibleSibling() throws {
        let familyRoot = tempRoot.appendingPathComponent("cohere-transcribe", isDirectory: true)
        let tierDir = familyRoot.appendingPathComponent("q8", isDirectory: true)
        let visibleSibling = familyRoot.appendingPathComponent("other-tier", isDirectory: true)
        for dir in [tierDir, visibleSibling] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "weights".write(to: dir.appendingPathComponent("model.bin"), atomically: true, encoding: .utf8)
        }

        XCTAssertTrue(CohereTranscribeEngine.deleteModel(cacheRoot: tierDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tierDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: familyRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: visibleSibling.path))
    }

    func testCohereDeleteModelKeepsParentWithNonFinderHiddenSibling() throws {
        let familyRoot = tempRoot.appendingPathComponent("cohere-transcribe", isDirectory: true)
        let tierDir = familyRoot.appendingPathComponent("q8", isDirectory: true)
        try FileManager.default.createDirectory(at: tierDir, withIntermediateDirectories: true)
        try "weights".write(to: tierDir.appendingPathComponent("model.bin"), atomically: true, encoding: .utf8)
        try "state".write(to: familyRoot.appendingPathComponent(".download-state"), atomically: true, encoding: .utf8)

        XCTAssertTrue(CohereTranscribeEngine.deleteModel(cacheRoot: tierDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tierDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: familyRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: familyRoot.appendingPathComponent(".download-state").path))
    }

    func testDownloadNemotronEnglishModelEmitsRuntimeTelemetryOnSuccess() async throws {
        let telemetry = ModelDeletionTelemetrySpy()
        Telemetry.configure(telemetry)
        defer { Telemetry.configure(NoOpTelemetryService()) }
        let modelURL = tempRoot!

        try await STTRuntime.downloadNemotronModel(
            modelVariant: .english1120,
            language: nil,
            emitTelemetry: true,
            downloader: { _, _, _ in
                modelURL
            }
        )

        let events = telemetry.snapshot()
        XCTAssertTrue(events.containsNemotronDownloadStarted(engineVariant: .english1120))
        XCTAssertTrue(events.containsNemotronDownloadCompleted(engineVariant: .english1120))
        XCTAssertTrue(events.containsNemotronDownloadOperation(outcome: .success, engineVariant: .english1120))
    }

    // MARK: - Whisper variant file removal

    func testDeleteWhisperModelRemovesFolderAndClearsOptimizedFlag() throws {
        let suite = "test.ModelDeletion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let variant = SpeechEnginePreference.defaultWhisperModelVariant
        let folder = tempRoot.appendingPathComponent(variant, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "weights".write(to: folder.appendingPathComponent("model.bin"), atomically: true, encoding: .utf8)
        SpeechEnginePreference.markWhisperOptimized(variant: variant, defaults: defaults)

        let removed = WhisperEngine.deleteModel(model: variant, downloadBase: tempRoot, defaults: defaults)

        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(SpeechEnginePreference.hasOptimizedWhisper(variant: variant, defaults: defaults))
    }

    func testDeleteWhisperModelIsNoOpWhenNotDownloaded() throws {
        let suite = "test.ModelDeletion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let removed = WhisperEngine.deleteModel(
            model: SpeechEnginePreference.defaultWhisperModelVariant,
            downloadBase: tempRoot,
            defaults: defaults
        )
        XCTAssertFalse(removed)
    }

    private func writeUnifiedModelFile(_ fileName: String, in cacheRoot: URL) throws {
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let fileURL = cacheRoot.appendingPathComponent(fileName, isDirectory: fileName.hasSuffix(".mlmodelc"))
        if fileName.hasSuffix(".mlmodelc") {
            try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        } else {
            try "{}".write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}

private final class ModelDeletionTelemetrySpy: TelemetryServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TelemetryEventSpec] = []

    func send(_ event: TelemetryEventSpec) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func sendAndFlush(_ event: TelemetryEventSpec) async -> Bool {
        send(event)
        return true
    }

    func clearQueue() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }

    func flush() async {}
    func flushForTermination() {}

    func snapshot() -> [TelemetryEventSpec] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private extension Array where Element == TelemetryEventSpec {
    func containsNemotronDownloadStarted(engineVariant expectedVariant: NemotronModelVariant) -> Bool {
        contains {
            if case .modelDownloadStarted(let modelKind, let speechEngine, let engineVariant) = $0 {
                return modelKind == .nemotronSTT
                    && speechEngine == .nemotron
                    && engineVariant == expectedVariant.rawValue
            }
            return false
        }
    }

    func containsNemotronDownloadCompleted(engineVariant expectedVariant: NemotronModelVariant) -> Bool {
        contains {
            if case .modelDownloadCompleted(_, let modelKind, let speechEngine, let engineVariant) = $0 {
                return modelKind == .nemotronSTT
                    && speechEngine == .nemotron
                    && engineVariant == expectedVariant.rawValue
            }
            return false
        }
    }

    func containsNemotronDownloadOperation(
        outcome expectedOutcome: ObservabilityOutcome,
        engineVariant expectedVariant: NemotronModelVariant
    ) -> Bool {
        contains {
            if case .modelOperation(
                _,
                _,
                let action,
                let outcome,
                let stage,
                let modelKind,
                let speechEngine,
                let engineVariant,
                _,
                let errorType
            ) = $0 {
                return action == .download
                    && outcome == expectedOutcome
                    && stage == .download
                    && modelKind == .nemotronSTT
                    && speechEngine == .nemotron
                    && engineVariant == expectedVariant.rawValue
                    && errorType == nil
            }
            return false
        }
    }
}
