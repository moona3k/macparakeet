import Foundation

public struct SystemInfo: Sendable, Codable {
    public let appVersion: String
    public let buildNumber: String
    public let gitCommit: String
    public let buildSource: String
    public let macOSVersion: String
    public let chipType: String

    public init(
        appVersion: String,
        buildNumber: String,
        gitCommit: String,
        buildSource: String,
        macOSVersion: String,
        chipType: String
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.gitCommit = gitCommit
        self.buildSource = buildSource
        self.macOSVersion = macOSVersion
        self.chipType = chipType
    }

    public static var current: SystemInfo {
        let build = BuildIdentity.current
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let chip = Self.readChipType()

        return SystemInfo(
            appVersion: build.version,
            buildNumber: build.buildNumber,
            gitCommit: build.gitCommit,
            buildSource: build.buildSource,
            macOSVersion: macOS,
            chipType: chip
        )
    }

    public var displaySummary: String {
        [
            "App Version: \(appVersion) (\(buildNumber))",
            "Git Commit:  \(gitCommit)",
            "Build Source: \(buildSource)",
            "macOS:       \(macOSVersion)",
            "Chip:        \(chipType)",
        ].joined(separator: "\n")
    }

    // MARK: - Private

    private static func readChipType() -> String {
        var size: Int = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
