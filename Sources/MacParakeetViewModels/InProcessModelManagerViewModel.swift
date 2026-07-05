import Foundation
import MacParakeetCore

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

    public static let minimumPhysicalMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024

    public private(set) var state: State = .setUpNeeded
    public private(set) var progress: InProcessModelDownloadProgress?
    public private(set) var isModelDownloaded = false
    public private(set) var isWorking = false

    private var downloader: (any InProcessModelDownloading)?
    private var configStore: (any LLMConfigStoreProtocol)?
    private var llmClient: (any LLMClientProtocol)?
    private var onConfigurationChanged: (() -> Void)?
    private var physicalMemoryBytes: UInt64

    public init(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    public func configure(
        downloader: any InProcessModelDownloading = InProcessModelDownloader(),
        configStore: any LLMConfigStoreProtocol,
        llmClient: any LLMClientProtocol,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        onConfigurationChanged: (() -> Void)? = nil
    ) {
        self.downloader = downloader
        self.configStore = configStore
        self.llmClient = llmClient
        self.physicalMemoryBytes = physicalMemoryBytes
        self.onConfigurationChanged = onConfigurationChanged
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
        ByteCountFormatter.string(
            fromByteCount: Int64(InProcessLocalModelCatalog.defaultManifest.totalBytes),
            countStyle: .file
        )
    }

    public var isLocalAISelected: Bool {
        guard let config = try? configStore?.loadConfig() else { return false }
        return config.id == .inProcessLocal
    }

    public func refresh() async {
        guard meetsMemoryRequirement else {
            isModelDownloaded = false
            state = .setUpNeeded
            return
        }
        guard let downloader else {
            state = .setUpNeeded
            return
        }
        isModelDownloaded = await downloader.isDefaultModelDownloaded()
        state = isModelDownloaded ? .ready : .setUpNeeded
    }

    public func enableLocalAI() async {
        guard meetsMemoryRequirement else {
            state = .failed(
                reason: "Local AI needs \(minimumMemoryDescription). Use a cloud provider or bring your own local server instead.",
                recoverable: false
            )
            return
        }
        guard let downloader, let configStore, let llmClient else {
            state = .failed(reason: "Local AI setup is not configured yet.", recoverable: true)
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            state = .downloading(progress: 0)
            progress = nil
            let progressSink = InProcessModelProgressSink(viewModel: self)
            _ = try await downloader.downloadDefaultModel { progress in
                await progressSink.update(progress)
            }

            state = .verifying
            _ = try await downloader.verifyDefaultModel()
            isModelDownloaded = true

            let config = LLMProviderConfig.inProcessLocal(
                model: InProcessLocalModelCatalog.defaultManifest.modelID
            )
            try await llmClient.testConnection(context: LLMExecutionContext(providerConfig: config))
            try configStore.saveConfig(config)

            state = .ready
            onConfigurationChanged?()
        } catch is CancellationError {
            state = .failed(reason: "Local AI setup was canceled.", recoverable: true)
        } catch {
            state = .failed(reason: error.localizedDescription, recoverable: true)
        }
    }

    public func deleteModel() async {
        guard let downloader else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            try await downloader.deleteDefaultModel()
            isModelDownloaded = false
            progress = nil
            if isLocalAISelected {
                try configStore?.deleteConfig()
                onConfigurationChanged?()
            }
            state = .setUpNeeded
        } catch {
            state = .failed(reason: error.localizedDescription, recoverable: true)
        }
    }

    fileprivate func updateDownloadProgress(_ progress: InProcessModelDownloadProgress) {
        guard case .downloading = state else { return }
        self.progress = progress
        state = .downloading(progress: progress.fractionCompleted)
    }
}

private final class InProcessModelProgressSink: @unchecked Sendable {
    weak var viewModel: InProcessModelManagerViewModel?

    init(viewModel: InProcessModelManagerViewModel) {
        self.viewModel = viewModel
    }

    @MainActor
    func update(_ progress: InProcessModelDownloadProgress) {
        viewModel?.updateDownloadProgress(progress)
    }
}
