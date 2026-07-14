import Foundation

public enum CommandLineToolInstallStatus: Equatable, Sendable {
    case installed
    case notInstalled
    case staleSymlink(currentTarget: String)
    case pathConflict(path: String)
    case unsupportedTranslocated
    case unsupportedEnvironment(String)
}

public enum CommandLineToolInstallError: Error, LocalizedError, Equatable, Sendable {
    case staleSymlink(currentTarget: String)
    case pathConflict(path: String)
    case unsupportedTranslocated
    case unsupportedEnvironment(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .staleSymlink(let currentTarget):
            return "macparakeet-cli already points to \(currentTarget). Review before replacing it."
        case .pathConflict(let path):
            return "\(path) already exists and is not a symbolic link."
        case .unsupportedTranslocated:
            return "Move MacParakeet to /Applications, relaunch it, then try again."
        case .unsupportedEnvironment(let message):
            return message
        case .operationFailed(let message):
            return message
        }
    }
}

public protocol CommandLineToolInstalling {
    func currentStatus() async -> CommandLineToolInstallStatus
    func install(overwriteExisting: Bool) async throws -> CommandLineToolInstallStatus
}

public actor CommandLineToolInstallService: CommandLineToolInstalling {
    public static let defaultLinkName = "macparakeet-cli"

    private let fileManager: FileManager
    private let bundledToolURL: URL
    private let installDirectory: URL
    private let linkName: String

    public init(
        fileManager: FileManager = .default,
        bundledToolURL: URL = CommandLineToolInstallService.defaultBundledToolURL(),
        installDirectory: URL = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        linkName: String = CommandLineToolInstallService.defaultLinkName
    ) {
        self.fileManager = fileManager
        self.bundledToolURL = bundledToolURL
        self.installDirectory = installDirectory
        self.linkName = linkName
    }

    public static func defaultBundledToolURL(bundle: Bundle = .main) -> URL {
        if bundle.bundleURL.pathExtension == "app" {
            return bundle.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent(defaultLinkName)
        }

        if let executableURL = bundle.executableURL {
            return executableURL
                .deletingLastPathComponent()
                .appendingPathComponent(defaultLinkName)
        }

        return URL(fileURLWithPath: defaultLinkName)
    }

    public func currentStatus() async -> CommandLineToolInstallStatus {
        if let unavailable = unavailableStatusForBundledTool() {
            return unavailable
        }

        if let currentTarget = symbolicLinkDestination(at: linkURL) {
            return pointsAtBundledTool(currentTarget)
                ? .installed
                : .staleSymlink(currentTarget: currentTarget.path)
        }

        if fileManager.fileExists(atPath: linkURL.path) {
            return .pathConflict(path: linkURL.path)
        }

        return .notInstalled
    }

    public func install(overwriteExisting: Bool) async throws -> CommandLineToolInstallStatus {
        if let unavailable = unavailableStatusForBundledTool() {
            throw error(for: unavailable)
        }

        do {
            try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)

            if let currentTarget = symbolicLinkDestination(at: linkURL) {
                if pointsAtBundledTool(currentTarget) {
                    return .installed
                }

                guard overwriteExisting else {
                    throw CommandLineToolInstallError.staleSymlink(currentTarget: currentTarget.path)
                }
                try fileManager.removeItem(at: linkURL)
            } else if fileManager.fileExists(atPath: linkURL.path) {
                throw CommandLineToolInstallError.pathConflict(path: linkURL.path)
            }

            try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: bundledToolURL.path)
            return .installed
        } catch let error as CommandLineToolInstallError {
            throw error
        } catch {
            throw CommandLineToolInstallError.operationFailed(error.localizedDescription)
        }
    }

    private var linkURL: URL {
        installDirectory.appendingPathComponent(linkName)
    }

    private func unavailableStatusForBundledTool() -> CommandLineToolInstallStatus? {
        if bundledToolURL.path.contains("/AppTranslocation/") {
            return .unsupportedTranslocated
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundledToolURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .unsupportedEnvironment("Bundled macparakeet-cli was not found.")
        }

        return nil
    }

    private func symbolicLinkDestination(at url: URL) -> URL? {
        guard let destinationPath = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }

        if destinationPath.hasPrefix("/") {
            return URL(fileURLWithPath: destinationPath).standardizedFileURL
        }

        return url
            .deletingLastPathComponent()
            .appendingPathComponent(destinationPath)
            .standardizedFileURL
    }

    private func pointsAtBundledTool(_ target: URL) -> Bool {
        target.standardizedFileURL.resolvingSymlinksInPath().path
            == bundledToolURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func error(for status: CommandLineToolInstallStatus) -> CommandLineToolInstallError {
        switch status {
        case .installed, .notInstalled:
            return .operationFailed("Command line tool installation could not determine the current state.")
        case .staleSymlink(let currentTarget):
            return .staleSymlink(currentTarget: currentTarget)
        case .pathConflict(let path):
            return .pathConflict(path: path)
        case .unsupportedTranslocated:
            return .unsupportedTranslocated
        case .unsupportedEnvironment(let message):
            return .unsupportedEnvironment(message)
        }
    }
}
