import Foundation

public struct BuildIdentity: Sendable {
    public let version: String
    public let buildNumber: String
    public let gitCommit: String
    public let buildDateUTC: String
    public let buildSource: String
    public let executablePath: String
    public let bundlePath: String

    public static var current: BuildIdentity {
        let bundle = Bundle.main
        let env = ProcessInfo.processInfo.environment
        let executablePath = CommandLine.arguments.first ?? "unknown"
        let bundlePath = bundle.bundlePath

        let version = read(bundle: bundle, key: "CFBundleShortVersionString", fallback: "dev")
        let buildNumber = read(bundle: bundle, key: "CFBundleVersion", fallback: "dev")
        let gitCommit = read(
            bundle: bundle,
            key: "MacParakeetGitCommit",
            env: env,
            envKey: "MACPARAKEET_GIT_COMMIT",
            fallback: "unknown"
        )
        let buildDateUTC = read(
            bundle: bundle,
            key: "MacParakeetBuildDateUTC",
            env: env,
            envKey: "MACPARAKEET_BUILD_DATE_UTC",
            fallback: "unknown"
        )
        let buildSource = read(
            bundle: bundle,
            key: "MacParakeetBuildSource",
            env: env,
            envKey: "MACPARAKEET_BUILD_SOURCE",
            fallback: derivedSource(executablePath: executablePath, bundlePath: bundlePath)
        )

        return BuildIdentity(
            version: version,
            buildNumber: buildNumber,
            gitCommit: gitCommit,
            buildDateUTC: buildDateUTC,
            buildSource: buildSource,
            executablePath: executablePath,
            bundlePath: bundlePath
        )
    }

    private static func read(
        bundle: Bundle,
        key: String,
        fallback: String
    ) -> String {
        let raw = bundle.object(forInfoDictionaryKey: key) as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func read(
        bundle: Bundle,
        key: String,
        env: [String: String],
        envKey: String,
        fallback: String
    ) -> String {
        let fromBundle = read(bundle: bundle, key: key, fallback: "")
        if !fromBundle.isEmpty { return fromBundle }
        let fromEnv = env[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromEnv.isEmpty { return fromEnv }
        return fallback
    }

    private static func derivedSource(executablePath: String, bundlePath: String) -> String {
        if executablePath.contains("/.build/") {
            return "swiftpm-debug"
        }
        if bundlePath.hasPrefix("/Applications/") {
            return "applications-bundle"
        }
        if bundlePath.contains("/dist/") {
            return "dist-bundle"
        }
        if bundlePath.hasSuffix(".app") {
            return "app-bundle"
        }
        return "unknown"
    }
}
