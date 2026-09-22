import CryptoKit
import Darwin
import Foundation

/// Advisory, per-split-operation kernel lease keyed by the operation's own
/// idempotency key (never by `operationId` directly, so a caller that only
/// knows the key — including the very first `createAndProcess` call, before
/// any operation row exists — can serialize against every other entry point
/// that later resolves to the same operation).
///
/// This is a lock file of its own, entirely separate from
/// `MeetingMediaMutationLease`'s root lock file: the two are never the same
/// `flock`, so acquiring one never recursively re-acquires the other.
/// Nonblocking, like `MeetingMediaMutationLease`: acquisition either succeeds
/// immediately or fails with `.busy`, so a caller is never left blocked on
/// another process's split work.
public final class MeetingSplitOperationLease: @unchecked Sendable {
    private static let locksDirectoryName = ".meeting-split-operation-locks"

    public enum AcquisitionError: Error, LocalizedError, Equatable {
        case busy(idempotencyKey: String)
        case ioFailure(idempotencyKey: String, code: Int32)
        /// The lock path exists but is not a plain regular file. Refused
        /// outright, matching `MeetingMediaMutationLease`'s same guard.
        case unexpectedLockFileType(idempotencyKey: String)

        public var errorDescription: String? {
            switch self {
            case .busy(let key):
                return "Split operation '\(key)' is already being processed by another caller. Try again in a moment."
            case .ioFailure(let key, let code):
                return "Could not lock split operation '\(key)' (errno \(code))."
            case .unexpectedLockFileType(let key):
                return "Split operation lock for '\(key)' is not a plain file and cannot be trusted."
            }
        }
    }

    private let stateLock = NSLock()
    private var heldFileDescriptor: Int32
    private var isReleased = false

    private init(heldFileDescriptor: Int32) {
        self.heldFileDescriptor = heldFileDescriptor
    }

    /// Acquires the exclusive, nonblocking claim for `idempotencyKey`. Every
    /// entry point that touches a split operation (create, process, resume,
    /// discard) must acquire this before reading or mutating anything, and
    /// hold it for that entire call.
    public static func acquire(
        idempotencyKey: String,
        meetingRecordingsRootURL: URL
    ) throws -> MeetingSplitOperationLease {
        let lockURL = lockFileURL(idempotencyKey: idempotencyKey, meetingRecordingsRootURL: meetingRecordingsRootURL)
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // O_NOFOLLOW: never lock/read through a symlink planted at the lock path.
        let fileDescriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw AcquisitionError.ioFailure(idempotencyKey: idempotencyKey, code: errno)
        }

        var info = stat()
        guard fstat(fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fileDescriptor)
            throw AcquisitionError.unexpectedLockFileType(idempotencyKey: idempotencyKey)
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let capturedErrno = errno
            close(fileDescriptor)
            if capturedErrno == EWOULDBLOCK {
                throw AcquisitionError.busy(idempotencyKey: idempotencyKey)
            }
            throw AcquisitionError.ioFailure(idempotencyKey: idempotencyKey, code: capturedErrno)
        }

        return MeetingSplitOperationLease(heldFileDescriptor: fileDescriptor)
    }

    /// Releases the claim. Idempotent; also safe to leave to `deinit` since
    /// process death (or descriptor close) drops the kernel `flock`
    /// unconditionally, so a crashed holder never leaves this permanently
    /// locked.
    public func release() {
        let descriptorToClose: Int32? = stateLock.withLock {
            guard !isReleased else { return nil }
            isReleased = true
            let descriptor = heldFileDescriptor
            heldFileDescriptor = -1
            return descriptor
        }
        if let descriptorToClose { close(descriptorToClose) }
    }

    deinit {
        release()
    }

    /// Nonblocking ownership probe scoped to this exact operation's own lock
    /// file — never a global media-root probe. `true` means another live
    /// process currently holds this operation's claim; `false` means it does
    /// not. Any failure other than the lock being held (I/O error, unexpected
    /// lock file type) is thrown rather than treated as "not owned", so a
    /// startup reconciler never mistakes a filesystem problem for a free
    /// operation. Suitable for a later native startup reconciler deciding
    /// whether a `.processing` split child (which has no capture
    /// `recording.lock`) is still actively owned by a live process.
    public static func isActivelyOwned(
        idempotencyKey: String,
        meetingRecordingsRootURL: URL
    ) throws -> Bool {
        do {
            let lease = try acquire(idempotencyKey: idempotencyKey, meetingRecordingsRootURL: meetingRecordingsRootURL)
            lease.release()
            return false
        } catch AcquisitionError.busy {
            return true
        }
    }

    private static func lockFileURL(idempotencyKey: String, meetingRecordingsRootURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(idempotencyKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return meetingRecordingsRootURL
            .appendingPathComponent(locksDirectoryName, isDirectory: true)
            .appendingPathComponent("\(digest).lock")
    }
}
