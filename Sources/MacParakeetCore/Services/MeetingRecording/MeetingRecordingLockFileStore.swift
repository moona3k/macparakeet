import Darwin
import Foundation

public enum MeetingRecordingLockState: String, Codable, Sendable, Equatable, CaseIterable {
    case recording
    case awaitingTranscription
}

public struct MeetingRecordingLockFile: Codable, Sendable, Equatable {
    /// Schema 2 distinguishes an independently captured meeting speech-engine
    /// route from schema 1 locks, which always encoded the former shared route.
    /// Other optional fields remain backward-compatible additions.
    /// See ADR-020 §9. The version guard in `MeetingRecordingLockFileStore.read()`
    /// uses `<=` so a lock file written by an OLDER app version is still
    /// readable; a future bump only needs to keep this property + bump the
    /// constant, not add a migration path. Lock files written by a NEWER app
    /// version are intentionally treated as opaque and skipped (we cannot
    /// know which fields they require).
    public static let currentSchemaVersion = 2
    public static let fileName = "recording.lock"

    public let schemaVersion: Int
    public let sessionId: UUID
    public let startedAt: Date
    public let pid: Int32
    public let displayName: String
    public let state: MeetingRecordingLockState
    /// Unique token while a retry or crash recovery owns finalization. `nil`
    /// for the original recording/finalization path and legacy lock files.
    public let finalizationLeaseId: UUID?
    public let speechEngine: SpeechEngineSelection
    /// Whether `speechEngine` was explicitly persisted by the recording build.
    /// Legacy locks without the field retain the Parakeet decode fallback but
    /// must use the current final-transcription route during recovery.
    public let speechEngineWasCaptured: Bool
    public let startContext: MeetingStartContext?
    public let calendarEventSnapshot: MeetingCalendarSnapshot?
    /// Free-form notes the user typed during the meeting. Persisted on
    /// every notepad debounce so a crash recovers what the user had written
    /// up to the last debounce fire. Decoded independently of the rest of
    /// the lock file (ADR-020 §9): a malformed `notes` value cannot block
    /// recovery of the audio metadata.
    public let notes: String?
    public let meetingTypeId: UUID?
    public let folderURL: URL?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessionId
        case startedAt
        case pid
        case displayName
        case state
        case finalizationLeaseId
        case speechEngine
        case startContext
        case calendarEventSnapshot
        case notes
        case meetingTypeId
    }

    public init(
        schemaVersion: Int = MeetingRecordingLockFile.currentSchemaVersion,
        sessionId: UUID,
        startedAt: Date,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        displayName: String,
        state: MeetingRecordingLockState = .recording,
        finalizationLeaseId: UUID? = nil,
        speechEngine: SpeechEngineSelection = SpeechEngineSelection(engine: .parakeet),
        speechEngineWasCaptured: Bool = true,
        startContext: MeetingStartContext? = nil,
        calendarEventSnapshot: MeetingCalendarSnapshot? = nil,
        notes: String? = nil,
        meetingTypeId: UUID? = nil,
        folderURL: URL? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.pid = pid
        self.displayName = displayName
        self.state = state
        self.finalizationLeaseId = finalizationLeaseId
        self.speechEngine = speechEngine
        self.speechEngineWasCaptured = speechEngineWasCaptured
        self.startContext = startContext
        self.calendarEventSnapshot = calendarEventSnapshot
        self.notes = notes
        self.meetingTypeId = meetingTypeId
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
        finalizationLeaseId = try container.decodeIfPresent(
            UUID.self,
            forKey: .finalizationLeaseId
        )
        let decodedSpeechEngine = try container.decodeIfPresent(SpeechEngineSelection.self, forKey: .speechEngine)
        speechEngine = decodedSpeechEngine ?? SpeechEngineSelection(engine: .parakeet)
        speechEngineWasCaptured = schemaVersion >= 2 && decodedSpeechEngine != nil
        startContext = (try? container.decodeIfPresent(MeetingStartContext.self, forKey: .startContext)) ?? nil
        // Calendar snapshots are best-effort context. A malformed optional
        // snapshot must not block lock-file recovery of the audio metadata.
        calendarEventSnapshot =
            (try? container.decodeIfPresent(
                MeetingCalendarSnapshot.self,
                forKey: .calendarEventSnapshot
            )) ?? nil
        // Notes are decoded independently — see ADR-020 §9. If a future encoder
        // bug or hand-edited file produces a malformed `notes` value, recovery
        // of the audio metadata still succeeds; only the typed notes are lost.
        notes = (try? container.decodeIfPresent(String.self, forKey: .notes)) ?? nil
        meetingTypeId = (try? container.decodeIfPresent(UUID.self, forKey: .meetingTypeId)) ?? nil
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
        try container.encodeIfPresent(finalizationLeaseId, forKey: .finalizationLeaseId)
        if speechEngineWasCaptured {
            try container.encode(speechEngine, forKey: .speechEngine)
        }
        try container.encodeIfPresent(startContext, forKey: .startContext)
        try container.encodeIfPresent(calendarEventSnapshot, forKey: .calendarEventSnapshot)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(meetingTypeId, forKey: .meetingTypeId)
    }

    public func withFolderURL(_ folderURL: URL) -> MeetingRecordingLockFile {
        MeetingRecordingLockFile(
            schemaVersion: schemaVersion,
            sessionId: sessionId,
            startedAt: startedAt,
            pid: pid,
            displayName: displayName,
            state: state,
            finalizationLeaseId: finalizationLeaseId,
            speechEngine: speechEngine,
            speechEngineWasCaptured: speechEngineWasCaptured,
            startContext: startContext,
            calendarEventSnapshot: calendarEventSnapshot,
            notes: notes,
            meetingTypeId: meetingTypeId,
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
            finalizationLeaseId: finalizationLeaseId,
            speechEngine: speechEngine,
            speechEngineWasCaptured: speechEngineWasCaptured,
            startContext: startContext,
            calendarEventSnapshot: calendarEventSnapshot,
            notes: notes,
            meetingTypeId: meetingTypeId,
            folderURL: folderURL
        )
    }

    public func withNotes(_ notes: String?) -> MeetingRecordingLockFile {
        MeetingRecordingLockFile(
            schemaVersion: schemaVersion,
            sessionId: sessionId,
            startedAt: startedAt,
            pid: pid,
            displayName: displayName,
            state: state,
            finalizationLeaseId: finalizationLeaseId,
            speechEngine: speechEngine,
            speechEngineWasCaptured: speechEngineWasCaptured,
            startContext: startContext,
            calendarEventSnapshot: calendarEventSnapshot,
            notes: notes,
            meetingTypeId: meetingTypeId,
            folderURL: folderURL
        )
    }

    public func withMeetingTypeId(_ meetingTypeId: UUID?) -> MeetingRecordingLockFile {
        MeetingRecordingLockFile(
            schemaVersion: schemaVersion,
            sessionId: sessionId,
            startedAt: startedAt,
            pid: pid,
            displayName: displayName,
            state: state,
            finalizationLeaseId: finalizationLeaseId,
            speechEngine: speechEngine,
            speechEngineWasCaptured: speechEngineWasCaptured,
            startContext: startContext,
            calendarEventSnapshot: calendarEventSnapshot,
            notes: notes,
            meetingTypeId: meetingTypeId,
            folderURL: folderURL
        )
    }

    public func withFinalizationOwner(
        pid: Int32,
        leaseID: UUID
    ) -> MeetingRecordingLockFile {
        MeetingRecordingLockFile(
            schemaVersion: schemaVersion,
            sessionId: sessionId,
            startedAt: startedAt,
            pid: pid,
            displayName: displayName,
            state: .awaitingTranscription,
            finalizationLeaseId: leaseID,
            speechEngine: speechEngine,
            speechEngineWasCaptured: speechEngineWasCaptured,
            startContext: startContext,
            calendarEventSnapshot: calendarEventSnapshot,
            notes: notes,
            meetingTypeId: meetingTypeId,
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

public struct MeetingFinalizationOwnershipLease: Sendable, Equatable {
    public let id: UUID
    public let folderURL: URL
    public let previousLock: MeetingRecordingLockFile

    public init(
        id: UUID,
        folderURL: URL,
        previousLock: MeetingRecordingLockFile
    ) {
        self.id = id
        self.folderURL = folderURL
        self.previousLock = previousLock
    }
}

public enum MeetingFinalizationOwnershipError: Error, LocalizedError, Sendable, Equatable {
    case missingLock
    case ownedByLiveProcess(pid: Int32)

    public var errorDescription: String? {
        switch self {
        case .missingLock:
            return "The meeting recovery record is missing. The saved audio was not changed."
        case .ownedByLiveProcess:
            return "This meeting is already being transcribed by MacParakeet."
        }
    }
}

public protocol MeetingFinalizationOwnershipClaiming: Sendable {
    func claimFinalizationOwnership(
        folderURL: URL
    ) throws -> MeetingFinalizationOwnershipLease
    func releaseFinalizationOwnership(_ lease: MeetingFinalizationOwnershipLease) throws
}

public protocol MeetingFinalizationReconciliationCoordinating: Sendable {
    /// Runs `transition` only while this folder has no live owner. The
    /// ownership check and transition are serialized against retry/recovery
    /// claims by the folder's advisory lock.
    func reconcileIfUnowned(
        folderURL: URL,
        transition: @Sendable () throws -> Bool
    ) throws -> Bool
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

public final class MeetingRecordingLockFileStore:
    MeetingRecordingLockFileStoring,
    MeetingFinalizationOwnershipClaiming,
    MeetingFinalizationReconciliationCoordinating
{
    private static let finalizationOwnershipMutexFileName = ".finalization-ownership.lock"
    private static let relinquishedFinalizationLeases =
        MeetingFinalizationRelinquishedLeaseRegistry()

    private let processChecker: any ProcessAliveChecking
    private let processID: Int32

    public init(
        processChecker: any ProcessAliveChecking = LiveProcessChecker(),
        processID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.processChecker = processChecker
        self.processID = processID
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
            // Accept any version up to and including the current — older
            // schemas decode via `decodeIfPresent` for added fields. A
            // newer schema is opaque to us, so skip it rather than risk
            // misinterpreting required fields we don't know about yet.
            guard lockFile.schemaVersion <= MeetingRecordingLockFile.currentSchemaVersion else {
                return nil
            }
            return lockFile.withFolderURL(folderURL)
        } catch is DecodingError {
            return nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// Whether a readable lock in this exact session folder belongs to a
    /// process that is still alive. Startup reconciliation uses the per-folder
    /// check because a meeting row already carries its canonical artifact path;
    /// scanning a global root would miss custom roots and do unnecessary I/O.
    public func hasLiveOwner(folderURL: URL) throws -> Bool {
        if let lockFile = try read(folderURL: folderURL) {
            return processChecker.isAlive(pid: lockFile.pid)
                && !hasRelinquishedFinalizationLease(lockFile)
        }
        // `read` maps a newer schema to nil so older builds do not invent
        // fields they cannot understand. Reconciliation must still honor a
        // peeked live PID, or an older process will mark the newer build's
        // in-flight row failed.
        if let header = peekLockFileHeader(folderURL: folderURL),
            let schemaVersion = header.schemaVersion,
            schemaVersion > MeetingRecordingLockFile.currentSchemaVersion,
            let pid = header.pid
        {
            return processChecker.isAlive(pid: pid)
        }
        return false
    }

    public func claimFinalizationOwnership(
        folderURL: URL
    ) throws -> MeetingFinalizationOwnershipLease {
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            throw MeetingFinalizationOwnershipError.missingLock
        }
        return try withFinalizationOwnershipMutex(folderURL: folderURL) {
            guard let currentLock = try readableOrUnreadablePresentLock(folderURL: folderURL)
            else {
                throw MeetingFinalizationOwnershipError.missingLock
            }
            let currentProcessAlreadyOwnsLease =
                currentLock.pid == processID
                && currentLock.finalizationLeaseId.map {
                    !Self.relinquishedFinalizationLeases.contains($0)
                } == true
            let anotherProcessIsAlive =
                currentLock.pid != processID && processChecker.isAlive(pid: currentLock.pid)
            if currentProcessAlreadyOwnsLease || anotherProcessIsAlive {
                throw MeetingFinalizationOwnershipError.ownedByLiveProcess(pid: currentLock.pid)
            }

            let lease = MeetingFinalizationOwnershipLease(
                id: UUID(),
                folderURL: folderURL.standardizedFileURL,
                previousLock: currentLock.finalizationLeaseId.flatMap {
                    Self.relinquishedFinalizationLeases.previousLock(for: $0)
                } ?? currentLock
            )
            try write(
                currentLock.withFinalizationOwner(pid: processID, leaseID: lease.id),
                folderURL: folderURL
            )
            if let previousLeaseID = currentLock.finalizationLeaseId {
                Self.relinquishedFinalizationLeases.remove(previousLeaseID)
            }
            return lease
        }
    }

    public func releaseFinalizationOwnership(
        _ lease: MeetingFinalizationOwnershipLease
    ) throws {
        do {
            try withFinalizationOwnershipMutex(folderURL: lease.folderURL) {
                guard let currentLock = try read(folderURL: lease.folderURL),
                    currentLock.finalizationLeaseId == lease.id
                else {
                    return
                }
                try write(lease.previousLock, folderURL: lease.folderURL)
            }
            Self.relinquishedFinalizationLeases.remove(lease.id)
        } catch {
            // The owner has finished even when restoring the prior lock hits a
            // transient I/O failure. Remember that exact token so a later
            // retry in this process can replace it without treating abandoned
            // work as an active same-process finalization.
            Self.relinquishedFinalizationLeases.insert(lease)
            throw error
        }
    }

    public func reconcileIfUnowned(
        folderURL: URL,
        transition: @Sendable () throws -> Bool
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            return try transition()
        }
        return try withFinalizationOwnershipMutex(folderURL: folderURL) {
            guard try !hasLiveOwner(folderURL: folderURL) else {
                return false
            }
            return try transition()
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
        // Orphans are crashed sessions: a lock file whose owning process is no
        // longer alive, or a same-process finalization lease explicitly
        // relinquished after lock restoration failed. Their audio is
        // recoverable, not in active use.
        try sortedSessions(meetingsRoot: meetingsRoot) {
            hasRelinquishedFinalizationLease($0)
                || !processChecker.isAlive(pid: $0.pid)
        }
    }

    /// Lock files in `meetingsRoot` whose owning process is still alive, minus
    /// an exact lease token this process recorded as relinquished after a
    /// restore failure. The in-process result is the inverse of
    /// `discoverOrphans`.
    ///
    /// Used by out-of-process callers (the CLI) that cannot observe the GUI's
    /// live recording state but must avoid clobbering an in-progress session's
    /// folder on disk. The relinquishment registry is process-local, so those
    /// callers conservatively see the same disk signal recovery otherwise
    /// trusts: `pid` liveness via `ProcessAliveChecking`.
    public func discoverActiveSessions(meetingsRoot: URL) throws -> [MeetingRecordingLockFile] {
        try sortedSessions(meetingsRoot: meetingsRoot) {
            !hasRelinquishedFinalizationLease($0)
                && processChecker.isAlive(pid: $0.pid)
        }
    }

    /// Every readable recording lock under `meetingsRoot`, regardless of PID
    /// liveness or state. Destructive retention paths use this stricter scan:
    /// a dead-owner `.awaitingTranscription` lock still represents saved audio
    /// that has not been finalized into a transcript yet.
    public func discoverAnySessions(meetingsRoot: URL) throws -> [MeetingRecordingLockFile] {
        try sortedSessions(meetingsRoot: meetingsRoot) { _ in true }
    }

    private func sortedSessions(
        meetingsRoot: URL,
        where predicate: (MeetingRecordingLockFile) -> Bool
    ) throws -> [MeetingRecordingLockFile] {
        guard FileManager.default.fileExists(atPath: meetingsRoot.path) else {
            return []
        }

        let sessionFolders = try FileManager.default.contentsOfDirectory(
            at: meetingsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var matches: [MeetingRecordingLockFile] = []
        for folderURL in sessionFolders {
            guard try folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                let lockFile = try read(folderURL: folderURL),
                predicate(lockFile)
            else {
                continue
            }

            matches.append(lockFile)
        }

        return matches.sorted {
            if $0.startedAt == $1.startedAt {
                return ($0.folderURL?.path ?? "") < ($1.folderURL?.path ?? "")
            }
            return $0.startedAt < $1.startedAt
        }
    }

    /// Retry must still be able to take over a folder whose `recording.lock`
    /// is present but unreadable (corrupt JSON, zero-byte). `read` maps those
    /// to `nil`, which used to look like a missing lock and bricked claim
    /// after reconciliation had already marked the row retryable.
    ///
    /// A newer schema is different: if its peeked PID is still alive, claim
    /// must refuse rather than overwrite a lock this build cannot interpret.
    private func readableOrUnreadablePresentLock(
        folderURL: URL
    ) throws -> MeetingRecordingLockFile? {
        if let readableLock = try read(folderURL: folderURL) {
            return readableLock
        }
        if let header = peekLockFileHeader(folderURL: folderURL),
            let schemaVersion = header.schemaVersion,
            schemaVersion > MeetingRecordingLockFile.currentSchemaVersion,
            let pid = header.pid,
            processChecker.isAlive(pid: pid)
        {
            throw MeetingFinalizationOwnershipError.ownedByLiveProcess(pid: pid)
        }
        guard
            FileManager.default.fileExists(
                atPath: Self.lockFileURL(for: folderURL).path
            )
        else {
            return nil
        }
        return MeetingRecordingLockFile(
            sessionId: UUID(),
            startedAt: Date(),
            pid: 0,
            displayName: folderURL.lastPathComponent,
            state: .awaitingTranscription
        )
    }

    private struct LockFileHeader {
        var schemaVersion: Int?
        var pid: Int32?
    }

    private func peekLockFileHeader(folderURL: URL) -> LockFileHeader? {
        let lockFileURL = Self.lockFileURL(for: folderURL)
        guard FileManager.default.fileExists(atPath: lockFileURL.path),
            let data = try? Data(contentsOf: lockFileURL),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }
        let schemaVersion = intValue(in: dictionary, key: "schemaVersion")
        let pid = intValue(in: dictionary, key: "pid").map(Int32.init)
        return LockFileHeader(schemaVersion: schemaVersion, pid: pid)
    }

    private func intValue(in dictionary: [String: Any], key: String) -> Int? {
        if let value = dictionary[key] as? Int {
            return value
        }
        if let value = dictionary[key] as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private func hasRelinquishedFinalizationLease(
        _ lockFile: MeetingRecordingLockFile
    ) -> Bool {
        guard lockFile.pid == processID,
            let leaseID = lockFile.finalizationLeaseId
        else {
            return false
        }
        return Self.relinquishedFinalizationLeases.contains(leaseID)
    }

    private func withFinalizationOwnershipMutex<T>(
        folderURL: URL,
        _ operation: () throws -> T
    ) throws -> T {
        let mutexURL = folderURL.appendingPathComponent(
            Self.finalizationOwnershipMutexFileName
        )
        let fileDescriptor = open(
            mutexURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        guard flock(fileDescriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(fileDescriptor, LOCK_UN) }

        return try operation()
    }
}

private final class MeetingFinalizationRelinquishedLeaseRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var previousLocksByLeaseID: [UUID: MeetingRecordingLockFile] = [:]

    func contains(_ leaseID: UUID) -> Bool {
        lock.withLock { previousLocksByLeaseID[leaseID] != nil }
    }

    func previousLock(for leaseID: UUID) -> MeetingRecordingLockFile? {
        lock.withLock { previousLocksByLeaseID[leaseID] }
    }

    func insert(_ lease: MeetingFinalizationOwnershipLease) {
        lock.withLock {
            previousLocksByLeaseID[lease.id] = lease.previousLock
        }
    }

    func remove(_ leaseID: UUID) {
        _ = lock.withLock {
            previousLocksByLeaseID.removeValue(forKey: leaseID)
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
