import MacParakeetCore
@testable import MacParakeet
import XCTest

final class AppEnvironmentTests: XCTestCase {
    func testEnableAIFormatterByDefaultWhenLLMConfiguredWritesTrueWhenPreferenceUnset() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test")

        AppEnvironment.enableAIFormatterByDefaultWhenLLMConfigured(
            defaults: defaults,
            configStore: configStore
        )

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey) as? Bool,
            true
        )
    }

    func testEnableAIFormatterByDefaultWhenLLMConfiguredPreservesExplicitFalse() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        let configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test")

        AppEnvironment.enableAIFormatterByDefaultWhenLLMConfigured(
            defaults: defaults,
            configStore: configStore
        )

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey) as? Bool,
            false
        )
    }

    func testEnableAIFormatterByDefaultWhenLLMConfiguredLeavesPreferenceUnsetWithoutProvider() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configStore = MockLLMConfigStore()

        AppEnvironment.enableAIFormatterByDefaultWhenLLMConfigured(
            defaults: defaults,
            configStore: configStore
        )

        XCTAssertNil(defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey))
    }

    private func makeDefaults() -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "AppEnvironmentTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
