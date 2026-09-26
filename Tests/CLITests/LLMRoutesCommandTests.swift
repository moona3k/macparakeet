import ArgumentParser
import Foundation
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class LLMRoutesCommandTests: XCTestCase {
    private func fixture() -> (LLMConfigStore, LocalCLIConfigStore) {
        let name = "LLMRoutesCommandTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (
            LLMConfigStore(defaults: defaults, keychain: RouteMemoryKeys()), LocalCLIConfigStore(defaults: defaults)
        )
    }

    func testCommandsAreRegistered() throws {
        XCTAssertTrue(try LLMCommand.parseAsRoot(["routes", "list", "--json"]) is LLMRoutesListCommand)
        XCTAssertTrue(
            try LLMCommand.parseAsRoot(["routes", "set", "analysis", "--provider", "ollama"]) is LLMRoutesSetCommand)
        XCTAssertTrue(try LLMCommand.parseAsRoot(["routes", "reset", "cleanup"]) is LLMRoutesResetCommand)
    }

    func testSetAndResetPreserveDefaultOtherRouteAndCredentials() throws {
        let (store, cliStore) = fixture()
        let original = LLMProviderConfig.openai(apiKey: "secret-default", model: "default-model")
        try store.saveConfig(original)
        try store.saveTaskOverride(.ollama(model: "cleanup-model"), for: .cleanup)
        let options = try LLMInlineOptions.parse(["--provider", "openai", "--model", "analysis-model"])
        try setLLMRoute("analysis", options: options, store: store, cliStore: cliStore, environment: [:])
        XCTAssertEqual(try store.loadTaskOverride(.analysis)?.apiKey, "secret-default")
        XCTAssertEqual(try store.loadTaskOverride(.analysis)?.modelName, "analysis-model")
        XCTAssertEqual(try store.loadConfig(), original)
        XCTAssertEqual(try store.loadTaskOverride(.cleanup)?.modelName, "cleanup-model")
        try resetLLMRoute("analysis", store: store)
        XCTAssertNil(try store.loadTaskOverride(.analysis))
        XCTAssertEqual(try store.loadAPIKey(for: .openai), "secret-default")
        let routes = try listLLMRoutes(store: store)
        XCTAssertTrue(try XCTUnwrap(routes.first { $0.task == "analysis" }).inherited)
        XCTAssertEqual(routes.first { $0.task == "analysis" }?.model, "default-model")
    }

    func testInvalidTaskDoesNotPersistAnything() throws {
        let (store, cliStore) = fixture()
        let options = try LLMInlineOptions.parse(["--provider", "openai", "--api-key", "secret"])
        for task in ["transform", "default", "unknown"] {
            XCTAssertThrowsError(
                try setLLMRoute(task, options: options, store: store, cliStore: cliStore, environment: [:]))
            XCTAssertThrowsError(try resetLLMRoute(task, store: store))
        }
        XCTAssertNil(try store.loadAPIKey(for: .openai))
        XCTAssertNil(try store.loadConfig())
    }

    func testListNeverSerializesCredentialsOrEndpointSecrets() throws {
        let (store, _) = fixture()
        try store.saveConfig(
            .openai(
                apiKey: "private-key", model: "m",
                baseURL: URL(string: "https://user:password@example.com/private-path?token=secret#private-fragment")!))
        let json = String(decoding: try JSONEncoder().encode(listLLMRoutes(store: store)), as: UTF8.self)
        for secret in ["private-key", "user", "password", "private-path", "token", "secret", "private-fragment"] {
            XCTAssertFalse(json.contains(secret), secret)
        }
        XCTAssertTrue(json.contains("example.com"))
    }

    func testOptionalCredentialIsPreserved() throws {
        let (store, cliStore) = fixture()
        try store.saveTaskOverride(.lmstudio(apiKey: "saved-token", model: "old"), for: .cleanup)
        let options = try LLMInlineOptions.parse(["--provider", "lmstudio", "--model", "new"])
        try setLLMRoute("analysis", options: options, store: store, cliStore: cliStore, environment: [:])
        XCTAssertEqual(try store.loadTaskOverride(.analysis)?.apiKey, "saved-token")
        XCTAssertEqual(try store.loadTaskOverride(.cleanup)?.apiKey, "saved-token")
    }

    func testExplicitEnvironmentCredentialOverridesSavedKey() throws {
        let (store, cliStore) = fixture()
        try store.saveConfig(.openai(apiKey: "old", model: "default"))
        let options = try LLMInlineOptions.parse(["--provider", "openai", "--api-key-env", "ROUTE_KEY"])
        try setLLMRoute(
            "analysis", options: options, store: store, cliStore: cliStore, environment: ["ROUTE_KEY": "replacement"])
        XCTAssertEqual(try store.loadTaskOverride(.analysis)?.apiKey, "replacement")
        XCTAssertEqual(try store.loadConfig()?.modelName, "default")
    }

    func testMissingExplicitEnvironmentDoesNotFallBackOrMutate() throws {
        let (store, cliStore) = fixture()
        try store.saveConfig(.openai(apiKey: "old", model: "default"))
        let options = try LLMInlineOptions.parse(["--provider", "openai", "--api-key-env", "MISSING"])
        XCTAssertThrowsError(
            try setLLMRoute("analysis", options: options, store: store, cliStore: cliStore, environment: [:]))
        XCTAssertNil(try store.loadTaskOverride(.analysis))
        XCTAssertEqual(try store.loadAPIKey(for: .openai), "old")
    }

    func testInvalidConfigurationLeavesRouteAndKeyUnchanged() throws {
        let (store, cliStore) = fixture()
        try store.saveTaskOverride(.openai(apiKey: "saved", model: "working"), for: .analysis)
        for arguments in [
            ["--provider", "openai", "--api-key", "replacement", "--base-url", "ftp://example.com"],
            ["--provider", "openai", "--api-key", "replacement", "--model", "   "],
            ["--provider", "openai", "--api-key", "replacement", "--command", "ignored-command"],
        ] {
            let options = try LLMInlineOptions.parse(arguments)
            XCTAssertThrowsError(
                try setLLMRoute("analysis", options: options, store: store, cliStore: cliStore, environment: [:]))
            XCTAssertEqual(try store.loadTaskOverride(.analysis)?.modelName, "working")
            XCTAssertEqual(try store.loadAPIKey(for: .openai), "saved")
        }
    }

    func testCLIRequiresExistingTemplateAndDoesNotCreateOne() throws {
        let (store, cliStore) = fixture()
        let options = try LLMInlineOptions.parse(["--provider", "cli", "--command", "new-cli -p"])
        XCTAssertThrowsError(
            try setLLMRoute("analysis", options: options, store: store, cliStore: cliStore, environment: [:]))
        XCTAssertNil(try store.loadTaskOverride(.analysis))
        XCTAssertNil(cliStore.load())
    }

    func testCLIReusesSharedTemplateAndRejectsReplacement() throws {
        let (store, cliStore) = fixture()
        try cliStore.save(LocalCLIConfig(commandTemplate: "existing-cli -p"))
        let options = try LLMInlineOptions.parse(["--provider", "cli"])
        try setLLMRoute("analysis", options: options, store: store, cliStore: cliStore, environment: [:])
        XCTAssertEqual(try store.loadTaskOverride(.analysis)?.id, .localCLI)
        let replacement = try LLMInlineOptions.parse(["--provider", "cli", "--command", "other-cli -p"])
        XCTAssertThrowsError(
            try setLLMRoute("cleanup", options: replacement, store: store, cliStore: cliStore, environment: [:]))
        XCTAssertNil(try store.loadTaskOverride(.cleanup))
        XCTAssertEqual(cliStore.load()?.commandTemplate, "existing-cli -p")
    }
}

private final class RouteMemoryKeys: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func getString(_ key: String) throws -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) throws { lock.withLock { values[key] = value } }
    func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
