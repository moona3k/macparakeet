import Darwin
import Foundation

public enum MeetingRecordingLockState: String, Codable, Sendable, Equatable {
    case recording
    case awaitingTranscription
}

public struct MeetingRecordingLockFile: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let fileName = "recording.lock"

    public let schemaVersion: Int
    public let sessionId: UUID
    public let startedAt: Date
    public let pid: Int32
    public let displayName: String
    public let state: MeetingRecordingLockState
    public let folderURL: URL?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessionId
        case startedAt
        case pid
        case displayName
        case state
    }

    public init(
        schemaVersion: Int = MeetingRecordingLockFile.currentSchemaVersion,
        sessionId: UUID,
        startedAt: Date,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        displayName: String,
        state: MeetingRecordingLockState = .recording,
        folderURL: URL? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.pid = pid
        self.displayName = displayName
        self.state = state
        self.folderURL = folderURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sessionId = try container.decode(UUID.self, forKey: .sessionId)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        pid = try container.decode(Int32.self, forKey: .pid)
        displayName = try container.decode(String.self, forKey: .displayName)
        state = try container.decodeIfPresent(MeetingRecordingLockState.self, forKey: .state) ?? .recording
        folderURL = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(pid, forKey: .pid)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(state, forKey: .state)
    }

    public func withFolderURL(_ folderURL: URL) -> MeetingRecordingLockFile {
        MeetingRecordingLockFile(
            schemaVersion: schemaVersion,
            sessionId: sessionId,
            startedAt: startedAt,
            pid: pid,
            displayName: displayName,
            state: state,
            folderURL: folderURL
        )
    }

    public func withState(_ state: MeetingRecordingLockState) -> MeetingRecordingLockFile {
        MeetingRecordingLockFile(
            schemaVersion: schemaVersion,
            sessionId: sessionId,
            startedAt: startedAt,
            pid: pid,
            displayName: displayName,
            state: state,
            folderURL: folderURL
        )
    }
}

public protocol MeetingRecordingLockFileStoring: Sendable {
    func write(_ file: MeetingRecordingLockFile, folderURL: URL) throws
    func read(folderURL: URL) throws -> MeetingRecordingLockFile?
    func delete(folderURL: URL) throws
    func discoverOrphans(meetingsRoot: URL) throws -> [MeetingRecordingLockFile]
}

public protocol ProcessAliveChecking: Sendable {
    func isAlive(pid: Int32) -> Bool
}

public struct LiveProcessChecker: ProcessAliveChecking {
    public init() {}

    public func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }

        errno = 0
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}

public final class MeetingRecordingLockFileStore: MeetingRecordingLockFileStoring {
    private let processChecker: any ProcessAliveChecking

    public init(processChecker: any ProcessAliveChecking = LiveProcessChecker()) {
        self.processChecker = processChecker
    }

    public static func lockFileURL(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(MeetingRecordingLockFile.fileName)
    }

    public func write(_ file: MeetingRecordingLockFile, folderURL: URL) throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.meetingRecordingLockFile.encode(file)
        try data.write(to: Self.lockFileURL(for: folderURL), options: .atomic)
    }

    public func read(folderURL: URL) throws -> MeetingRecordingLockFile? {
        let lockFileURL = Self.lockFileURL(for: folderURL)
        guard FileManager.default.fileExists(atPath: lockFileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: lockFileURL)
            let lockFile = try JSONDecoder.meetingRecordingLockFile.decode(
                MeetingRecordingLockFile.self,
                from: data
            )
            guard lockFile.schemaVersion == MeetingRecordingLockFile.currentSchemaVersion else {
                return nil
            }
            return lockFile.withFolderURL(folderURL)
        } catch is DecodingError {
            return nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    public func delete(folderURL: URL) throws {
        let lockFileURL = Self.lockFileURL(for: folderURL)
        guard FileManager.default.fileExists(atPath: lockFileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: lockFileURL)
    }

    public func discoverOrphans(meetingsRoot: URL) throws -> [MeetingRecordingLockFile] {
        guard FileManager.default.fileExists(atPath: meetingsRoot.path) else {
            return []
        }

        let sessionFolders = try FileManager.default.contentsOfDirectory(
            at: meetingsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var discoveries: [MeetingRecordingLockFile] = []
        for folderURL in sessionFolders {
            guard try folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                  let lockFile = try read(folderURL: folderURL),
                  !processChecker.isAlive(pid: lockFile.pid) else {
                continue
            }

            discoveries.append(lockFile)
        }

        return discoveries.sorted {
            if $0.startedAt == $1.startedAt {
                return ($0.folderURL?.path ?? "") < ($1.folderURL?.path ?? "")
            }
            return $0.startedAt < $1.startedAt
        }
    }
}

private extension JSONEncoder {
    static var meetingRecordingLockFile: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var meetingRecordingLockFile: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
