import ArgumentParser
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class ConfigCommandTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // Isolate each test in a unique UserDefaults suite so we never touch
        // the user's real `com.macparakeet.MacParakeet` plist.
        suiteName = "macparakeet.test.config.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - read

    func testReadTelemetryDefaultsToOn() throws {
        // Mirror AppPreferences.isTelemetryEnabled: missing key → on.
        let value = try ConfigCommand.read(key: "telemetry", defaults: defaults)
        XCTAssertEqual(value, "on")
    }

    func testReadTelemetryReflectsExplicitFalse() throws {
        defaults.set(false, forKey: AppPreferences.telemetryEnabledKey)
        XCTAssertEqual(try ConfigCommand.read(key: "telemetry", defaults: defaults), "off")
    }

    func testReadTelemetryReflectsExplicitTrue() throws {
        defaults.set(true, forKey: AppPreferences.telemetryEnabledKey)
        XCTAssertEqual(try ConfigCommand.read(key: "telemetry", defaults: defaults), "on")
    }

    func testReadUnknownKeyThrowsValidationError() {
        // Maps to errorType="validation" / exit code 2 in --json failure envelope.
        XCTAssertThrowsError(try ConfigCommand.read(key: "bogus", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError, "Expected ValidationError, got \(type(of: error))")
            XCTAssertTrue("\(error)".contains("bogus"))
        }
    }

    // MARK: - write

    func testWriteTelemetryOffPersists() throws {
        let canonical = try ConfigCommand.write(key: "telemetry", value: "off", defaults: defaults)
        XCTAssertEqual(canonical, "off")
        XCTAssertEqual(defaults.object(forKey: AppPreferences.telemetryEnabledKey) as? Bool, false)
    }

    func testWriteTelemetryOnPersists() throws {
        defaults.set(false, forKey: AppPreferences.telemetryEnabledKey)
        let canonical = try ConfigCommand.write(key: "telemetry", value: "on", defaults: defaults)
        XCTAssertEqual(canonical, "on")
        XCTAssertEqual(defaults.object(forKey: AppPreferences.telemetryEnabledKey) as? Bool, true)
    }

    func testWriteAcceptsAllBoolSynonyms() throws {
        for (synonym, expectedBool) in [
            ("on", true), ("ON", true), ("true", true), ("yes", true),
            ("1", true), ("enable", true), ("enabled", true),
            ("off", false), ("OFF", false), ("false", false), ("no", false),
            ("0", false), ("disable", false), ("disabled", false)
        ] {
            let canonical = try ConfigCommand.write(key: "telemetry", value: synonym, defaults: defaults)
            XCTAssertEqual(canonical, expectedBool ? "on" : "off",
                           "Synonym '\(synonym)' should canonicalize to \(expectedBool ? "on" : "off")")
            XCTAssertEqual(defaults.object(forKey: AppPreferences.telemetryEnabledKey) as? Bool, expectedBool)
        }
    }

    func testWriteRejectsInvalidValueAsValidationError() {
        XCTAssertThrowsError(try ConfigCommand.write(key: "telemetry", value: "maybe", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError, "Expected ValidationError, got \(type(of: error))")
            XCTAssertTrue("\(error)".contains("maybe"))
        }
        // Defaults must not have been mutated.
        XCTAssertNil(defaults.object(forKey: AppPreferences.telemetryEnabledKey))
    }

    func testWriteUnknownKeyThrowsValidationError() {
        XCTAssertThrowsError(try ConfigCommand.write(key: "bogus", value: "on", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError, "Expected ValidationError, got \(type(of: error))")
        }
    }

    // MARK: - parseBool

    func testParseBoolRejectsEmpty() {
        XCTAssertThrowsError(try ConfigCommand.parseBool("", key: "telemetry")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testParseBoolRejectsWhitespaceOnly() {
        XCTAssertThrowsError(try ConfigCommand.parseBool("   ", key: "telemetry")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testParseBoolTrimsNewlines() throws {
        XCTAssertTrue(try ConfigCommand.parseBool("\n on \n", key: "telemetry"))
        XCTAssertFalse(try ConfigCommand.parseBool("\n off \n", key: "telemetry"))
    }
}
