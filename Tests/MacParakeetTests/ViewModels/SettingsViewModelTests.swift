import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class SettingsViewModelTests: XCTestCase {
    var viewModel: SettingsViewModel!
    var mockRepo: MockDictationRepository!
    var mockTranscriptionRepo: MockTranscriptionRepository!
    var mockPermissions: MockPermissionService!
    var mockLaunchAtLogin: MockLaunchAtLoginService!
    var testDefaults: UserDefaults!
    var entitlements: EntitlementsService!
    var youtubeDownloadsTestDir: URL!

    override func setUp() {
        mockRepo = MockDictationRepository()
        mockTranscriptionRepo = MockTranscriptionRepository()
        mockPermissions = MockPermissionService()
        mockLaunchAtLogin = MockLaunchAtLoginService()
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
        XCTAssertFalse(viewModel.menuBarOnlyMode, "menuBarOnlyMode should default to false")
        XCTAssertTrue(viewModel.showIdlePill, "showIdlePill should default to true")
        XCTAssertFalse(viewModel.silenceAutoStop, "silenceAutoStop should default to false")
        XCTAssertEqual(viewModel.silenceDelay, 2.0, "silenceDelay should default to 2.0")
        XCTAssertTrue(viewModel.saveAudioRecordings, "saveAudioRecordings should default to true")
        XCTAssertTrue(viewModel.saveTranscriptionAudio, "saveTranscriptionAudio should default to true")
    }

    func testInitLoadsFromUserDefaults() {
        // Set values in defaults before creating ViewModel
        testDefaults.set(true, forKey: "launchAtLogin")
        testDefaults.set(true, forKey: AppPreferences.menuBarOnlyModeKey)
        testDefaults.set(false, forKey: "showIdlePill")
        testDefaults.set(true, forKey: "silenceAutoStop")
        testDefaults.set(3.0, forKey: "silenceDelay")
        testDefaults.set(false, forKey: "saveAudioRecordings")
        testDefaults.set(false, forKey: "saveTranscriptionAudio")

        let vm = SettingsViewModel(defaults: testDefaults)

        XCTAssertTrue(vm.launchAtLogin)
        XCTAssertTrue(vm.menuBarOnlyMode)
        XCTAssertFalse(vm.showIdlePill)
        XCTAssertTrue(vm.silenceAutoStop)
        XCTAssertEqual(vm.silenceDelay, 3.0)
        XCTAssertFalse(vm.saveAudioRecordings)
        XCTAssertFalse(vm.saveTranscriptionAudio)
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

    func testConfigureSyncsLaunchAtLoginFromServiceStatus() {
        testDefaults.set(false, forKey: "launchAtLogin")
        mockLaunchAtLogin.status = .enabled

        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            launchAtLoginService: mockLaunchAtLogin,
            checkoutURL: nil
        )

        XCTAssertTrue(viewModel.launchAtLogin)
        XCTAssertEqual(viewModel.launchAtLoginDetail, "MacParakeet will open automatically when you sign in.")
    }

    func testSettingLaunchAtLoginCallsService() {
        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            launchAtLoginService: mockLaunchAtLogin,
            checkoutURL: nil
        )

        viewModel.launchAtLogin = true

        XCTAssertEqual(mockLaunchAtLogin.setEnabledCalls, [true])
        XCTAssertTrue(viewModel.launchAtLogin)
        XCTAssertNil(viewModel.launchAtLoginError)
    }

    func testSettingLaunchAtLoginRevertsAndShowsErrorWhenServiceFails() {
        mockLaunchAtLogin.errorToThrow = LaunchAtLoginError.invalidSignature

        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            launchAtLoginService: mockLaunchAtLogin,
            checkoutURL: nil
        )

        viewModel.launchAtLogin = true

        XCTAssertEqual(mockLaunchAtLogin.setEnabledCalls, [true])
        XCTAssertFalse(viewModel.launchAtLogin)
        XCTAssertEqual(viewModel.launchAtLoginError, LaunchAtLoginError.invalidSignature.localizedDescription)
    }

    func testSettingMenuBarOnlyModePersists() {
        viewModel.menuBarOnlyMode = true

        XCTAssertTrue(testDefaults.bool(forKey: AppPreferences.menuBarOnlyModeKey))
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

    func testShowIdlePillDefaultsToTrue() {
        // Fresh defaults with no key set — should default to true (existing users keep pill visible)
        let vm = SettingsViewModel(defaults: testDefaults)
        XCTAssertTrue(vm.showIdlePill)
    }

    func testShowIdlePillPersistsToUserDefaults() {
        viewModel.showIdlePill = false
        XCTAssertFalse(testDefaults.bool(forKey: "showIdlePill"))

        viewModel.showIdlePill = true
        XCTAssertTrue(testDefaults.bool(forKey: "showIdlePill"))
    }

    func testShowIdlePillPostsNotificationOnChange() {
        let expectation = expectation(forNotification: Notification.Name("macparakeet.showIdlePillDidChange"), object: nil)
        viewModel.showIdlePill = false
        wait(for: [expectation], timeout: 1.0)
    }

    func testProcessingModePersists() {
        viewModel.processingMode = Dictation.ProcessingMode.clean.rawValue
        XCTAssertEqual(testDefaults.string(forKey: "processingMode"), Dictation.ProcessingMode.clean.rawValue)
    }

    func testInvalidProcessingModeFallsBackToRaw() {
        viewModel.processingMode = "invalid-mode"
        XCTAssertEqual(viewModel.processingMode, Dictation.ProcessingMode.raw.rawValue)
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

    // MARK: - Local Models

    func testRefreshModelStatusMarksSpeechNotDownloadedWhenCacheMissing() async throws {
        let vm = SettingsViewModel(
            defaults: testDefaults,
            youtubeDownloadsDirPath: { [youtubeDownloadsTestDir] in
                youtubeDownloadsTestDir?.path ?? AppPaths.youtubeDownloadsDir
            },
            isSpeechModelCached: { false }
        )
        let stt = MockSTTClient()
        await stt.setReady(false)

        vm.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            checkoutURL: nil,
            sttClient: stt
        )

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(vm.parakeetStatus, .notDownloaded)
    }

    func testRepairParakeetModelUsesRetryAndEndsReady() async throws {
        let vm = SettingsViewModel(
            defaults: testDefaults,
            youtubeDownloadsDirPath: { [youtubeDownloadsTestDir] in
                youtubeDownloadsTestDir?.path ?? AppPaths.youtubeDownloadsDir
            },
            isSpeechModelCached: { true }
        )
        let stt = MockSTTClient()
        await stt.setReady(false)
        await stt.configureWarmUpFailuresBeforeSuccess(2)

        vm.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            checkoutURL: nil,
            sttClient: stt
        )

        vm.repairParakeetModel()
        try await Task.sleep(for: .milliseconds(1300))

        let warmUpCallCount = await stt.warmUpCallCount
        XCTAssertEqual(warmUpCallCount, 3)
        XCTAssertFalse(vm.parakeetRepairing)
        XCTAssertEqual(vm.parakeetStatus, .ready)
    }

    // MARK: - Hotkey Trigger

    func testHotkeyTriggerDefaultsToFn() {
        XCTAssertEqual(viewModel.hotkeyTrigger, .fn)
    }

    func testHotkeyTriggerPersistsKeyCode() {
        let endKey = HotkeyTrigger.fromKeyCode(119)
        viewModel.hotkeyTrigger = endKey

        let vm2 = SettingsViewModel(defaults: testDefaults)
        XCTAssertEqual(vm2.hotkeyTrigger, endKey)
        XCTAssertEqual(vm2.hotkeyTrigger.displayName, "End")
    }

    func testHotkeyTriggerPersistsModifier() {
        viewModel.hotkeyTrigger = .control

        let vm2 = SettingsViewModel(defaults: testDefaults)
        XCTAssertEqual(vm2.hotkeyTrigger, .control)
    }

    func testHotkeyTriggerBackwardCompatibleWithLegacyString() {
        // Simulate a legacy UserDefaults value from the old TriggerKey enum
        testDefaults.set("option", forKey: "hotkeyTrigger")

        let vm = SettingsViewModel(defaults: testDefaults)
        XCTAssertEqual(vm.hotkeyTrigger, .option)
        XCTAssertEqual(vm.hotkeyTrigger.displayName, "Option")
    }

    // MARK: - Round-trip

    func testSettingsRoundTrip() {
        // Set everything to non-default values
        viewModel.launchAtLogin = true
        viewModel.menuBarOnlyMode = true
        viewModel.showIdlePill = false
        viewModel.silenceAutoStop = true
        viewModel.silenceDelay = 5.0
        viewModel.saveAudioRecordings = false
        viewModel.saveTranscriptionAudio = false

        // Create a new ViewModel reading from the same defaults
        let vm2 = SettingsViewModel(defaults: testDefaults)

        XCTAssertTrue(vm2.launchAtLogin)
        XCTAssertTrue(vm2.menuBarOnlyMode)
        XCTAssertFalse(vm2.showIdlePill)
        XCTAssertTrue(vm2.silenceAutoStop)
        XCTAssertEqual(vm2.silenceDelay, 5.0)
        XCTAssertFalse(vm2.saveAudioRecordings)
        XCTAssertFalse(vm2.saveTranscriptionAudio)
    }
}
