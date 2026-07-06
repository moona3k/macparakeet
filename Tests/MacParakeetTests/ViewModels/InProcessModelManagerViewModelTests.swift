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

    init(isDownloaded: Bool = false, hasArtifacts: Bool? = nil) {
        self.isDownloaded = isDownloaded
        self.hasArtifacts = hasArtifacts ?? isDownloaded
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

    func verifyDefaultModel() async throws -> URL {
        verifyCalls += 1
        isDownloaded = true
        return defaultModelDirectory()
    }

    func downloadDefaultModel(
        progress: @escaping InProcessModelDownloadProgressHandler
    ) async throws -> URL {
        downloadCalls += 1
        isDownloaded = true
        hasArtifacts = true
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
