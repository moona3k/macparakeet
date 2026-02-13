import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class SettingsViewModelTests: XCTestCase {
    var viewModel: SettingsViewModel!
    var mockRepo: MockDictationRepository!
    var mockTranscriptionRepo: MockTranscriptionRepository!
    var mockPermissions: MockPermissionService!
    var testDefaults: UserDefaults!
    var entitlements: EntitlementsService!
    var youtubeDownloadsTestDir: URL!

    override func setUp() {
        mockRepo = MockDictationRepository()
        mockTranscriptionRepo = MockTranscriptionRepository()
        mockPermissions = MockPermissionService()
        youtubeDownloadsTestDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-youtube-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: youtubeDownloadsTestDir, withIntermediateDirectories: true)

        // Use a unique suite name for isolated UserDefaults per test
        let suiteName = "com.macparakeet.tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!

        viewModel = SettingsViewModel(
            defaults: testDefaults,
            youtubeDownloadsDirPath: { [youtubeDownloadsTestDir] in
                youtubeDownloadsTestDir?.path ?? AppPaths.youtubeDownloadsDir
            }
        )

        entitlements = EntitlementsService(
            config: LicensingConfig(checkoutURL: nil, expectedVariantID: nil),
            store: InMemoryKeyValueStore(),
            api: StubLicenseAPI()
        )
    }

    override func tearDown() {
        // Clean up the test UserDefaults suite
        if let suiteName = testDefaults.volatileDomainNames.first {
            testDefaults.removePersistentDomain(forName: suiteName)
        }
        if let youtubeDownloadsTestDir {
            try? FileManager.default.removeItem(at: youtubeDownloadsTestDir)
        }
        testDefaults = nil
    }

    // MARK: - Initial Values

    func testDefaultValues() {
        XCTAssertFalse(viewModel.launchAtLogin, "launchAtLogin should default to false")
        XCTAssertFalse(viewModel.silenceAutoStop, "silenceAutoStop should default to false")
        XCTAssertEqual(viewModel.silenceDelay, 2.0, "silenceDelay should default to 2.0")
        XCTAssertTrue(viewModel.saveAudioRecordings, "saveAudioRecordings should default to true")
        XCTAssertTrue(viewModel.saveTranscriptionAudio, "saveTranscriptionAudio should default to true")
        XCTAssertTrue(viewModel.autoUpdateYouTubeEngine, "autoUpdateYouTubeEngine should default to true")
    }

    func testInitLoadsFromUserDefaults() {
        // Set values in defaults before creating ViewModel
        testDefaults.set(true, forKey: "launchAtLogin")
        testDefaults.set(true, forKey: "silenceAutoStop")
        testDefaults.set(3.0, forKey: "silenceDelay")
        testDefaults.set(false, forKey: "saveAudioRecordings")
        testDefaults.set(false, forKey: "saveTranscriptionAudio")
        testDefaults.set(false, forKey: "autoUpdateYouTubeEngine")

        let vm = SettingsViewModel(defaults: testDefaults)

        XCTAssertTrue(vm.launchAtLogin)
        XCTAssertTrue(vm.silenceAutoStop)
        XCTAssertEqual(vm.silenceDelay, 3.0)
        XCTAssertFalse(vm.saveAudioRecordings)
        XCTAssertFalse(vm.saveTranscriptionAudio)
        XCTAssertFalse(vm.autoUpdateYouTubeEngine)
    }

    func testSilenceDelayDefaultsTo2WhenZero() {
        // When silenceDelay is not set, double(forKey:) returns 0, which should default to 2.0
        let vm = SettingsViewModel(defaults: testDefaults)
        XCTAssertEqual(vm.silenceDelay, 2.0)
    }

    // MARK: - Saving Settings

    func testSettingLaunchAtLoginPersists() {
        viewModel.launchAtLogin = true

        XCTAssertTrue(testDefaults.bool(forKey: "launchAtLogin"))
    }

    func testSettingSilenceAutoStopPersists() {
        viewModel.silenceAutoStop = true

        XCTAssertTrue(testDefaults.bool(forKey: "silenceAutoStop"))
    }

    func testSettingSilenceDelayPersists() {
        viewModel.silenceDelay = 5.0

        XCTAssertEqual(testDefaults.double(forKey: "silenceDelay"), 5.0)
    }

    func testSettingSaveAudioRecordingsPersists() {
        viewModel.saveAudioRecordings = false

        XCTAssertFalse(testDefaults.bool(forKey: "saveAudioRecordings"))
    }

    func testSettingSaveTranscriptionAudioPersists() {
        viewModel.saveTranscriptionAudio = false

        XCTAssertFalse(testDefaults.bool(forKey: "saveTranscriptionAudio"))
    }

    func testSettingAutoUpdateYouTubeEnginePersists() {
        viewModel.autoUpdateYouTubeEngine = false

        XCTAssertFalse(testDefaults.bool(forKey: "autoUpdateYouTubeEngine"))
    }

    // MARK: - Permissions

    func testRefreshPermissionsUpdatesGrantedState() async throws {
        mockPermissions.microphonePermission = .granted
        mockPermissions.accessibilityPermission = true

        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            checkoutURL: nil
        )

        // refreshPermissions uses Task internally, wait for it
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(viewModel.microphoneGranted)
        XCTAssertTrue(viewModel.accessibilityGranted)
    }

    func testRefreshPermissionsUpdatesNotGrantedState() async throws {
        mockPermissions.microphonePermission = .denied
        mockPermissions.accessibilityPermission = false

        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            checkoutURL: nil
        )

        // refreshPermissions uses Task internally, wait for it
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(viewModel.microphoneGranted)
        XCTAssertFalse(viewModel.accessibilityGranted)
    }

    func testMicrophoneNotDeterminedIsNotGranted() async throws {
        mockPermissions.microphonePermission = .notDetermined

        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            checkoutURL: nil
        )

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(viewModel.microphoneGranted, "notDetermined should not be treated as granted")
    }

    // MARK: - Stats

    func testRefreshStatsUpdatesCount() {
        mockRepo.dictations = [
            Dictation(durationMs: 1000, rawTranscript: "One"),
            Dictation(durationMs: 2000, rawTranscript: "Two"),
            Dictation(durationMs: 3000, rawTranscript: "Three"),
        ]

        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            checkoutURL: nil
        )

        XCTAssertEqual(viewModel.dictationCount, 3)
    }

    func testRefreshStatsEmptyRepo() {
        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            checkoutURL: nil
        )

        XCTAssertEqual(viewModel.dictationCount, 0)
    }

    // MARK: - Clear All Dictations

    func testClearAllDictationsCallsRepo() {
        mockRepo.dictations = [
            Dictation(durationMs: 1000, rawTranscript: "One"),
            Dictation(durationMs: 2000, rawTranscript: "Two"),
        ]

        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            checkoutURL: nil
        )
        XCTAssertEqual(viewModel.dictationCount, 2)

        viewModel.clearAllDictations()

        XCTAssertTrue(mockRepo.deleteAllCalled)
        XCTAssertEqual(viewModel.dictationCount, 0, "Count should be 0 after clearing")
    }

    func testClearAllDictationsRefreshesStats() {
        mockRepo.dictations = [
            Dictation(durationMs: 1000, rawTranscript: "Test"),
        ]

        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            checkoutURL: nil
        )
        XCTAssertEqual(viewModel.dictationCount, 1)

        viewModel.clearAllDictations()

        XCTAssertEqual(viewModel.dictationCount, 0)
    }

    // MARK: - Unconfigured

    func testRefreshStatsBeforeConfigureIsNoOp() {
        viewModel.refreshStats()
        XCTAssertEqual(viewModel.dictationCount, 0)
    }

    func testClearAllBeforeConfigureIsNoOp() {
        // Should not crash
        viewModel.clearAllDictations()
        XCTAssertEqual(viewModel.dictationCount, 0)
    }

    // MARK: - YouTube Audio Storage

    func testRefreshStatsIncludesYouTubeDownloadStorage() throws {
        let fileA = youtubeDownloadsTestDir.appendingPathComponent("a.m4a")
        let fileB = youtubeDownloadsTestDir.appendingPathComponent("b.webm")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileA.path, contents: Data(repeating: 0x1, count: 1024)))
        XCTAssertTrue(FileManager.default.createFile(atPath: fileB.path, contents: Data(repeating: 0x2, count: 2048)))

        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            transcriptionRepo: mockTranscriptionRepo,
            entitlementsService: entitlements,
            checkoutURL: nil
        )

        XCTAssertEqual(viewModel.youtubeDownloadCount, 2)
        XCTAssertGreaterThan(viewModel.youtubeDownloadStorageMB, 0)
    }

    func testClearDownloadedYouTubeAudioRemovesFilesAndClearsStoredPaths() throws {
        let file = youtubeDownloadsTestDir.appendingPathComponent("a.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 0x1, count: 512)))

        let ytTranscription = Transcription(
            fileName: "yt",
            filePath: file.path,
            status: .completed,
            sourceURL: "https://youtu.be/dQw4w9WgXcQ"
        )
        mockTranscriptionRepo.transcriptions = [ytTranscription]

        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            transcriptionRepo: mockTranscriptionRepo,
            entitlementsService: entitlements,
            checkoutURL: nil
        )

        viewModel.clearDownloadedYouTubeAudio()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(viewModel.youtubeDownloadCount, 0)
        XCTAssertEqual(mockTranscriptionRepo.transcriptions.first?.filePath, nil)
    }

    // MARK: - Round-trip

    func testSettingsRoundTrip() {
        // Set everything to non-default values
        viewModel.launchAtLogin = true
        viewModel.silenceAutoStop = true
        viewModel.silenceDelay = 5.0
        viewModel.saveAudioRecordings = false
        viewModel.saveTranscriptionAudio = false
        viewModel.autoUpdateYouTubeEngine = false

        // Create a new ViewModel reading from the same defaults
        let vm2 = SettingsViewModel(defaults: testDefaults)

        XCTAssertTrue(vm2.launchAtLogin)
        XCTAssertTrue(vm2.silenceAutoStop)
        XCTAssertEqual(vm2.silenceDelay, 5.0)
        XCTAssertFalse(vm2.saveAudioRecordings)
        XCTAssertFalse(vm2.saveTranscriptionAudio)
        XCTAssertFalse(vm2.autoUpdateYouTubeEngine)
    }
}
