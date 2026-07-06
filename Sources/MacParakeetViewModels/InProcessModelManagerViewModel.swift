import Foundation
import MacParakeetCore

public typealias InProcessModelAvailableDiskSpaceProvider = @Sendable (URL) throws -> UInt64?

public enum InProcessModelDiskSpace {
    public static func availableCapacityForImportantUsage(at directory: URL) throws -> UInt64? {
        let volumeURL = existingAncestor(for: directory)
        let values = try volumeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage, capacity >= 0 else {
            return nil
        }
        return UInt64(capacity)
    }

    private static func existingAncestor(for url: URL, fileManager: FileManager = .default) -> URL {
        var candidate = url.standardizedFileURL
        var isDirectory = ObjCBool(false)
        while !fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return candidate }
            candidate = parent
        }
        return isDirectory.boolValue ? candidate : candidate.deletingLastPathComponent()
    }
}

@MainActor
@Observable
public final class InProcessModelManagerViewModel {
    public enum State: Equatable {
        case setUpNeeded
        case downloading(progress: Double)
        case verifying
        case ready
        case failed(reason: String, recoverable: Bool)
    }

    public nonisolated static let minimumPhysicalMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024
    public nonisolated static let diskSafetyMarginBytes: UInt64 = 500 * 1000 * 1000

    public private(set) var state: State = .setUpNeeded
    public private(set) var progress: InProcessModelDownloadProgress?
    public private(set) var isModelDownloaded = false
    public private(set) var hasModelArtifacts = false
    public private(set) var modelCacheSizeBytes: UInt64 = 0
    public private(set) var isWorking = false

    private var downloader: (any InProcessModelDownloading)?
    private var configStore: (any LLMConfigStoreProtocol)?
    private var llmClient: (any LLMClientProtocol)?
    private var onConfigurationChanged: (() -> Void)?
    private var physicalMemoryBytes: UInt64
    @ObservationIgnored
    private var availableDiskSpaceBytes: InProcessModelAvailableDiskSpaceProvider =
        { try InProcessModelDiskSpace.availableCapacityForImportantUsage(at: $0) }
    private var isRuntimeAvailable = false
    private var setupTask: Task<Void, Never>?

    public init(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    public func configure(
        downloader: any InProcessModelDownloading = InProcessModelDownloader(),
        configStore: any LLMConfigStoreProtocol,
        llmClient: any LLMClientProtocol,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        availableDiskSpaceBytes: @escaping InProcessModelAvailableDiskSpaceProvider =
            { try InProcessModelDiskSpace.availableCapacityForImportantUsage(at: $0) },
        onConfigurationChanged: (() -> Void)? = nil
    ) {
        self.downloader = downloader
        self.configStore = configStore
        self.llmClient = llmClient
        self.physicalMemoryBytes = physicalMemoryBytes
        self.availableDiskSpaceBytes = availableDiskSpaceBytes
        self.isRuntimeAvailable = llmClient.supportsInProcessLocalLLM
        self.onConfigurationChanged = onConfigurationChanged
        refreshSelectionState()
    }

    public var meetsMemoryRequirement: Bool {
        physicalMemoryBytes >= Self.minimumPhysicalMemoryBytes
    }

    public var minimumMemoryDescription: String {
        "16 GB RAM"
    }

    public var modelDisplayName: String {
        InProcessLocalModelCatalog.defaultManifest.displayName
    }

    public var modelSizeDescription: String {
        Self.formatBytes(InProcessLocalModelCatalog.defaultManifest.totalBytes)
    }

    public var modelCacheSizeDescription: String {
        Self.formatBytes(modelCacheSizeBytes)
    }

    public private(set) var isLocalAISelected = false

    public func refreshSelectionState() {
        let config = try? configStore?.loadConfig()
        isLocalAISelected = config?.id == .inProcessLocal
    }

    public func refresh() async {
        guard setupTask == nil else { return }
        refreshSelectionState()
        guard let downloader else {
            state = .setUpNeeded
            modelCacheSizeBytes = 0
            return
        }
        isModelDownloaded = await downloader.isDefaultModelDownloaded()
        hasModelArtifacts = await downloader.hasDefaultModelArtifacts()
        modelCacheSizeBytes = await downloader.defaultModelCacheSizeBytes()
        guard setupTask == nil else { return }
        state = isModelDownloaded ? .ready : .setUpNeeded
    }

    public var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    public func startEnableLocalAI() {
        guard setupTask == nil else { return }
        setupTask = Task {
            await enableLocalAI()
            setupTask = nil
        }
    }

    public func cancelSetup() {
        setupTask?.cancel()
    }

    public func enableLocalAI() async {
        guard let downloader, let configStore, let llmClient else {
            state = .failed(reason: "Local AI setup is not configured yet.", recoverable: true)
            return
        }
        guard isRuntimeAvailable else {
            state = .failed(
                reason:
                    "Local AI is enabled by a developer override, but this app build does not include the MLX runtime. Use a gated MLX build to test it.",
                recoverable: false
            )
            return
        }
        guard meetsMemoryRequirement else {
            state = .failed(
                reason:
                    "Local AI needs \(minimumMemoryDescription). Use a cloud provider or bring your own local server instead.",
                recoverable: false
            )
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            try await runDiskSpacePreflight(downloader: downloader)

            state = .downloading(progress: 0)
            progress = nil
            _ = try await downloader.downloadDefaultModel { [weak self] progress in
                await self?.updateDownloadProgress(progress)
            }
            isModelDownloaded = true
            hasModelArtifacts = true
            modelCacheSizeBytes = await downloader.defaultModelCacheSizeBytes()

            state = .verifying

            let config = LLMProviderConfig.inProcessLocal(
                model: InProcessLocalModelCatalog.defaultManifest.modelID
            )
            try await llmClient.testConnection(context: LLMExecutionContext(providerConfig: config))
            try configStore.saveConfig(config)
            refreshSelectionState()

            state = .ready
            onConfigurationChanged?()
        } catch is CancellationError {
            state = .failed(reason: "Local AI setup was canceled.", recoverable: true)
            hasModelArtifacts = await downloader.hasDefaultModelArtifacts()
            modelCacheSizeBytes = await downloader.defaultModelCacheSizeBytes()
        } catch {
            state = .failed(reason: Self.recoveryMessage(for: error, state: state), recoverable: true)
            hasModelArtifacts = await downloader.hasDefaultModelArtifacts()
            modelCacheSizeBytes = await downloader.defaultModelCacheSizeBytes()
        }
    }

    public func deleteModel() async {
        guard let downloader else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            if let llmClient {
                try await llmClient.withInProcessLocalModelRemoval {
                    try await downloader.deleteDefaultModel()
                }
            } else {
                try await downloader.deleteDefaultModel()
            }
            isModelDownloaded = false
            hasModelArtifacts = false
            modelCacheSizeBytes = 0
            progress = nil
            refreshSelectionState()
            if isLocalAISelected {
                try configStore?.deleteConfig()
                refreshSelectionState()
                onConfigurationChanged?()
            }
            state = .setUpNeeded
        } catch {
            state = .failed(reason: error.localizedDescription, recoverable: true)
        }
    }

    private func runDiskSpacePreflight(downloader: any InProcessModelDownloading) async throws {
        let remainingBytes = try await downloader.remainingDefaultModelDownloadBytes()
        guard remainingBytes > 0 else { return }

        let requiredBytes = remainingBytes.addingReportingOverflow(Self.diskSafetyMarginBytes)
        let required = requiredBytes.overflow ? UInt64.max : requiredBytes.partialValue
        let cacheDirectory = downloader.defaultModelDirectory()
        guard let availableBytes = try availableDiskSpaceBytes(cacheDirectory) else {
            throw InProcessModelSetupError.diskSpaceUnavailable(requiredBytes: required)
        }
        guard availableBytes >= required else {
            throw InProcessModelSetupError.insufficientDiskSpace(
                requiredBytes: required,
                availableBytes: availableBytes
            )
        }
    }

    public nonisolated static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
            countStyle: .file
        )
    }

    private nonisolated static func recoveryMessage(for error: Error, state: State) -> String {
        if let setupError = error as? InProcessModelSetupError {
            return setupError.localizedDescription
        }

        let detail = error.localizedDescription
        switch state {
        case .downloading:
            return "Local AI download failed: \(detail) Check your network connection, then retry."
        case .verifying:
            return
                "Local AI downloaded, but the generation test failed: \(detail) Retry setup. If it keeps failing, choose another AI provider."
        case .setUpNeeded:
            return "Local AI setup failed before download: \(detail) Fix the issue, then retry."
        case .ready:
            return "Local AI setup failed while saving configuration: \(detail) Retry setup."
        case .failed:
            return detail
        }
    }

    fileprivate func updateDownloadProgress(_ progress: InProcessModelDownloadProgress) {
        guard case .downloading = state else { return }
        self.progress = progress
        state = .downloading(progress: progress.fractionCompleted)
    }
}

private enum InProcessModelSetupError: LocalizedError {
    case diskSpaceUnavailable(requiredBytes: UInt64)
    case insufficientDiskSpace(requiredBytes: UInt64, availableBytes: UInt64)

    var errorDescription: String? {
        switch self {
        case .diskSpaceUnavailable(let requiredBytes):
            return
                "Unable to check free disk space for Local AI setup. Verify at least \(InProcessModelManagerViewModel.formatBytes(requiredBytes)) is available, then retry."
        case .insufficientDiskSpace(let requiredBytes, let availableBytes):
            return
                "Not enough free disk space for Local AI setup. Need \(InProcessModelManagerViewModel.formatBytes(requiredBytes)); available: \(InProcessModelManagerViewModel.formatBytes(availableBytes)). Free up space, then retry."
        }
    }
}
