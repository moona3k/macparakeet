import MacParakeetCore
@testable import MacParakeet
import XCTest

final class AppEnvironmentTests: XCTestCase {
    func testWarmCaptureSuppressionUsesTheActiveInputRoute() {
        let systemDefaultAttempts: [MeetingInputDeviceAttempt] = [
            .implicitSystemDefault(resolvedDeviceID: 20),
            MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
        ]
        XCTAssertTrue(AppEnvironment.shouldSuppressWarmCapture(
            deviceAttempts: systemDefaultAttempts,
            isBluetoothInput: { $0 == 20 }
        ))

        let namedMicAttempts: [MeetingInputDeviceAttempt] = [
            MeetingInputDeviceAttempt(source: .selected(uid: "usb-mic"), deviceID: 10),
            .implicitSystemDefault(resolvedDeviceID: 20),
        ]
        XCTAssertFalse(AppEnvironment.shouldSuppressWarmCapture(
            deviceAttempts: namedMicAttempts,
            isBluetoothInput: { $0 == 20 }
        ))

        XCTAssertTrue(AppEnvironment.shouldSuppressWarmCapture(
            deviceAttempts: [.implicitSystemDefault(resolvedDeviceID: nil)],
            isBluetoothInput: { _ in false }
        ))

        XCTAssertTrue(
            AppEnvironment.shouldSuppressWarmCapture(
                deviceAttempts: [.implicitSystemDefault(resolvedDeviceID: 20)],
                isBluetoothInput: { _ in nil }
            ),
            "Unresolved transport/topology must not acquire an idle microphone"
        )
    }

    func testCohereDictationRoutingDisablesLiveAndDisplayPreview() {
        XCTAssertFalse(AppEnvironment.shouldAttemptLiveDictationTranscription(
            speechEngine: .cohere,
            liveDictationStreamingEnabled: true
        ))
        XCTAssertNil(AppEnvironment.dictationPreviewSpeechEngine(
            speechEngine: .cohere,
            liveDictationStreamingEnabled: true
        ))
    }

    func testParakeetDictationRoutingUsesVariantCapabilities() {
        XCTAssertFalse(AppEnvironment.shouldAttemptLiveDictationTranscription(
            speechEngine: .parakeet,
            parakeetModelVariant: .v3,
            liveDictationStreamingEnabled: true
        ))
        let tdtPreview = AppEnvironment.dictationPreviewSpeechEngine(
            speechEngine: .parakeet,
            parakeetModelVariant: .v3,
            liveDictationStreamingEnabled: true
        )
        XCTAssertEqual(tdtPreview?.selection, SpeechEngineSelection(engine: .parakeet))
        XCTAssertEqual(tdtPreview?.capabilities.key, .parakeet(.v3))

        XCTAssertTrue(AppEnvironment.shouldAttemptLiveDictationTranscription(
            speechEngine: .parakeet,
            parakeetModelVariant: .unified,
            liveDictationStreamingEnabled: true
        ))
        XCTAssertNil(AppEnvironment.dictationPreviewSpeechEngine(
            speechEngine: .parakeet,
            parakeetModelVariant: .unified,
            liveDictationStreamingEnabled: true
        ))
    }

    func testStandaloneCleanupAvailabilitySurvivesStartupSync() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockLLMConfigStore()
        store.taskOverrides[.cleanup] = .appleIntelligence()
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey)

        AppEnvironment.syncAIFormatterAvailabilityWithLLMConfiguration(defaults: defaults, configStore: store)

        XCTAssertTrue(defaults.bool(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey))
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey))
        store.taskOverrides = [:]
        AppEnvironment.syncAIFormatterAvailabilityWithLLMConfiguration(defaults: defaults, configStore: store)
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey))
    }

    func testSyncAIFormatterAvailabilityUsesRouteMetadataWhenCredentialsAreBlocked() throws {
        let (_, defaults) = makeDefaults()
        let domain = makeIsolatedDefaultsSuite("AppEnvironmentTests-routes-")
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
            .appendingPathComponent("routes.lock")
        addTeardownBlock { try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent()) }
        let credentials = InMemoryKeyValueStore()
        let store = LLMConfigStore(preferencesDomain: domain, lockURL: lockURL, keychain: credentials)
        try store.saveTaskOverride(.openai(apiKey: "saved-key", model: "gpt-5.5"), for: .cleanup)
        credentials.getError = KeyValueStoreError.unsupported
        let readsBeforeSync = credentials.readCount

        AppEnvironment.syncAIFormatterAvailabilityWithLLMConfiguration(defaults: defaults, configStore: store)

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey) as? Bool,
            true
        )
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey) as? Bool,
            false
        )
        XCTAssertEqual(credentials.readCount, readsBeforeSync)
    }

    func testSyncAIFormatterAvailabilityWritesTrueWhenProviderExists() {
        let (_, defaults) = makeDefaults()
        let configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test")

        AppEnvironment.syncAIFormatterAvailabilityWithLLMConfiguration(
            defaults: defaults,
            configStore: configStore
        )

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey) as? Bool,
            true
        )
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey) as? Bool,
            false
        )
    }

    func testSyncAIFormatterAvailabilityOverwritesLegacyExplicitFalseWhenProviderExists() {
        let (_, defaults) = makeDefaults()
        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        let configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test")

        AppEnvironment.syncAIFormatterAvailabilityWithLLMConfiguration(
            defaults: defaults,
            configStore: configStore
        )

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey) as? Bool,
            true
        )
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey) as? Bool,
            false
        )
    }

    func testSyncAIFormatterAvailabilityDoesNotMigrateLegacyExplicitFalseOnSecondRun() {
        let (_, defaults) = makeDefaults()
        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        let configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test")

        AppEnvironment.syncAIFormatterAvailabilityWithLLMConfiguration(
            defaults: defaults,
            configStore: configStore
        )
        AppEnvironment.syncAIFormatterAvailabilityWithLLMConfiguration(
            defaults: defaults,
            configStore: configStore
        )

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey) as? Bool,
            true
        )
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey) as? Bool,
            false
        )
    }

    func testSyncAIFormatterAvailabilityDoesNotMigrateNewProviderOnSecondRun() {
        let (_, defaults) = makeDefaults()
        let configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test")

        AppEnvironment.syncAIFormatterAvailabilityWithLLMConfiguration(
            defaults: defaults,
            configStore: configStore
        )
        AppEnvironment.syncAIFormatterAvailabilityWithLLMConfiguration(
            defaults: defaults,
            configStore: configStore
        )

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey) as? Bool,
            true
        )
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey) as? Bool,
            false
        )
    }

    func testSyncAIFormatterAvailabilityMigratesLegacyExplicitTrueToDictationPreference() {
        let (_, defaults) = makeDefaults()
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        let configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test")

        AppEnvironment.syncAIFormatterAvailabilityWithLLMConfiguration(
            defaults: defaults,
            configStore: configStore
        )

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey) as? Bool,
            true
        )
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey) as? Bool,
            true
        )
    }

    func testSyncAIFormatterAvailabilityPreservesExistingDictationPreference() {
        let (_, defaults) = makeDefaults()
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey)
        let configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test")

        AppEnvironment.syncAIFormatterAvailabilityWithLLMConfiguration(
            defaults: defaults,
            configStore: configStore
        )

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey) as? Bool,
            true
        )
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey) as? Bool,
            false
        )
    }

    func testSyncAIFormatterAvailabilityPreservesExistingTranscriptionPreference() {
        let (_, defaults) = makeDefaults()
        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForTranscriptionsKey)
        let configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test")

        AppEnvironment.syncAIFormatterAvailabilityWithLLMConfiguration(
            defaults: defaults,
            configStore: configStore
        )

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey) as? Bool,
            true
        )
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForTranscriptionsKey) as? Bool,
            false
        )
    }

    func testSyncAIFormatterAvailabilityRemovesPreferenceWithoutProvider() {
        let (_, defaults) = makeDefaults()
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        let configStore = MockLLMConfigStore()

        AppEnvironment.syncAIFormatterAvailabilityWithLLMConfiguration(
            defaults: defaults,
            configStore: configStore
        )

        XCTAssertNil(defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey))
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey) as? Bool,
            false
        )
    }

    private func makeDefaults() -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = makeIsolatedDefaultsSuite("AppEnvironmentTests-")
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
