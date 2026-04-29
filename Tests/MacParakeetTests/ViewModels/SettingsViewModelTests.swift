import XCTest
import CoreAudio
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
    var testDefaultsSuiteName: String!
    var entitlements: EntitlementsService!
    var youtubeDownloadsTestDir: URL!

    private func waitUntil(
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    override func setUp() {
        mockRepo = MockDictationRepository()
        mockTranscriptionRepo = MockTranscriptionRepository()
        mockPermissions = MockPermissionService()
        mockLaunchAtLogin = MockLaunchAtLoginService()
        youtubeDownloadsTestDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-youtube-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: youtubeDownloadsTestDir, withIntermediateDirectories: true)

        // Use a unique suite name for isolated UserDefaults per test
        testDefaultsSuiteName = "com.macparakeet.tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: testDefaultsSuiteName)!

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
        if let testDefaultsSuiteName {
            testDefaults.removePersistentDomain(forName: testDefaultsSuiteName)
        }
        if let youtubeDownloadsTestDir {
            try? FileManager.default.removeItem(at: youtubeDownloadsTestDir)
        }
        testDefaults = nil
        testDefaultsSuiteName = nil
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
        XCTAssertEqual(viewModel.meetingHotkeyTrigger, .chord(modifiers: ["command", "shift"], keyCode: 46))
        XCTAssertEqual(viewModel.meetingAudioSourceMode, .microphoneAndSystem)
        XCTAssertEqual(
            viewModel.selectedMicrophoneDeviceUID,
            SettingsViewModel.systemDefaultMicrophoneSelection,
            "microphone selection should default to macOS System Default"
        )
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
        testDefaults.set("usb-mic-uid", forKey: UserDefaultsAppRuntimePreferences.selectedMicrophoneDeviceUIDKey)
        testDefaults.set(
            MeetingAudioSourceMode.systemOnly.rawValue,
            forKey: UserDefaultsAppRuntimePreferences.meetingAudioSourceModeKey
        )
        HotkeyTrigger.chord(modifiers: ["control", "option"], keyCode: 46)
            .save(to: testDefaults, defaultsKey: HotkeyTrigger.meetingDefaultsKey)

        let vm = SettingsViewModel(defaults: testDefaults)

        XCTAssertTrue(vm.launchAtLogin)
        XCTAssertTrue(vm.menuBarOnlyMode)
        XCTAssertFalse(vm.showIdlePill)
        XCTAssertTrue(vm.silenceAutoStop)
        XCTAssertEqual(vm.silenceDelay, 3.0)
        XCTAssertFalse(vm.saveAudioRecordings)
        XCTAssertFalse(vm.saveTranscriptionAudio)
        XCTAssertEqual(vm.selectedMicrophoneDeviceUID, "usb-mic-uid")
        XCTAssertEqual(vm.meetingAudioSourceMode, .systemOnly)
        XCTAssertEqual(vm.meetingHotkeyTrigger, .chord(modifiers: ["control", "option"], keyCode: 46))
    }

    func testSelectedMicrophonePersistsUIDAndClearsForSystemDefault() {
        viewModel.selectedMicrophoneDeviceUID = "usb-mic-uid"

        XCTAssertEqual(
            testDefaults.string(forKey: UserDefaultsAppRuntimePreferences.selectedMicrophoneDeviceUIDKey),
            "usb-mic-uid"
        )

        viewModel.selectedMicrophoneDeviceUID = SettingsViewModel.systemDefaultMicrophoneSelection

        XCTAssertNil(testDefaults.string(forKey: UserDefaultsAppRuntimePreferences.selectedMicrophoneDeviceUIDKey))
    }

    func testSelectedMicrophoneNormalizesBlankSelectionToSystemDefault() {
        viewModel.selectedMicrophoneDeviceUID = "usb-mic-uid"
        XCTAssertEqual(
            testDefaults.string(forKey: UserDefaultsAppRuntimePreferences.selectedMicrophoneDeviceUIDKey),
            "usb-mic-uid"
        )

        viewModel.selectedMicrophoneDeviceUID = "   "

        XCTAssertEqual(viewModel.selectedMicrophoneDeviceUID, SettingsViewModel.systemDefaultMicrophoneSelection)
        XCTAssertNil(testDefaults.string(forKey: UserDefaultsAppRuntimePreferences.selectedMicrophoneDeviceUIDKey))
    }

    func testRefreshMicrophoneDevicesUsesInjectedDevicesAndMarksDefaultFirst() {
        let vm = SettingsViewModel(
            defaults: testDefaults,
            inputDevicesProvider: {
                [
                    AudioDeviceManager.InputDevice(
                        id: 20,
                        uid: "usb-alpha",
                        name: "Alpha USB Mic",
                        transportType: kAudioDeviceTransportTypeUSB
                    ),
                    AudioDeviceManager.InputDevice(
                        id: 10,
                        uid: "builtin-zed",
                        name: "Zed Built-In Mic",
                        transportType: kAudioDeviceTransportTypeBuiltIn
                    )
                ]
            },
            defaultInputDeviceUIDProvider: { "builtin-zed" }
        )

        XCTAssertEqual(vm.microphoneDeviceOptions.map(\.uid), ["builtin-zed", "usb-alpha"])
        XCTAssertEqual(vm.microphoneDeviceOptions.first?.displayName, "Zed Built-In Mic (System Default)")
        XCTAssertEqual(vm.microphoneDeviceOptions.last?.displayName, "Alpha USB Mic")
        XCTAssertEqual(vm.microphoneDeviceOptions.last?.detail, "usb")
    }

    func testRefreshMicrophoneDevicesPreservesUnavailableStoredSelection() {
        testDefaults.set("missing-usb-mic", forKey: UserDefaultsAppRuntimePreferences.selectedMicrophoneDeviceUIDKey)

        let vm = SettingsViewModel(
            defaults: testDefaults,
            inputDevicesProvider: {
                [
                    AudioDeviceManager.InputDevice(
                        id: 10,
                        uid: "builtin-zed",
                        name: "Zed Built-In Mic",
                        transportType: kAudioDeviceTransportTypeBuiltIn
                    )
                ]
            },
            defaultInputDeviceUIDProvider: { "builtin-zed" }
        )

        XCTAssertEqual(vm.selectedMicrophoneDeviceUID, "missing-usb-mic")
        XCTAssertEqual(vm.microphoneDeviceOptions.map(\.uid), ["builtin-zed", "missing-usb-mic"])
        XCTAssertEqual(vm.microphoneDeviceOptions.last?.displayName, "Selected microphone (unavailable)")
        XCTAssertEqual(
            vm.selectedMicrophoneStatusText,
            "Selected microphone is unavailable. MacParakeet will use System Default until it returns."
        )
    }

    func testMeetingAutoSaveMigratesLegacyTranscriptionSettings() {
        // setUp's vm already populated `testDefaults` for both scopes.
        // To exercise the legacy upgrade path (transcription configured,
        // meeting empty) we need a separate suite that hasn't been
        // touched by ensureFolderConfigured yet.
        let suite = "com.macparakeet.tests.legacy.\(UUID().uuidString)"
        let fresh = UserDefaults(suiteName: suite)!
        defer { fresh.removePersistentDomain(forName: suite) }

        fresh.set(true, forKey: AutoSaveService.enabledKey)
        fresh.set(AutoSaveFormat.json.rawValue, forKey: AutoSaveService.formatKey)
        AutoSaveService.storeFolder(youtubeDownloadsTestDir, defaults: fresh)

        let vm = SettingsViewModel(defaults: fresh)

        XCTAssertTrue(vm.meetingAutoSave)
        XCTAssertEqual(vm.meetingAutoSaveFormat, .json)
        XCTAssertEqual(
            vm.meetingAutoSaveFolderPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            youtubeDownloadsTestDir.standardizedFileURL.path
        )
        XCTAssertEqual(fresh.object(forKey: AutoSaveScope.meeting.enabledKey) as? Bool, true)
        XCTAssertEqual(fresh.string(forKey: AutoSaveScope.meeting.formatKey), AutoSaveFormat.json.rawValue)
        XCTAssertNotNil(fresh.data(forKey: AutoSaveScope.meeting.folderBookmarkKey))
    }

    // MARK: - Auto-save folder configuration
    //
    // The folder is always set after init — to the user's chosen folder if
    // they have one, or to the default `~/Documents/MacParakeet/...`
    // otherwise. This collapses the entire bug class around "toggle ON ·
    // no folder" because the no-folder state is unreachable in practice.

    func testInitConfiguresDefaultFoldersWhenNoneStored() {
        // setUp's `viewModel` already populated `testDefaults` via
        // ensureFolderConfigured, so use a separate suite to observe
        // the fresh-defaults case.
        let suite = "com.macparakeet.tests.fresh.\(UUID().uuidString)"
        let fresh = UserDefaults(suiteName: suite)!
        defer { fresh.removePersistentDomain(forName: suite) }

        XCTAssertNil(fresh.data(forKey: AutoSaveService.folderBookmarkKey))
        XCTAssertNil(fresh.data(forKey: AutoSaveScope.meeting.folderBookmarkKey))

        let vm = SettingsViewModel(defaults: fresh)

        XCTAssertNotNil(vm.autoSaveFolderPath)
        XCTAssertNotNil(vm.meetingAutoSaveFolderPath)
        XCTAssertTrue(vm.autoSaveFolderPath?.contains("MacParakeet/Transcriptions") ?? false)
        XCTAssertTrue(vm.meetingAutoSaveFolderPath?.contains("MacParakeet/Meetings") ?? false)
    }

    func testInitPreservesUserChosenFolder() {
        // The user previously picked a custom folder. ensureFolderConfigured
        // must not stomp it with the default.
        AutoSaveService.storeFolder(youtubeDownloadsTestDir, defaults: testDefaults)

        let vm = SettingsViewModel(defaults: testDefaults)

        XCTAssertEqual(
            vm.autoSaveFolderPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            youtubeDownloadsTestDir.standardizedFileURL.path,
            "User-chosen folders must survive init untouched."
        )
    }

    func testResetAutoSaveFolderRestoresDefault() {
        AutoSaveService.storeFolder(youtubeDownloadsTestDir, defaults: testDefaults)
        viewModel.autoSaveTranscripts = true
        viewModel.autoSaveFolderPath = youtubeDownloadsTestDir.path

        viewModel.resetAutoSaveFolder()

        XCTAssertNotNil(viewModel.autoSaveFolderPath)
        XCTAssertTrue(viewModel.autoSaveFolderPath?.contains("MacParakeet/Transcriptions") ?? false)
        XCTAssertTrue(viewModel.autoSaveTranscripts, "Reset must not silently disable the toggle.")
    }

    func testResetMeetingAutoSaveFolderRestoresDefault() {
        AutoSaveService.storeFolder(youtubeDownloadsTestDir, scope: .meeting, defaults: testDefaults)
        viewModel.meetingAutoSave = true
        viewModel.meetingAutoSaveFolderPath = youtubeDownloadsTestDir.path

        viewModel.resetMeetingAutoSaveFolder()

        XCTAssertNotNil(viewModel.meetingAutoSaveFolderPath)
        XCTAssertTrue(viewModel.meetingAutoSaveFolderPath?.contains("MacParakeet/Meetings") ?? false)
        XCTAssertTrue(viewModel.meetingAutoSave)
    }

    func testEnsureFolderConfiguredIsIdempotent() {
        // Running ensureFolderConfigured twice on fresh defaults must
        // produce the same path — the second call should see the first
        // call's bookmark and not re-create or move the folder.
        let suite = "com.macparakeet.tests.idempotent.\(UUID().uuidString)"
        let fresh = UserDefaults(suiteName: suite)!
        defer { fresh.removePersistentDomain(forName: suite) }

        let first = AutoSaveService.ensureFolderConfigured(scope: .transcription, defaults: fresh)
        let second = AutoSaveService.ensureFolderConfigured(scope: .transcription, defaults: fresh)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(first?.standardizedFileURL.path, second?.standardizedFileURL.path)
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

    func testMeetingHotkeyPersistsToDedicatedDefaultsKey() {
        let trigger = HotkeyTrigger.chord(modifiers: ["control", "option"], keyCode: 46)
        viewModel.meetingHotkeyTrigger = trigger

        XCTAssertEqual(
            HotkeyTrigger.current(defaults: testDefaults, defaultsKey: HotkeyTrigger.meetingDefaultsKey),
            trigger
        )
    }

    func testMeetingAudioSourceModePersists() {
        viewModel.meetingAudioSourceMode = .systemOnly

        XCTAssertEqual(
            testDefaults.string(forKey: UserDefaultsAppRuntimePreferences.meetingAudioSourceModeKey),
            MeetingAudioSourceMode.systemOnly.rawValue
        )
    }

    func testMeetingHotkeyPostsNotificationOnChange() {
        let expectation = expectation(
            forNotification: Notification.Name("macparakeet.meetingHotkeyTriggerDidChange"),
            object: nil
        )
        viewModel.meetingHotkeyTrigger = .chord(modifiers: ["control", "option"], keyCode: 46)
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - File/YouTube Transcription Hotkeys

    func testTranscriptionHotkeysDefaultToDisabled() {
        XCTAssertEqual(viewModel.fileTranscriptionHotkeyTrigger, .disabled)
        XCTAssertEqual(viewModel.youtubeTranscriptionHotkeyTrigger, .disabled)
    }

    func testFileTranscriptionHotkeyPersistsToDedicatedDefaultsKey() {
        let trigger = HotkeyTrigger.chord(modifiers: ["control", "shift"], keyCode: 3) // F
        viewModel.fileTranscriptionHotkeyTrigger = trigger

        XCTAssertEqual(
            HotkeyTrigger.current(
                defaults: testDefaults,
                defaultsKey: HotkeyTrigger.fileTranscriptionDefaultsKey,
                fallback: .disabled
            ),
            trigger
        )
    }

    func testYouTubeTranscriptionHotkeyPersistsToDedicatedDefaultsKey() {
        let trigger = HotkeyTrigger.chord(modifiers: ["control", "shift"], keyCode: 16) // Y
        viewModel.youtubeTranscriptionHotkeyTrigger = trigger

        XCTAssertEqual(
            HotkeyTrigger.current(
                defaults: testDefaults,
                defaultsKey: HotkeyTrigger.youtubeTranscriptionDefaultsKey,
                fallback: .disabled
            ),
            trigger
        )
    }

    func testFileTranscriptionHotkeyPostsNotificationOnChange() {
        let expectation = expectation(
            forNotification: Notification.Name("macparakeet.fileTranscriptionHotkeyTriggerDidChange"),
            object: nil
        )
        viewModel.fileTranscriptionHotkeyTrigger = .chord(modifiers: ["control", "shift"], keyCode: 3)
        wait(for: [expectation], timeout: 1.0)
    }

    func testYouTubeTranscriptionHotkeyPostsNotificationOnChange() {
        let expectation = expectation(
            forNotification: Notification.Name("macparakeet.youtubeTranscriptionHotkeyTriggerDidChange"),
            object: nil
        )
        viewModel.youtubeTranscriptionHotkeyTrigger = .chord(modifiers: ["control", "shift"], keyCode: 16)
        wait(for: [expectation], timeout: 1.0)
    }

    func testTranscriptionHotkeysLoadFromUserDefaults() {
        let fileTrigger = HotkeyTrigger.chord(modifiers: ["control", "shift"], keyCode: 3)
        let youtubeTrigger = HotkeyTrigger.chord(modifiers: ["control", "shift"], keyCode: 16)
        fileTrigger.save(to: testDefaults, defaultsKey: HotkeyTrigger.fileTranscriptionDefaultsKey)
        youtubeTrigger.save(to: testDefaults, defaultsKey: HotkeyTrigger.youtubeTranscriptionDefaultsKey)

        let vm = SettingsViewModel(defaults: testDefaults)

        XCTAssertEqual(vm.fileTranscriptionHotkeyTrigger, fileTrigger)
        XCTAssertEqual(vm.youtubeTranscriptionHotkeyTrigger, youtubeTrigger)
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
        mockPermissions.screenRecordingPermission = true

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
        XCTAssertTrue(viewModel.screenRecordingGranted)
    }

    func testRefreshPermissionsUpdatesNotGrantedState() async throws {
        mockPermissions.microphonePermission = .denied
        mockPermissions.accessibilityPermission = false
        mockPermissions.screenRecordingPermission = false

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
        XCTAssertFalse(viewModel.screenRecordingGranted)
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

    func testClearAllDictationsAlsoDeletesPrivateRows() {
        // "Clear All" must wipe both visible and hidden (metric-only) rows.
        var hidden = Dictation(durationMs: 4000, rawTranscript: "")
        hidden.hidden = true
        mockRepo.dictations = [
            Dictation(durationMs: 1000, rawTranscript: "Visible"),
            hidden,
        ]

        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            checkoutURL: nil
        )

        viewModel.clearAllDictations()

        XCTAssertTrue(mockRepo.deleteAllCalled, "deleteAll() must run")
        XCTAssertTrue(mockRepo.deleteHiddenCalled, "deleteHidden() must run too — 'All' means all")
        XCTAssertTrue(mockRepo.dictations.isEmpty, "no dictation rows survive Clear All")
    }

    // MARK: - Reset Lifetime Stats (#124)

    func testResetLifetimeStatsCallsRepo() {
        mockRepo.dictations = [
            Dictation(durationMs: 1000, rawTranscript: "One"),
        ]

        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            checkoutURL: nil
        )

        var stateChangedFireCount = 0
        viewModel.onDictationStateChanged = { stateChangedFireCount += 1 }

        viewModel.resetLifetimeStats()

        XCTAssertTrue(mockRepo.resetLifetimeStatsCalled)
        XCTAssertFalse(mockRepo.deleteAllCalled, "Reset should not delete dictation rows")
        XCTAssertEqual(viewModel.dictationCount, 1, "Dictation count must survive lifetime reset")
        XCTAssertEqual(
            stateChangedFireCount, 1,
            "onDictationStateChanged must fire once so dependent views (e.g. history) reload derived stats"
        )
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

    func testResetLifetimeStatsBeforeConfigureIsNoOp() {
        // Should not crash
        viewModel.resetLifetimeStats()
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

    func testRefreshModelStatusMarksActiveWhisperReady() async throws {
        SpeechEnginePreference.whisper.save(to: testDefaults)
        let vm = SettingsViewModel(
            defaults: testDefaults,
            youtubeDownloadsDirPath: { [youtubeDownloadsTestDir] in
                youtubeDownloadsTestDir?.path ?? AppPaths.youtubeDownloadsDir
            },
            isSpeechModelCached: { true }
        )
        let stt = MockSTTClient()
        await stt.setReady(true)

        vm.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            checkoutURL: nil,
            sttClient: stt
        )

        try await waitUntil { vm.whisperModelStatus == .ready }
        XCTAssertEqual(vm.whisperModelStatusDetail, "Whisper Large v3 Turbo · Loaded in memory and ready.")
        XCTAssertEqual(vm.parakeetStatus, .notLoaded)
        XCTAssertEqual(vm.parakeetStatusDetail, "Downloaded. Loads automatically when needed.")
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

    func testWhisperDefaultLanguagePersistsNormalizedValue() {
        viewModel.whisperDefaultLanguage = "KO_kr"
        XCTAssertEqual(SpeechEnginePreference.whisperDefaultLanguage(defaults: testDefaults), "ko")

        viewModel.whisperDefaultLanguage = "auto"
        XCTAssertNil(SpeechEnginePreference.whisperDefaultLanguage(defaults: testDefaults))
    }

    func testSpeechEngineChangeCallsSwitcherAndPersistsOnSuccess() async throws {
        let switcher = MockSpeechEngineSwitcher()
        viewModel.whisperModelStatus = .notLoaded
        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            checkoutURL: nil,
            speechEngineSwitcher: switcher
        )

        viewModel.whisperModelStatus = .notLoaded
        viewModel.speechEnginePreference = .whisper
        try await waitForSpeechEngineSwitchingToFinish()

        let preferences = await switcher.preferences
        XCTAssertEqual(preferences, [.whisper])
        XCTAssertEqual(SpeechEnginePreference.current(defaults: testDefaults), .whisper)
        XCTAssertFalse(viewModel.speechEngineSwitching)
        XCTAssertNil(viewModel.speechEngineError)
    }

    func testSpeechEngineChangeRevertsWhenSwitcherFails() async throws {
        let switcher = MockSpeechEngineSwitcher(error: STTError.engineBusy)
        viewModel.whisperModelStatus = .notLoaded
        viewModel.configure(
            permissionService: mockPermissions,
            dictationRepo: mockRepo,
            entitlementsService: entitlements,
            checkoutURL: nil,
            speechEngineSwitcher: switcher
        )

        viewModel.whisperModelStatus = .notLoaded
        viewModel.speechEnginePreference = .whisper
        try await waitForSpeechEngineSwitchingToFinish()

        XCTAssertEqual(viewModel.speechEnginePreference, .parakeet)
        XCTAssertEqual(SpeechEnginePreference.current(defaults: testDefaults), .parakeet)
        XCTAssertEqual(viewModel.speechEngineError, STTError.engineBusy.localizedDescription)
    }

    private func waitForSpeechEngineSwitchingToFinish(
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let start = ContinuousClock.now
        while viewModel.speechEngineSwitching {
            if start.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for speech engine switch to finish", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
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

private actor MockSpeechEngineSwitcher: SpeechEngineSwitching {
    private let error: Error?
    private(set) var preferences: [SpeechEnginePreference] = []

    init(error: Error? = nil) {
        self.error = error
    }

    func setSpeechEngine(_ preference: SpeechEnginePreference) async throws {
        preferences.append(preference)
        if let error {
            throw error
        }
    }
}
