import Darwin
import Foundation

/// Advisory, per-recordings-root mutation lease that keeps saved-meeting audio
/// deletion/bulk cleanup from racing a split's media export/materialize/publish.
///
/// The lease is nonblocking: acquisition either succeeds immediately or fails
/// with `.busy`, so a `@MainActor` caller is never left waiting on file I/O
/// owned by another mutator. It is intentionally independent of
/// `recording.lock` (capture/finalization ownership): there is no PID-stale
/// logic here, because `flock` is released by the kernel the instant the
/// holding process exits (or closes the descriptor), so a crashed holder can
/// never leave the root permanently locked.
public final class MeetingMediaMutationLease: @unchecked Sendable {
    /// Hidden, regular file living directly in the recordings root, never
    /// inside a per-meeting session folder. That keeps the root's lock
    /// identity stable even after a meeting's session folder is deleted, and
    /// keeps a deleted session folder from ever taking this file with it.
    public static let lockFileName = ".meeting-media-mutation.lock"

    public enum AcquisitionError: Error, LocalizedError, Equatable {
        case busy(root: String)
        case ioFailure(root: String, code: Int32)
        /// The lock path exists but is not a plain regular file (for example a
        /// symlink, FIFO, or device planted at that path). Refused outright:
        /// this lease never follows a symlink into locking/reading/writing an
        /// unrelated file, and never trusts a non-regular file as a lock.
        case unexpectedLockFileType(root: String)

        public var errorDescription: String? {
            switch self {
            case .busy(let root):
                return "Meeting media at \(root) is being used by another operation. Let that operation finish or stop it before trying again."
            case .ioFailure(let root, let code):
                return "Could not lock meeting media at \(root) (errno \(code))."
            case .unexpectedLockFileType(let root):
                return "Meeting media lock at \(root) is not a plain file and cannot be trusted."
            }
        }
    }

    private let stateLock = NSLock()
    private var heldFileDescriptors: [Int32]
    private var isReleased = false

    private init(heldFileDescriptors: [Int32]) {
        self.heldFileDescriptors = heldFileDescriptors
    }

    /// Acquires an exclusive, nonblocking advisory lease over every root.
    ///
    /// Roots are canonicalized (symlinks resolved), deduped, and sorted before
    /// acquisition. Sorting fixes a single lock order across every caller so
    /// two multi-root acquisitions (for example a split's source and
    /// destination roots) can never partially overlap and deadlock each
    /// other; on a failure partway through, every descriptor already opened
    /// by this call is released before the error is thrown, so a caller never
    /// leaks a partial acquisition.
    ///
    /// Each call opens its own file descriptor, and `flock` advisory locks
    /// are scoped to the open file description, not the owning process. Two
    /// independent acquisitions of the same root therefore conflict even
    /// when made from the same process.
    public static func acquire(roots: [URL]) throws -> MeetingMediaMutationLease {
        let canonicalRoots = Set(roots.map(canonicalPath(for:))).sorted()

        var heldFileDescriptors: [Int32] = []
        do {
            for root in canonicalRoots {
                heldFileDescriptors.append(try lockFileDescriptor(forRoot: root))
            }
        } catch {
            heldFileDescriptors.forEach { close($0) }
            throw error
        }

        return MeetingMediaMutationLease(heldFileDescriptors: heldFileDescriptors)
    }

    /// Releases every held root lock. Idempotent: safe to call explicitly and
    /// safe to leave to `deinit`. Closing the descriptor drops its `flock`
    /// regardless of any other opens of the same file, and process death
    /// releases every held lock unconditionally, so there is nothing else to
    /// reconcile on release.
    public func release() {
        let descriptorsToClose: [Int32] = stateLock.withLock {
            guard !isReleased else { return [] }
            isReleased = true
            let descriptors = heldFileDescriptors
            heldFileDescriptors = []
            return descriptors
        }
        descriptorsToClose.forEach { close($0) }
    }

    deinit {
        release()
    }

    private static func lockFileDescriptor(forRoot root: String) throws -> Int32 {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let lockPath = (root as NSString).appendingPathComponent(lockFileName)

        // O_NOFOLLOW refuses to open through a symlink planted at the lock
        // path, so this lease can never be tricked into locking/reading an
        // unrelated file outside the root whose identity it is meant to pin.
        let fileDescriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw AcquisitionError.ioFailure(root: root, code: errno)
        }

        var info = stat()
        guard fstat(fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fileDescriptor)
            throw AcquisitionError.unexpectedLockFileType(root: root)
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let capturedErrno = errno
            close(fileDescriptor)
            if capturedErrno == EWOULDBLOCK {
                throw AcquisitionError.busy(root: root)
            }
            throw AcquisitionError.ioFailure(root: root, code: capturedErrno)
        }

        return fileDescriptor
    }

    private static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
