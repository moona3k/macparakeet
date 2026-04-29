import XCTest
@testable import CLI

final class CLITelemetryTests: XCTestCase {

    // MARK: - decideOverride: explicit MACPARAKEET_TELEMETRY

    func testDecideOverrideExplicitForceOffAccepts0FalseNoOff() {
        for raw in ["0", "false", "no", "off", "FALSE", "Off", " no "] {
            XCTAssertEqual(
                CLITelemetry.decideOverride(env: ["MACPARAKEET_TELEMETRY": raw]),
                .forceOff,
                "Expected forceOff for MACPARAKEET_TELEMETRY=\(raw)"
            )
        }
    }

    func testDecideOverrideExplicitForceOnAccepts1TrueYesOn() {
        for raw in ["1", "true", "yes", "on", "TRUE", "On", " yes "] {
            XCTAssertEqual(
                CLITelemetry.decideOverride(env: ["MACPARAKEET_TELEMETRY": raw]),
                .forceOn,
                "Expected forceOn for MACPARAKEET_TELEMETRY=\(raw)"
            )
        }
    }

    func testDecideOverrideEmptyMacparakeetVarFallsThrough() {
        // An empty MACPARAKEET_TELEMETRY shouldn't trigger forceOff/forceOn — fall through.
        XCTAssertEqual(
            CLITelemetry.decideOverride(env: ["MACPARAKEET_TELEMETRY": ""]),
            .none
        )
        XCTAssertEqual(
            CLITelemetry.decideOverride(env: ["MACPARAKEET_TELEMETRY": "   "]),
            .none
        )
    }

    func testDecideOverrideUnknownMacparakeetValueFallsThrough() {
        // Unknown values like "maybe" shouldn't accidentally enable or disable.
        XCTAssertEqual(
            CLITelemetry.decideOverride(env: ["MACPARAKEET_TELEMETRY": "maybe"]),
            .none
        )
    }

    // MARK: - decideOverride: DO_NOT_TRACK

    func testDecideOverrideHonorsDoNotTrack() {
        XCTAssertEqual(
            CLITelemetry.decideOverride(env: ["DO_NOT_TRACK": "1"]),
            .forceOff
        )
    }

    func testDecideOverrideDoNotTrack0DoesNotForceOff() {
        // DO_NOT_TRACK=0 means "tracking is fine," not "force off."
        XCTAssertEqual(
            CLITelemetry.decideOverride(env: ["DO_NOT_TRACK": "0"]),
            .none
        )
    }

    func testDecideOverrideMacparakeetForceOnBeatsDoNotTrack() {
        // Explicit MACPARAKEET_TELEMETRY=1 wins over DO_NOT_TRACK so a developer
        // can smoke-test telemetry from a shell that has DO_NOT_TRACK set globally.
        XCTAssertEqual(
            CLITelemetry.decideOverride(env: [
                "MACPARAKEET_TELEMETRY": "1",
                "DO_NOT_TRACK": "1"
            ]),
            .forceOn
        )
    }

    // MARK: - decideOverride: CI auto-disable

    func testDecideOverrideAutoDisablesInCI() {
        for ciVar in ["CI", "GITHUB_ACTIONS", "GITLAB_CI", "BUILDKITE", "CIRCLECI",
                      "TRAVIS", "JENKINS_URL", "TF_BUILD", "TEAMCITY_VERSION"] {
            XCTAssertEqual(
                CLITelemetry.decideOverride(env: [ciVar: "true"]),
                .ciAutoDisable,
                "Expected ciAutoDisable for \(ciVar)=true"
            )
        }
    }

    func testDecideOverrideCIFalseDoesNotTriggerAutoDisable() {
        // Some setups pass CI=false. Don't auto-disable on that.
        XCTAssertEqual(
            CLITelemetry.decideOverride(env: ["CI": "false"]),
            .none
        )
        XCTAssertEqual(
            CLITelemetry.decideOverride(env: ["CI": "0"]),
            .none
        )
        XCTAssertEqual(
            CLITelemetry.decideOverride(env: ["CI": ""]),
            .none
        )
    }

    func testDecideOverrideMacparakeetForceOnBeatsCIAutoDisable() {
        // Developer in a CI shell smoke-testing telemetry should be able to override.
        XCTAssertEqual(
            CLITelemetry.decideOverride(env: [
                "CI": "true",
                "MACPARAKEET_TELEMETRY": "1"
            ]),
            .forceOn
        )
    }

    func testDecideOverrideMacparakeetForceOffStillForceOffInCI() {
        XCTAssertEqual(
            CLITelemetry.decideOverride(env: [
                "CI": "true",
                "MACPARAKEET_TELEMETRY": "0"
            ]),
            .forceOff
        )
    }

    func testDecideOverrideNoEnvVarsReturnsNone() {
        XCTAssertEqual(CLITelemetry.decideOverride(env: [:]), .none)
    }

    // MARK: - isCIEnvironment

    func testIsCIEnvironmentTruthyValues() {
        for value in ["true", "1", "yes", "on", "TRUE", " true "] {
            XCTAssertTrue(
                CLITelemetry.isCIEnvironment(env: ["GITHUB_ACTIONS": value]),
                "Expected truthy detection for GITHUB_ACTIONS=\(value)"
            )
        }
    }

    func testIsCIEnvironmentFalsyValues() {
        for value in ["false", "0", "no", "off", "", "  "] {
            XCTAssertFalse(
                CLITelemetry.isCIEnvironment(env: ["GITHUB_ACTIONS": value]),
                "Expected falsy detection for GITHUB_ACTIONS=\(value)"
            )
        }
    }

    func testIsCIEnvironmentJenkinsURL() {
        // JENKINS_URL is conventionally a URL string (not "true"/"false"); treat any
        // non-falsy value as CI-positive.
        XCTAssertTrue(
            CLITelemetry.isCIEnvironment(env: ["JENKINS_URL": "https://ci.example.com/"])
        )
    }
}
