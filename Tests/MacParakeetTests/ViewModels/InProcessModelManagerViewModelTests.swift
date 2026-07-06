import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class InProcessModelManagerViewModelTests: XCTestCase {
    func testEnableLocalAIGatedBelowMinimumMemory() async {
        let downloader = FakeInProcessModelDownloader()
        let configStore = MockLLMConfigStore()
        let client = MockLLMClient()
        let viewModel = InProcessModelManagerViewModel(physicalMemoryBytes: 8 * 1024 * 1024 * 1024)
        viewModel.configure(
            downloader: downloader,
            configStore: configStore,
            llmClient: client,
            physicalMemoryBytes: 8 * 1024 * 1024 * 1024
        )

        await viewModel.enableLocalAI()

        XCTAssertEqual(
            viewModel.state,
            .failed(
                reason: "Local AI needs 16 GB RAM. Use a cloud provider or bring your own local server instead.",
                recoverable: false
            )
        )
        let downloadCallCount = await downloader.downloadCallCount()
        XCTAssertEqual(downloadCallCount, 0)
        XCTAssertNil(configStore.config)
    }

    func testEnableLocalAIGatedWhenRuntimeUnavailable() async {
        let downloader = FakeInProcessModelDownloader()
        let configStore = MockLLMConfigStore()
        let client = MockLLMClient()
        client.supportsInProcessLocalLLM = false
        let viewModel = InProcessModelManagerViewModel()
        viewModel.configure(
            downloader: downloader,
            configStore: configStore,
            llmClient: client,
            physicalMemoryBytes: 32 * 1024 * 1024 * 1024
        )

        await viewModel.enableLocalAI()

        guard case .failed(let reason, let recoverable) = viewModel.state else {
            return XCTFail("Expected failed state")
        }
        XCTAssertTrue(reason.contains("does not include the MLX runtime"))
        XCTAssertFalse(recoverable)
        let downloadCallCount = await downloader.downloadCallCount()
        XCTAssertEqual(downloadCallCount, 0)
        XCTAssertNil(configStore.config)
    }

    func testEnableLocalAIDownloadsVerifiesTestsAndSavesProvider() async {
        let downloader = FakeInProcessModelDownloader()
        let configStore = MockLLMConfigStore()
        let client = MockLLMClient()
        var configurationChangedCount = 0
        let viewModel = InProcessModelManagerViewModel()
        viewModel.configure(
            downloader: downloader,
            configStore: configStore,
            llmClient: client,
            physicalMemoryBytes: 32 * 1024 * 1024 * 1024,
            onConfigurationChanged: { configurationChangedCount += 1 }
        )

        await viewModel.enableLocalAI()

        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertTrue(viewModel.isModelDownloaded)
        let downloadCallCount = await downloader.downloadCallCount()
        let verifyCallCount = await downloader.verifyCallCount()
        XCTAssertEqual(downloadCallCount, 1)
        XCTAssertEqual(verifyCallCount, 0)
        XCTAssertEqual(configStore.config?.id, .inProcessLocal)
        XCTAssertEqual(configStore.config?.modelName, InProcessLocalModelCatalog.defaultManifest.modelID)
        XCTAssertEqual(client.capturedContext?.providerConfig.id, .inProcessLocal)
        XCTAssertEqual(configurationChangedCount, 1)
    }

    func testEnableLocalAIPassesDiskPreflightBeforeDownload() async {
        let remainingBytes: UInt64 = 1_000
        let downloader = FakeInProcessModelDownloader(remainingDownloadBytes: remainingBytes)
        let configStore = MockLLMConfigStore()
        let client = MockLLMClient()
        let diskSpaceProbe = DiskSpaceProbe(
            availableBytes: remainingBytes + InProcessModelManagerViewModel.diskSafetyMarginBytes
        )
        let viewModel = InProcessModelManagerViewModel()
        viewModel.configure(
            downloader: downloader,
            configStore: configStore,
            llmClient: client,
            physicalMemoryBytes: 32 * 1024 * 1024 * 1024,
            availableDiskSpaceBytes: { [diskSpaceProbe] url in diskSpaceProbe.capacity(for: url) }
        )

        await viewModel.enableLocalAI()

        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertEqual(diskSpaceProbe.queriedURL(), downloader.defaultModelDirectory())
        let downloadCallCount = await downloader.downloadCallCount()
        XCTAssertEqual(downloadCallCount, 1)
    }

    func testEnableLocalAIFailsDiskPreflightBeforeDownload() async {
        let remainingBytes: UInt64 = 2_000_000_000
        let availableBytes: UInt64 = 1_000_000_000
        let downloader = FakeInProcessModelDownloader(remainingDownloadBytes: remainingBytes)
        let configStore = MockLLMConfigStore()
        let client = MockLLMClient()
        let viewModel = InProcessModelManagerViewModel()
        viewModel.configure(
            downloader: downloader,
            configStore: configStore,
            llmClient: client,
            physicalMemoryBytes: 32 * 1024 * 1024 * 1024,
            availableDiskSpaceBytes: { _ in availableBytes }
        )

        await viewModel.enableLocalAI()

        guard case .failed(let reason, let recoverable) = viewModel.state else {
            return XCTFail("Expected failed state")
        }
        XCTAssertTrue(reason.contains("Not enough free disk space"))
        XCTAssertTrue(
            reason.contains(
                InProcessModelManagerViewModel.formatBytes(
                    remainingBytes + InProcessModelManagerViewModel.diskSafetyMarginBytes
                )
            )
        )
        XCTAssertTrue(reason.contains(InProcessModelManagerViewModel.formatBytes(availableBytes)))
        XCTAssertTrue(recoverable)
        let downloadCallCount = await downloader.downloadCallCount()
        XCTAssertEqual(downloadCallCount, 0)
        XCTAssertNil(configStore.config)
    }

    func testEnableLocalAIFailsWhenDiskPreflightCannotReadCapacity() async {
        let downloader = FakeInProcessModelDownloader(remainingDownloadBytes: 1_000)
        let configStore = MockLLMConfigStore()
        let client = MockLLMClient()
        let viewModel = InProcessModelManagerViewModel()
        viewModel.configure(
            downloader: downloader,
            configStore: configStore,
            llmClient: client,
            physicalMemoryBytes: 32 * 1024 * 1024 * 1024,
            availableDiskSpaceBytes: { _ in nil }
        )

        await viewModel.enableLocalAI()

        guard case .failed(let reason, let recoverable) = viewModel.state else {
            return XCTFail("Expected failed state")
        }
        XCTAssertTrue(reason.contains("Unable to check free disk space"))
        XCTAssertTrue(reason.contains("retry"))
        XCTAssertTrue(recoverable)
        let downloadCallCount = await downloader.downloadCallCount()
        XCTAssertEqual(downloadCallCount, 0)
    }

    func testEnableLocalAIDoesNotSaveWhenRuntimeTestFails() async {
        let downloader = FakeInProcessModelDownloader()
        let configStore = MockLLMConfigStore()
        let client = MockLLMClient()
        client.testConnectionError = LLMError.connectionFailed("runtime unavailable")
        let viewModel = InProcessModelManagerViewModel()
        viewModel.configure(
            downloader: downloader,
            configStore: configStore,
            llmClient: client,
            physicalMemoryBytes: 32 * 1024 * 1024 * 1024
        )

        await viewModel.enableLocalAI()

        XCTAssertNil(configStore.config)
        guard case .failed(let reason, let recoverable) = viewModel.state else {
            return XCTFail("Expected failed state")
        }
        XCTAssertTrue(reason.contains("runtime unavailable"))
        XCTAssertTrue(reason.contains("generation test failed"))
        XCTAssertTrue(reason.contains("Retry setup"))
        XCTAssertTrue(recoverable)
    }

    func testDownloadFailureShowsRetryRecoveryCopy() async {
        let downloader = FakeInProcessModelDownloader(downloadError: URLError(.notConnectedToInternet))
        let configStore = MockLLMConfigStore()
        let client = MockLLMClient()
        let viewModel = InProcessModelManagerViewModel()
        viewModel.configure(
            downloader: downloader,
            configStore: configStore,
            llmClient: client,
            physicalMemoryBytes: 32 * 1024 * 1024 * 1024
        )

        await viewModel.enableLocalAI()

        guard case .failed(let reason, let recoverable) = viewModel.state else {
            return XCTFail("Expected failed state")
        }
        XCTAssertTrue(reason.contains("Local AI download failed"))
        XCTAssertTrue(reason.contains("Check your network connection"))
        XCTAssertTrue(reason.contains("retry"))
        XCTAssertTrue(recoverable)
    }

    func testRefreshBelowMinimumMemoryStillReportsDownloadedModel() async {
        let downloader = FakeInProcessModelDownloader(isDownloaded: true)
        let viewModel = InProcessModelManagerViewModel()
        viewModel.configure(
            downloader: downloader,
            configStore: MockLLMConfigStore(),
            llmClient: MockLLMClient(),
            physicalMemoryBytes: 8 * 1024 * 1024 * 1024
        )

        await viewModel.refresh()

        XCTAssertTrue(viewModel.isModelDownloaded)
        XCTAssertFalse(viewModel.meetsMemoryRequirement)
    }

    func testCancelSetupDuringDownloadReportsCanceledStateAndSavesNothing() async throws {
        let downloader = BlockingInProcessModelDownloader()
        let configStore = MockLLMConfigStore()
        let viewModel = InProcessModelManagerViewModel()
        viewModel.configure(
            downloader: downloader,
            configStore: configStore,
            llmClient: MockLLMClient(),
            physicalMemoryBytes: 32 * 1024 * 1024 * 1024
        )

        viewModel.startEnableLocalAI()
        while !(await downloader.hasStartedDownload()) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        viewModel.cancelSetup()

        let deadline = Date().addingTimeInterval(10)
        while viewModel.isWorking, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(
            viewModel.state,
            .failed(reason: "Local AI setup was canceled.", recoverable: true)
        )
        XCTAssertNil(configStore.config)
    }

    func testRefreshDuringActiveSetupKeepsDownloadingState() async throws {
        let downloader = BlockingInProcessModelDownloader()
        let viewModel = InProcessModelManagerViewModel()
        viewModel.configure(
            downloader: downloader,
            configStore: MockLLMConfigStore(),
            llmClient: MockLLMClient(),
            physicalMemoryBytes: 32 * 1024 * 1024 * 1024
        )

        viewModel.startEnableLocalAI()
        while !(await downloader.hasStartedDownload()) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        await viewModel.refresh()

        guard case .downloading = viewModel.state else {
            return XCTFail("Expected downloading state, got \(viewModel.state)")
        }

        viewModel.cancelSetup()
        let deadline = Date().addingTimeInterval(10)
        while viewModel.isWorking, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func testRefreshSurfacesPartialArtifactsAndDeleteClearsThem() async {
        let downloader = FakeInProcessModelDownloader(isDownloaded: false, hasArtifacts: true)
        let viewModel = InProcessModelManagerViewModel()
        viewModel.configure(
            downloader: downloader,
            configStore: MockLLMConfigStore(),
            llmClient: MockLLMClient(),
            physicalMemoryBytes: 32 * 1024 * 1024 * 1024
        )

        await viewModel.refresh()

        XCTAssertFalse(viewModel.isModelDownloaded)
        XCTAssertTrue(viewModel.hasModelArtifacts)

        await viewModel.deleteModel()

        XCTAssertFalse(viewModel.hasModelArtifacts)
        XCTAssertEqual(viewModel.state, .setUpNeeded)
    }

    func testDeleteModelClearsSavedLocalProvider() async {
        let downloader = FakeInProcessModelDownloader(isDownloaded: true)
        let configStore = MockLLMConfigStore()
        configStore.config = .inProcessLocal()
        let client = MockLLMClient()
        let viewModel = InProcessModelManagerViewModel()
        viewModel.configure(
            downloader: downloader,
            configStore: configStore,
            llmClient: client,
            physicalMemoryBytes: 32 * 1024 * 1024 * 1024
        )
        await viewModel.refresh()

        await viewModel.deleteModel()

        XCTAssertEqual(viewModel.state, .setUpNeeded)
        XCTAssertFalse(viewModel.isModelDownloaded)
        XCTAssertNil(configStore.config)
        let deleteCallCount = await downloader.deleteCallCount()
        XCTAssertEqual(deleteCallCount, 1)
    }

    func testDeleteModelRunsDeletionInsideClientRemovalGate() async throws {
        let downloader = FakeInProcessModelDownloader(isDownloaded: true, cacheSizeBytes: 123)
        let configStore = MockLLMConfigStore()
        configStore.config = .inProcessLocal()
        let client = MockLLMClient()
        client.holdInProcessModelRemoval = true
        let viewModel = InProcessModelManagerViewModel()
        viewModel.configure(
            downloader: downloader,
            configStore: configStore,
            llmClient: client,
            physicalMemoryBytes: 32 * 1024 * 1024 * 1024
        )
        await viewModel.refresh()

        let deleteTask = Task { await viewModel.deleteModel() }
        let deadline = Date().addingTimeInterval(5)
        while client.inProcessModelRemovalCallCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(client.inProcessModelRemovalCallCount, 1)
        let deleteCallCountBeforeRelease = await downloader.deleteCallCount()
        XCTAssertEqual(deleteCallCountBeforeRelease, 0)

        client.releaseInProcessModelRemoval()
        await deleteTask.value

        let deleteCallCountAfterRelease = await downloader.deleteCallCount()
        XCTAssertEqual(deleteCallCountAfterRelease, 1)
        XCTAssertNil(configStore.config)
        XCTAssertEqual(viewModel.modelCacheSizeBytes, 0)
    }

    func testRefreshFormatsDownloadedModelCacheSize() async {
        let cacheSizeBytes: UInt64 = 2_513_288_145
        let downloader = FakeInProcessModelDownloader(isDownloaded: true, cacheSizeBytes: cacheSizeBytes)
        let viewModel = InProcessModelManagerViewModel()
        viewModel.configure(
            downloader: downloader,
            configStore: MockLLMConfigStore(),
            llmClient: MockLLMClient(),
            physicalMemoryBytes: 32 * 1024 * 1024 * 1024
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.modelCacheSizeBytes, cacheSizeBytes)
        XCTAssertEqual(
            viewModel.modelCacheSizeDescription,
            InProcessModelManagerViewModel.formatBytes(cacheSizeBytes)
        )
    }
}

private final class DiskSpaceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let availableBytes: UInt64?
    private var capturedURL: URL?

    init(availableBytes: UInt64?) {
        self.availableBytes = availableBytes
    }

    func capacity(for url: URL) -> UInt64? {
        lock.lock()
        capturedURL = url
        lock.unlock()
        return availableBytes
    }

    func queriedURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return capturedURL
    }
}

private actor BlockingInProcessModelDownloader: InProcessModelDownloading {
    private var downloadStarted = false

    nonisolated func defaultModelDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BlockingInProcessModelDownloader", isDirectory: true)
    }

    func isDefaultModelDownloaded() async -> Bool {
        false
    }

    func hasDefaultModelArtifacts() async -> Bool {
        downloadStarted
    }

    func defaultModelCacheSizeBytes() async -> UInt64 {
        downloadStarted ? 1 : 0
    }

    func remainingDefaultModelDownloadBytes() async throws -> UInt64 {
        0
    }

    func verifyDefaultModel() async throws -> URL {
        defaultModelDirectory()
    }

    func downloadDefaultModel(
        progress: @escaping InProcessModelDownloadProgressHandler
    ) async throws -> URL {
        downloadStarted = true
        while true {
            try Task.checkCancellation()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func deleteDefaultModel() async throws {}

    func hasStartedDownload() -> Bool {
        downloadStarted
    }
}

private actor FakeInProcessModelDownloader: InProcessModelDownloading {
    private var isDownloaded: Bool
    private var hasArtifacts: Bool
    private var downloadCalls = 0
    private var verifyCalls = 0
    private var deleteCalls = 0
    private var remainingDownloadBytes: UInt64
    private var cacheSizeBytes: UInt64
    private var downloadError: Error?

    init(
        isDownloaded: Bool = false,
        hasArtifacts: Bool? = nil,
        remainingDownloadBytes: UInt64 = 0,
        cacheSizeBytes: UInt64 = 0,
        downloadError: Error? = nil
    ) {
        self.isDownloaded = isDownloaded
        self.hasArtifacts = hasArtifacts ?? isDownloaded
        self.remainingDownloadBytes = remainingDownloadBytes
        self.cacheSizeBytes = cacheSizeBytes
        self.downloadError = downloadError
    }

    nonisolated func defaultModelDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeInProcessModelDownloader", isDirectory: true)
    }

    func isDefaultModelDownloaded() async -> Bool {
        isDownloaded
    }

    func hasDefaultModelArtifacts() async -> Bool {
        hasArtifacts
    }

    func defaultModelCacheSizeBytes() async -> UInt64 {
        cacheSizeBytes
    }

    func remainingDefaultModelDownloadBytes() async throws -> UInt64 {
        remainingDownloadBytes
    }

    func verifyDefaultModel() async throws -> URL {
        verifyCalls += 1
        isDownloaded = true
        return defaultModelDirectory()
    }

    func downloadDefaultModel(
        progress: @escaping InProcessModelDownloadProgressHandler
    ) async throws -> URL {
        downloadCalls += 1
        if let downloadError {
            throw downloadError
        }
        isDownloaded = true
        hasArtifacts = true
        remainingDownloadBytes = 0
        cacheSizeBytes = max(cacheSizeBytes, 1)
        await progress(
            InProcessModelDownloadProgress(
                completedBytes: 1,
                totalBytes: 1,
                completedFiles: 1,
                totalFiles: 1,
                currentFile: "model.safetensors"
            ))
        return defaultModelDirectory()
    }

    func deleteDefaultModel() async throws {
        deleteCalls += 1
        isDownloaded = false
        hasArtifacts = false
        cacheSizeBytes = 0
    }

    func downloadCallCount() -> Int {
        downloadCalls
    }

    func verifyCallCount() -> Int {
        verifyCalls
    }

    func deleteCallCount() -> Int {
        deleteCalls
    }
}
