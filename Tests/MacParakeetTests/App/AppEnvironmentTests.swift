import MacParakeetCore
@testable import MacParakeet
import XCTest

final class AppEnvironmentTests: XCTestCase {
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

    func testSyncAIFormatterAvailabilityWritesTrueWhenProviderExists() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        let suiteName = "AppEnvironmentTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
