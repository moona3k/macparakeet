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
        XCTAssertEqual(verifyCallCount, 1)
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

private actor FakeInProcessModelDownloader: InProcessModelDownloading {
    private var isDownloaded: Bool
    private var downloadCalls = 0
    private var verifyCalls = 0
    private var deleteCalls = 0

    init(isDownloaded: Bool = false) {
        self.isDownloaded = isDownloaded
    }

    nonisolated func defaultModelDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeInProcessModelDownloader", isDirectory: true)
    }

    func isDefaultModelDownloaded() async -> Bool {
        isDownloaded
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
        await progress(InProcessModelDownloadProgress(
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
