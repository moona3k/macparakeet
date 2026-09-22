import Darwin
import Foundation

/// Advisory, per-split-child kernel lease that prevents deletion from racing
/// completion automation for a published child.
///
/// Lock files live under the recordings root rather than inside the child's
/// session folder, so their identity survives deletion of that folder. The
/// lease is nonblocking: deletion or processing fails cleanly instead of
/// waiting on a provider call owned by another process.
final class MeetingSplitChildProcessingLease: @unchecked Sendable {
    static let locksDirectoryName = ".meeting-split-child-processing-locks"

    enum AcquisitionError: Error, LocalizedError, Equatable {
        case busy(childId: UUID)
        case ioFailure(childId: UUID, code: Int32)
        case unexpectedLockFileType(childId: UUID)

        var errorDescription: String? {
            switch self {
            case .busy:
                return "This split recording is still being processed. Try deleting it again after processing finishes."
            case .ioFailure(let childId, let code):
                return "Could not lock split recording \(childId) (errno \(code))."
            case .unexpectedLockFileType(let childId):
                return "The processing lock for split recording \(childId) is not a plain file and cannot be trusted."
            }
        }
    }

    private let stateLock = NSLock()
    private var heldFileDescriptor: Int32
    private var isReleased = false

    private init(heldFileDescriptor: Int32) {
        self.heldFileDescriptor = heldFileDescriptor
    }

    static func acquire(childId: UUID, recordingsRootURL: URL) throws -> MeetingSplitChildProcessingLease {
        let lockURL = recordingsRootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(locksDirectoryName, isDirectory: true)
            .appendingPathComponent("\(childId.uuidString.lowercased()).lock")
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fileDescriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw AcquisitionError.ioFailure(childId: childId, code: errno)
        }

        var info = stat()
        guard fstat(fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fileDescriptor)
            throw AcquisitionError.unexpectedLockFileType(childId: childId)
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let capturedErrno = errno
            close(fileDescriptor)
            if capturedErrno == EWOULDBLOCK {
                throw AcquisitionError.busy(childId: childId)
            }
            throw AcquisitionError.ioFailure(childId: childId, code: capturedErrno)
        }

        return MeetingSplitChildProcessingLease(heldFileDescriptor: fileDescriptor)
    }

    func release() {
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
}
