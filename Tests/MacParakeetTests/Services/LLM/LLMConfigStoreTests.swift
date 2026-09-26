import CoreFoundation
import Darwin
import XCTest
@testable import MacParakeetCore

final class LLMConfigStoreTests: XCTestCase {
    var store: LLMConfigStore!
    var keychain: InMemoryKeyValueStore!
    var routeLockURL: URL!
    var defaults: UserDefaults!
    var suiteName: String!

    override func setUp() {
        keychain = InMemoryKeyValueStore()
        suiteName = UUID().uuidString
        routeLockURL = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName).appendingPathComponent(
            "routes.lock")
        defaults = UserDefaults(suiteName: suiteName)!
        store = LLMConfigStore(preferencesDomain: suiteName, lockURL: routeLockURL, keychain: keychain)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: routeLockURL.deletingLastPathComponent())
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testBusyMutationsCannotReadRotateOrDeleteCredentials() throws {
        try store.saveConfig(.openai(apiKey: "working-key", model: "working"))
        let keys = RouteFailingKeys()
        let blocked = LLMConfigStore(preferencesDomain: suiteName, lockURL: routeLockURL, keychain: keys)
        let fd = open(routeLockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return XCTFail("Could not open fixture lock") }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let replacement = LLMProviderConfig.openai(apiKey: "replacement", model: "replacement")
        let operations: [() throws -> Void] = [
            { try blocked.saveConfig(replacement) },
            { try blocked.saveTaskOverride(replacement, for: .analysis) },
            { try blocked.saveConfiguration(replacement, cleanupOverride: nil, analysisOverride: nil) },
            { try blocked.deleteConfig() },
            { try blocked.saveAPIKey("replacement") },
            { try blocked.deleteAPIKey() },
        ]
        for operation in operations {
            XCTAssertThrowsError(try operation()) { error in
                guard case LLMConfigStore.StoreError.busy = error else { return XCTFail("Expected busy, got \(error)") }
            }
        }
        XCTAssertEqual(keys.accesses, 0)
        XCTAssertEqual(close(fd), 0)
        XCTAssertEqual(try store.loadConfig()?.modelName, "working")
        XCTAssertEqual(try store.loadAPIKey(), "working-key")
    }

    func testCredentialMutationKeepsLeaseUntilMetadataPublicationOrClear() throws {
        let keys = RouteMutationKeys()
        let writer = LLMConfigStore(preferencesDomain: suiteName, lockURL: routeLockURL, keychain: keys)
        try writer.saveConfig(.openai(apiKey: "old", model: "old"))
        var competingAttempts = 0
        keys.onMutation = { [self] in
            competingAttempts += 1
            XCTAssertThrowsError(try store.updateModelName("competing")) { error in
                guard case LLMConfigStore.StoreError.busy = error else { return XCTFail("Expected busy, got \(error)") }
            }
        }
        try writer.saveConfig(.openai(apiKey: "new", model: "new"))
        XCTAssertEqual(try writer.loadConfig()?.modelName, "new")
        XCTAssertEqual(try writer.loadAPIKey(), "new")
        try writer.deleteConfig()
        XCTAssertEqual(competingAttempts, 2)
        XCTAssertNil(try writer.loadConfigMetadata())
        XCTAssertNil(try keys.getString("llm_api_key_openai"))
    }

    func testRefreshFailureRejectsBeforeAnyCredentialOrMetadataMutation() throws {
        try store.saveConfig(.openai(apiKey: "old", model: "old"))
        let keys = RouteFailingKeys()
        let fault = LLMRouteSynchronizationFault(failingCalls: [1])
        let failing = LLMConfigStore(
            preferencesDomain: suiteName, lockURL: routeLockURL, keychain: keys,
            synchronizePreferences: { fault.synchronize($0) })
        XCTAssertThrowsError(try failing.saveConfig(.openai(apiKey: "new", model: "new"))) { error in
            guard case LLMConfigStore.StoreError.refreshFailed = error else {
                return XCTFail("Expected refresh failure")
            }
        }
        XCTAssertEqual(keys.accesses, 0)
        XCTAssertEqual(try store.loadConfig()?.modelName, "old")
        XCTAssertEqual(try store.loadAPIKey(), "old")
    }

    func testPublicationFailureIsUnconfirmedAndNotAutomaticallyRetried() throws {
        try store.saveConfig(.ollama(model: "old"))
        let expected = try XCTUnwrap(store.loadRouteMetadata(for: .analysis))
        let fault = LLMRouteSynchronizationFault(failingCalls: [2])
        let failing = LLMConfigStore(
            preferencesDomain: suiteName, lockURL: routeLockURL, keychain: RouteFailingKeys(),
            synchronizePreferences: { fault.synchronize($0) })
        XCTAssertThrowsError(try failing.updateModelName("new", for: .analysis, expected: expected)) { error in
            guard case LLMConfigStore.StoreError.publicationUnconfirmed = error else {
                return XCTFail("Expected unconfirmed publication")
            }
            XCTAssertTrue(error.localizedDescription.contains("may have changed"))
        }
        XCTAssertEqual(fault.callCount, 2)
        // Deliberately no no-change assertion: CFPreferences can publish cached
        // data later and this failure cannot promise rollback across stores.
    }

    func testStaleConditionalWriteDoesNotAttemptPublication() throws {
        try store.saveConfig(.ollama(model: "current"))
        let fault = LLMRouteSynchronizationFault(failingCalls: [2])
        let reader = LLMConfigStore(
            preferencesDomain: suiteName, lockURL: routeLockURL, keychain: RouteFailingKeys(),
            synchronizePreferences: { fault.synchronize($0) })
        let stale = LLMModelSelectionRoute(config: .ollama(model: "old"), isOverride: false)
        XCTAssertFalse(try reader.updateModelName("new", for: .analysis, expected: stale))
        XCTAssertEqual(fault.callCount, 1)
    }

    func testConditionalModelUpdateRejectsEveryChangedRouteIdentity() throws {
        let original = LLMProviderConfig.openai(apiKey: "secret", model: "original")
        let alternatives: [LLMProviderConfig?] = [
            nil, .ollama(model: "other"), .openai(apiKey: "secret", model: "different"),
            .openai(apiKey: "secret", model: "original", baseURL: URL(string: "https://other.example/v1")!),
        ]
        for replacement in alternatives {
            try store.saveConfiguration(
                original, cleanupOverride: .ollama(model: "cleanup"), analysisOverride: original)
            let expected = try XCTUnwrap(store.loadRouteMetadata(for: .analysis))
            try store.saveTaskOverride(replacement, for: .analysis)
            XCTAssertFalse(try store.updateModelName("stale", for: .analysis, expected: expected))
            XCTAssertEqual(try store.loadConfig(), original)
            XCTAssertEqual(try store.loadTaskOverride(.analysis)?.modelName, replacement?.modelName)
            XCTAssertEqual(try store.loadTaskOverride(.cleanup)?.modelName, "cleanup")
        }
        try store.saveTaskOverride(nil, for: .analysis)
        let inherited = try XCTUnwrap(store.loadRouteMetadata(for: .analysis))
        try store.saveTaskOverride(original, for: .analysis)
        XCTAssertFalse(try store.updateModelName("stale", for: .analysis, expected: inherited))
    }

    func testModelWritesNeverAccessKeychainAndCredentialRotationDoesNotInvalidateMetadata() throws {
        try store.saveConfiguration(
            .openai(apiKey: "secret", model: "default"), cleanupOverride: nil,
            analysisOverride: .openai(apiKey: "secret", model: "analysis"))
        let expected = try XCTUnwrap(store.loadRouteMetadata(for: .analysis))
        XCTAssertNil(expected.config.apiKey)
        try store.saveAPIKey("rotated")
        let noKeys = RouteFailingKeys()
        let metadataStore = LLMConfigStore(preferencesDomain: suiteName, lockURL: routeLockURL, keychain: noKeys)
        XCTAssertTrue(try metadataStore.updateModelName("updated", for: .analysis, expected: expected))
        try metadataStore.updateModelName("new-default")
        XCTAssertEqual(noKeys.accesses, 0)
        XCTAssertEqual(try store.loadConfig()?.apiKey, "rotated")
        XCTAssertEqual(try store.loadTaskOverride(.analysis)?.apiKey, "rotated")
    }

    func testCorruptMetadataStillThrowsOnReadButCanBeCleared() throws {
        try keychain.setString("preserve", forKey: "llm_api_key_openai")
        CFPreferencesSetAppValue(
            "llm_provider_config" as CFString, Data("broken".utf8) as CFData, suiteName as CFString)
        CFPreferencesSetAppValue(
            "llm_provider_config_analysis" as CFString, Data("broken".utf8) as CFData, suiteName as CFString)
        XCTAssertTrue(CFPreferencesAppSynchronize(suiteName as CFString))
        XCTAssertThrowsError(try store.loadConfigMetadata())
        XCTAssertThrowsError(try store.loadRouteMetadata(for: .analysis))
        try store.deleteConfig()
        XCTAssertNil(try store.loadConfigMetadata())
        XCTAssertNil(try store.loadTaskOverrideMetadata(.analysis))
        XCTAssertEqual(try keychain.getString("llm_api_key_openai"), "preserve")
    }

    func testMetadataLockRejectsSymlinkAndReleasesAfterDecodingError() throws {
        try FileManager.default.createDirectory(
            at: routeLockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = routeLockURL.deletingLastPathComponent().appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: routeLockURL, withDestinationURL: target)
        XCTAssertThrowsError(try store.loadConfigMetadata())
        XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
        try FileManager.default.removeItem(at: routeLockURL)
        CFPreferencesSetAppValue("llm_provider_config" as CFString, Data("bad".utf8) as CFData, suiteName as CFString)
        XCTAssertTrue(CFPreferencesAppSynchronize(suiteName as CFString))
        XCTAssertThrowsError(try store.loadConfigMetadata())
        try store.saveConfig(.ollama(model: "recovered"))
        XCTAssertEqual(try store.loadConfigMetadata()?.modelName, "recovered")
    }

    func testExecutionHydratesOnlySelectedProviderOutsideMetadataLock() throws {
        try store.saveConfiguration(
            .openai(apiKey: "default-key", model: "old-default"), cleanupOverride: nil,
            analysisOverride: .ollama(model: "old-analysis"))
        let keys = RouteHookKeys()
        keys.onRead = { [self] key in
            XCTAssertEqual(key, "llm_api_key_ollama")
            // A writer can run during credential loading: metadata selection was
            // already captured, and no lock is held across credential access.
            try store.saveConfiguration(.ollama(model: "new-default"), cleanupOverride: nil, analysisOverride: nil)
            return "selected-key"
        }
        let reader: any LLMConfigStoreProtocol = LLMConfigStore(
            preferencesDomain: suiteName, lockURL: routeLockURL, keychain: keys)
        let resolver = StoredLLMExecutionContextResolver(
            configStore: reader, cliConfigStore: LocalCLIConfigStore(defaults: defaults))
        let context = try XCTUnwrap(resolver.resolveContext(for: .analysis))
        XCTAssertEqual(context.providerConfig.modelName, "old-analysis")
        XCTAssertEqual(context.providerConfig.apiKey, "selected-key")
        XCTAssertEqual(try store.loadRouteMetadata(for: .analysis)?.config.modelName, "new-default")
    }

    func testTwoProcessesRefreshSnapshotsAndSerializeWriters() async throws {
        try store.saveConfiguration(.ollama(model: "A"), cleanupOverride: nil, analysisOverride: nil)
        let stale = try XCTUnwrap(store.loadRouteMetadata(for: .analysis))
        let process = try launchRouteChild(mode: "swap")
        defer { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit() }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline {
            do {
                let model = try store.loadRouteMetadata(for: .analysis)?.config.modelName
                XCTAssertTrue(model == "A" || model == "C", "Mixed default/override snapshot: \(model ?? "nil")")
            } catch LLMConfigStore.StoreError.busy {}
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(process.isRunning, "Route child timed out")
        guard !process.isRunning else { return }
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try store.loadRouteMetadata(for: .analysis)?.config.modelName, "C")
        XCTAssertFalse(try store.updateModelName("stale", for: .analysis, expected: stale))

        var fd = open(routeLockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        defer { if fd >= 0 { close(fd) } }
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let blocked = try launchRouteChild(mode: "blocked")
        defer { if blocked.isRunning { Darwin.kill(blocked.processIdentifier, SIGKILL) }; blocked.waitUntilExit() }
        let blockedDeadline = Date().addingTimeInterval(30)
        while blocked.isRunning && Date() < blockedDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(blocked.isRunning, "Lock child timed out")
        XCTAssertEqual(close(fd), 0)
        fd = -1
        guard !blocked.isRunning else { return }
        XCTAssertEqual(blocked.terminationStatus, 0)
        try store.updateModelName("after-close")
        XCTAssertEqual(try store.loadConfigMetadata()?.modelName, "after-close")
    }

    func testChildResetOfIdenticalOverrideRejectsPreviouslyCapturedPicker() async throws {
        let config = LLMProviderConfig.ollama(model: "same-model")
        try store.saveConfiguration(config, cleanupOverride: nil, analysisOverride: config)
        let expected = try XCTUnwrap(store.loadRouteMetadata(for: .analysis))
        let child = try launchRouteChild(mode: "reset")
        defer { if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }; child.waitUntilExit() }
        let deadline = Date().addingTimeInterval(30)
        while child.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(child.isRunning, "Reset child timed out")
        guard !child.isRunning else { return }
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertFalse(try store.updateModelName("stale-selection", for: .analysis, expected: expected))
        XCTAssertEqual(try store.loadConfigMetadata(), LLMModelSelectionRoute(config: config, isOverride: false).config)
        XCTAssertNil(try store.loadTaskOverrideMetadata(.analysis))
    }

    private func launchRouteChild(mode: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest", "MacParakeetTests.LLMConfigStoreTests/testRouteStoreChild",
            Bundle(for: Self.self).bundleURL.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "MACPARAKEET_ROUTE_TEST_DOMAIN": suiteName!, "MACPARAKEET_ROUTE_TEST_LOCK": routeLockURL.path,
            "MACPARAKEET_ROUTE_TEST_MODE": mode,
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    func testRouteStoreChild() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let domain = environment["MACPARAKEET_ROUTE_TEST_DOMAIN"],
            let path = environment["MACPARAKEET_ROUTE_TEST_LOCK"],
            let mode = environment["MACPARAKEET_ROUTE_TEST_MODE"]
        else { throw XCTSkip("Subprocess entry point") }
        let child = LLMConfigStore(
            preferencesDomain: domain, lockURL: URL(fileURLWithPath: path), keychain: InMemoryKeyValueStore())
        if mode == "reset" {
            try child.saveTaskOverride(nil, for: .analysis)
        } else if mode == "blocked" {
            let config = LLMProviderConfig.ollama(model: "blocked")
            let expected = LLMModelSelectionRoute(config: config, isOverride: false)
            let operations: [() throws -> Void] = [
                { _ = try child.loadRouteMetadata(for: .analysis) },
                { try child.saveConfig(config) },
                { try child.saveTaskOverride(nil, for: .analysis) },
                { try child.saveConfiguration(config, cleanupOverride: nil, analysisOverride: nil) },
                { try child.deleteConfig() },
                { try child.updateModelName("blocked") },
                { _ = try child.updateModelName("blocked", for: .analysis, expected: expected) },
            ]
            for operation in operations {
                XCTAssertThrowsError(try operation()) { error in
                    guard case LLMConfigStore.StoreError.busy = error else {
                        return XCTFail("Expected busy, got \(error)")
                    }
                }
            }
        } else {
            // Hold each published state briefly so the parent reads both while
            // this process alternates complete three-key configurations.
            func publish(defaultModel: String, analysis: LLMProviderConfig?) throws {
                let deadline = Date().addingTimeInterval(5)
                while true {
                    do {
                        try child.saveConfiguration(
                            .ollama(model: defaultModel), cleanupOverride: nil, analysisOverride: analysis)
                        return
                    } catch LLMConfigStore.StoreError.busy {
                        guard Date() < deadline else { throw LLMConfigStore.StoreError.busy }
                        usleep(500)
                    }
                }
            }
            for _ in 0..<30 {
                try publish(defaultModel: "A", analysis: nil)
                usleep(2_000)
                try publish(defaultModel: "B", analysis: .ollama(model: "C"))
                usleep(2_000)
            }
        }
    }

    // MARK: - Tests

    func testTaskModelUpdatePreservesDefaultCleanupAndCredentials() throws {
        let defaultConfig = LLMProviderConfig.openai(apiKey: "default-key", model: "default-model")
        let cleanup = LLMProviderConfig.ollama(model: "cleanup-model")
        try store.saveConfig(defaultConfig)
        try store.saveTaskOverride(cleanup, for: .cleanup)
        try store.saveTaskOverride(.anthropic(apiKey: "analysis-key", model: "claude-old"), for: .analysis)

        try store.updateModelName("claude-new", for: .analysis)

        XCTAssertEqual(try store.loadConfig(), defaultConfig)
        XCTAssertEqual(try store.loadTaskOverride(.cleanup), cleanup)
        XCTAssertEqual(try store.loadConfig(for: .analysis)?.modelName, "claude-new")
        XCTAssertEqual(try store.loadConfig(for: .analysis)?.apiKey, "analysis-key")
        XCTAssertEqual(try store.loadConfig(for: .analysis)?.id, .anthropic)
    }

    func testInheritedTaskModelUpdateDoesNotCreateOverride() throws {
        try store.saveConfig(.openai(apiKey: "default-key", model: "old"))
        try store.updateModelName("new", for: .analysis)
        XCTAssertNil(try store.loadTaskOverride(.analysis))
        XCTAssertEqual(try store.loadConfig()?.modelName, "new")
        XCTAssertEqual(try store.loadConfig(for: .analysis), try store.loadConfig())
    }

    func testSaveAndLoadRoundTrip() throws {
        let config = LLMProviderConfig.openai(apiKey: "sk-test-key", model: "gpt-4o")
        try store.saveConfig(config)

        let loaded = try store.loadConfig()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, .openai)
        XCTAssertEqual(loaded?.modelName, "gpt-4o")
        XCTAssertEqual(loaded?.apiKey, "sk-test-key")
        XCTAssertEqual(loaded?.isLocal, false)
    }

    func testAPIKeyStoredInKeychainNotUserDefaults() throws {
        let config = LLMProviderConfig.anthropic(apiKey: "sk-ant-secret")
        try store.saveConfig(config)

        // Verify apiKey is in per-provider Keychain key
        let keychainValue = try keychain.getString("llm_api_key_anthropic")
        XCTAssertEqual(keychainValue, "sk-ant-secret")

        // Verify apiKey is NOT in UserDefaults (CodingKeys excludes it)
        let data = defaults.data(forKey: "llm_provider_config")!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["apiKey"])
    }

    func testLoadReturnsNilWhenEmpty() throws {
        let loaded = try store.loadConfig()
        XCTAssertNil(loaded)
    }

    func testDeleteClearsBothStores() throws {
        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        try store.saveConfig(config)

        try store.deleteConfig()

        XCTAssertNil(try store.loadConfig())
        XCTAssertNil(try keychain.getString("llm_api_key_openai"))
        XCTAssertNil(defaults.data(forKey: "llm_provider_config"))
    }

    func testOllamaConfigWithNoAPIKey() throws {
        let config = LLMProviderConfig.ollama(model: "llama3.2")
        try store.saveConfig(config)

        let loaded = try store.loadConfig()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, .ollama)
        XCTAssertNil(loaded?.apiKey)
        XCTAssertEqual(loaded?.isLocal, true)
    }

    func testLMStudioOptionalAPIKeyStoredInKeychain() throws {
        let config = LLMProviderConfig.lmstudio(apiKey: "lm-token", model: "local-model")
        try store.saveConfig(config)

        XCTAssertEqual(try keychain.getString("llm_api_key_lmstudio"), "lm-token")
        let data = defaults.data(forKey: "llm_provider_config")!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["apiKey"])

        let loaded = try store.loadConfig()
        XCTAssertEqual(loaded?.id, .lmstudio)
        XCTAssertEqual(loaded?.apiKey, "lm-token")
    }

    func testInProcessLocalSentinelURLRoundTripsWithoutAPIKey() throws {
        let config = LLMProviderConfig.inProcessLocal(model: "local-model")
        try store.saveConfig(config)

        let loaded = try store.loadConfig()
        XCTAssertEqual(loaded?.id, .inProcessLocal)
        XCTAssertEqual(loaded?.baseURL.absoluteString, "inprocess://local")
        XCTAssertEqual(loaded?.modelName, "local-model")
        XCTAssertEqual(loaded?.isLocal, true)
        XCTAssertNil(loaded?.apiKey)
        XCTAssertNil(try keychain.getString("llm_api_key_inProcessLocal"))
    }

    func testAppleIntelligenceSentinelURLRoundTripsWithoutAPIKey() throws {
        let config = LLMProviderConfig.appleIntelligence()
        try store.saveConfig(config)

        let loaded = try store.loadConfig()
        XCTAssertEqual(loaded?.id, .appleIntelligence)
        XCTAssertEqual(loaded?.baseURL.absoluteString, "appleintelligence://system")
        XCTAssertEqual(loaded?.modelName, "apple-intelligence")
        XCTAssertEqual(loaded?.isLocal, true)
        XCTAssertNil(loaded?.apiKey)
        XCTAssertNil(try keychain.getString("llm_api_key_appleIntelligence"))
    }

    func testOverwriteAPIKey() throws {
        let config1 = LLMProviderConfig.openai(apiKey: "old-key")
        try store.saveConfig(config1)

        let config2 = LLMProviderConfig.openai(apiKey: "new-key")
        try store.saveConfig(config2)

        let loaded = try store.loadConfig()
        XCTAssertEqual(loaded?.apiKey, "new-key")
    }

    func testLoadAPIKeyAndSaveAPIKey() throws {
        // loadAPIKey() requires a saved config to know which provider to look up
        XCTAssertNil(try store.loadAPIKey())

        let config = LLMProviderConfig.openai(apiKey: "sk-initial")
        try store.saveConfig(config)

        try store.saveAPIKey("sk-direct")
        XCTAssertEqual(try store.loadAPIKey(), "sk-direct")
        XCTAssertEqual(try store.loadAPIKey(for: .openai), "sk-direct")

        try store.deleteAPIKey()
        XCTAssertNil(try store.loadAPIKey())
    }

    func testMissingKeychainKeyReturnsConfigWithNilAPIKey() throws {
        // Save config with apiKey, then delete only the Keychain entry
        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        try store.saveConfig(config)
        try keychain.delete("llm_api_key_openai")

        let loaded = try store.loadConfig()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, .openai)
        XCTAssertNil(loaded?.apiKey)
    }

    // MARK: - Per-Provider Key Storage

    func testPerProviderKeysPreservedAcrossSwitch() throws {
        // Save OpenAI config
        let openaiConfig = LLMProviderConfig.openai(apiKey: "sk-openai-key")
        try store.saveConfig(openaiConfig)

        // Save Anthropic config (switches active provider)
        let anthropicConfig = LLMProviderConfig.anthropic(apiKey: "sk-ant-key")
        try store.saveConfig(anthropicConfig)

        // Both keys should be in Keychain
        XCTAssertEqual(try keychain.getString("llm_api_key_openai"), "sk-openai-key")
        XCTAssertEqual(try keychain.getString("llm_api_key_anthropic"), "sk-ant-key")

        // loadAPIKey(for:) returns the right key per provider
        XCTAssertEqual(try store.loadAPIKey(for: .openai), "sk-openai-key")
        XCTAssertEqual(try store.loadAPIKey(for: .anthropic), "sk-ant-key")
    }

    func testDeleteOnlyClearsActiveProviderKey() throws {
        // Save keys for multiple providers
        try store.saveConfig(.openai(apiKey: "sk-openai"))
        try store.saveConfig(.anthropic(apiKey: "sk-ant"))

        // Delete clears only the active provider (anthropic) key
        try store.deleteConfig()

        XCTAssertEqual(try keychain.getString("llm_api_key_openai"), "sk-openai")
        XCTAssertNil(try keychain.getString("llm_api_key_anthropic"))
    }

    func testFailedCredentialWritePreservesWorkingProviderAcrossReopen() throws {
        try store.saveConfig(.openai(apiKey: "working-key", model: "working-model"))
        keychain.setError = KeyValueStoreError.unsupported

        XCTAssertThrowsError(try store.saveConfig(.anthropic(apiKey: "replacement-key")))

        let reopened = LLMConfigStore(preferencesDomain: suiteName, lockURL: routeLockURL, keychain: keychain)
        XCTAssertEqual(try reopened.loadConfig()?.id, .openai)
        XCTAssertEqual(try reopened.loadConfig()?.modelName, "working-model")
        XCTAssertEqual(try reopened.loadAPIKey(), "working-key")
        XCTAssertNil(try reopened.loadAPIKey(for: .anthropic))
    }

    func testFailedCredentialReplacementPreservesSameProviderConfiguration() throws {
        try store.saveConfig(.openai(apiKey: "working-key", model: "working-model"))
        keychain.setError = KeyValueStoreError.unsupported
        let replacement = LLMProviderConfig(
            id: .openai,
            baseURL: URL(string: "https://replacement.example/v1")!,
            apiKey: "replacement-key",
            modelName: "replacement-model",
            isLocal: false
        )

        XCTAssertThrowsError(try store.saveConfig(replacement))

        let loaded = try XCTUnwrap(store.loadConfig())
        XCTAssertEqual(loaded.baseURL, LLMProviderConfig.openai(apiKey: "working-key").baseURL)
        XCTAssertEqual(loaded.modelName, "working-model")
        XCTAssertEqual(loaded.apiKey, "working-key")
    }

    func testFailedOptionalCredentialRemovalPreservesWorkingConfiguration() throws {
        try store.saveConfig(.lmstudio(apiKey: "working-token", model: "working-model"))
        keychain.deleteError = KeyValueStoreError.unsupported

        XCTAssertThrowsError(try store.saveConfig(.lmstudio(model: "replacement-model")))

        XCTAssertEqual(try store.loadConfig()?.modelName, "working-model")
        XCTAssertEqual(try store.loadAPIKey(), "working-token")
    }

    func testFailedClearPreservesWorkingConfiguration() throws {
        try store.saveConfig(.openai(apiKey: "working-key", model: "working-model"))
        keychain.deleteError = KeyValueStoreError.unsupported

        XCTAssertThrowsError(try store.deleteConfig())

        XCTAssertEqual(try store.loadConfig()?.id, .openai)
        XCTAssertEqual(try store.loadConfig()?.modelName, "working-model")
        XCTAssertEqual(try store.loadAPIKey(), "working-key")
    }

    func testTaskOverrideRoundTripDoesNotReplaceDefault() throws {
        try store.saveConfig(.anthropic(apiKey: "sk-ant", model: "claude-sonnet-5"))
        try store.saveTaskOverride(.ollama(model: "llama3.2"), for: .cleanup)

        XCTAssertEqual(try store.loadConfig()?.id, .anthropic)
        XCTAssertEqual(try store.loadTaskOverride(.cleanup)?.id, .ollama)
        XCTAssertEqual(try store.loadTaskOverride(.cleanup)?.modelName, "llama3.2")
        XCTAssertNil(try store.loadTaskOverride(.analysis))
        XCTAssertNil(try store.loadTaskOverride(.transform))
    }

    func testFailedConfigurationSaveDoesNotPublishAnyTaskRoute() throws {
        try store.saveConfiguration(
            .openai(apiKey: "working-key", model: "working-model"),
            cleanupOverride: .ollama(model: "old-cleanup"),
            analysisOverride: nil
        )
        keychain.setError = KeyValueStoreError.unsupported

        XCTAssertThrowsError(
            try store.saveConfiguration(
                .anthropic(apiKey: "new-key", model: "new-model"),
                cleanupOverride: nil,
                analysisOverride: .ollama(model: "new-analysis")
            ))

        let reopened = LLMConfigStore(preferencesDomain: suiteName, lockURL: routeLockURL, keychain: keychain)
        XCTAssertEqual(try reopened.loadConfig()?.id, .openai)
        XCTAssertEqual(try reopened.loadConfig()?.modelName, "working-model")
        XCTAssertEqual(try reopened.loadTaskOverride(.cleanup)?.modelName, "old-cleanup")
        XCTAssertNil(try reopened.loadTaskOverride(.analysis))
        XCTAssertEqual(try reopened.loadAPIKey(), "working-key")
    }

    func testConfigurationSavePublishesBothTaskRoutes() throws {
        try store.saveConfiguration(
            .openai(apiKey: "default-key", model: "default-model"),
            cleanupOverride: .ollama(model: "cleanup-model"),
            analysisOverride: .openai(apiKey: "default-key", model: "analysis-model")
        )

        XCTAssertEqual(try store.loadConfig()?.modelName, "default-model")
        XCTAssertEqual(try store.loadTaskOverride(.cleanup)?.modelName, "cleanup-model")
        XCTAssertEqual(try store.loadTaskOverride(.analysis)?.modelName, "analysis-model")
        XCTAssertEqual(try store.loadTaskOverride(.analysis)?.apiKey, "default-key")
    }

    func testConfigurationSaveRejectsChangedTaskCredentialBeforePublishing() throws {
        try store.saveConfiguration(
            .openai(apiKey: "working-key", model: "working-model"),
            cleanupOverride: nil,
            analysisOverride: nil
        )

        XCTAssertThrowsError(
            try store.saveConfiguration(
                .anthropic(apiKey: "new-key", model: "new-model"),
                cleanupOverride: .openai(apiKey: "stale-key", model: "cleanup-model"),
                analysisOverride: nil
            ))

        XCTAssertEqual(try store.loadConfig()?.modelName, "working-model")
        XCTAssertNil(try store.loadTaskOverride(.cleanup))
        XCTAssertEqual(try store.loadAPIKey(), "working-key")
        XCTAssertNil(try store.loadAPIKey(for: .anthropic))
    }

    func testDeleteConfigClearsTaskOverrides() throws {
        try store.saveConfig(.openai(apiKey: "sk-test", model: "gpt-5.4"))
        try store.saveTaskOverride(.ollama(model: "llama3.2"), for: .cleanup)
        try store.deleteConfig()

        XCTAssertNil(try store.loadConfig())
        XCTAssertNil(try store.loadTaskOverride(.cleanup))
    }
}

private final class RouteFailingKeys: KeyValueStore, @unchecked Sendable {
    var accesses = 0
    func getString(_ key: String) throws -> String? { accesses += 1; throw NSError(domain: "keychain", code: 1) }
    func setString(_ value: String, forKey key: String) throws {
        accesses += 1; throw NSError(domain: "keychain", code: 1)
    }
    func delete(_ key: String) throws { accesses += 1; throw NSError(domain: "keychain", code: 1) }
}

private final class RouteHookKeys: KeyValueStore, @unchecked Sendable {
    var onRead: ((String) throws -> String?)?
    func getString(_ key: String) throws -> String? { try onRead?(key) }
    func setString(_ value: String, forKey key: String) throws {}
    func delete(_ key: String) throws {}
}

final class LLMRouteSynchronizationFault: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failingCalls: Set<Int>
    init(failingCalls: Set<Int>) { self.failingCalls = failingCalls }
    var callCount: Int { lock.withLock { count } }
    func synchronize(_ domain: String) -> Bool {
        let fail = lock.withLock {
            count += 1; return failingCalls.contains(count)
        }
        return fail ? false : CFPreferencesAppSynchronize(domain as CFString)
    }
}

private final class RouteMutationKeys: KeyValueStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    var onMutation: (() throws -> Void)?
    func getString(_ key: String) throws -> String? { values[key] }
    func setString(_ value: String, forKey key: String) throws { try onMutation?(); values[key] = value }
    func delete(_ key: String) throws { try onMutation?(); values.removeValue(forKey: key) }
}