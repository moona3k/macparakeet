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
        XCTAssertTrue(events.containsNemotronDownloadStarted)
        XCTAssertTrue(events.containsNemotronDownloadCompleted)
        XCTAssertTrue(events.containsNemotronDownloadOperation(outcome: .success))
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
    var containsNemotronDownloadStarted: Bool {
        contains {
            if case .modelDownloadStarted(let modelKind, let speechEngine, let engineVariant) = $0 {
                return modelKind == .nemotronSTT
                    && speechEngine == .nemotron
                    && engineVariant == NemotronModelVariant.multilingual1120.rawValue
            }
            return false
        }
    }

    var containsNemotronDownloadCompleted: Bool {
        contains {
            if case .modelDownloadCompleted(_, let modelKind, let speechEngine, let engineVariant) = $0 {
                return modelKind == .nemotronSTT
                    && speechEngine == .nemotron
                    && engineVariant == NemotronModelVariant.multilingual1120.rawValue
            }
            return false
        }
    }

    func containsNemotronDownloadOperation(outcome expectedOutcome: ObservabilityOutcome) -> Bool {
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
                    && engineVariant == NemotronModelVariant.multilingual1120.rawValue
                    && errorType == nil
            }
            return false
        }
    }
}
