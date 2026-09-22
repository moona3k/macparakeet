import Foundation

/// Shared environment policy. Explicit enablement overrides development/CI defaults;
/// GUI consent is evaluated separately and remains authoritative.
public enum TelemetryPolicy {
    public enum EnvOverride: Equatable, Sendable {
        case forceOn, forceOff, ciAutoDisable, none
    }

    public static func decideOverride(env: [String: String]) -> EnvOverride {
        if let raw = env["MACPARAKEET_TELEMETRY"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if ["0", "false", "no", "off"].contains(raw) { return .forceOff }
            if ["1", "true", "yes", "on"].contains(raw) { return .forceOn }
        }
        if env["DO_NOT_TRACK"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return .forceOff }
        return isCIEnvironment(env: env) ? .ciAutoDisable : .none
    }

    public static func isCIEnvironment(env: [String: String]) -> Bool {
        ["CI", "GITHUB_ACTIONS", "GITLAB_CI", "BUILDKITE", "CIRCLECI", "TRAVIS",
         "JENKINS_URL", "TF_BUILD", "TEAMCITY_VERSION"].contains { key in
            guard let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                !value.isEmpty else { return false }
            return !["false", "0", "no", "off"].contains(value)
        }
    }

    public static func guiEnabled(
        preferenceEnabled: Bool, env: [String: String], isDebug: Bool, buildSource: String, version: String
    ) -> Bool {
        preferenceEnabled && guiTransportEligible(
            env: env, isDebug: isDebug, buildSource: buildSource, version: version
        )
    }

    public static func guiTransportEligible(
        env: [String: String], isDebug: Bool, buildSource: String, version: String
    ) -> Bool {
        switch decideOverride(env: env) {
        case .forceOn: return true
        case .forceOff, .ciAutoDisable: return false
        case .none:
            return !isDebug && !buildSource.hasPrefix("dev-")
                && !buildSource.hasPrefix("swiftpm-") && version != "0.0.0" && version != "dev"
        }
    }

    public static func currentGUIEnabled() -> Bool {
        AppPreferences.isTelemetryEnabled(defaults: .standard) && currentGUITransportEligible()
    }

    public static func currentGUITransportEligible() -> Bool {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let identity = BuildIdentity.current
        return guiTransportEligible(
            env: ProcessInfo.processInfo.environment, isDebug: isDebug,
            buildSource: identity.buildSource, version: identity.version
        )
    }
}
