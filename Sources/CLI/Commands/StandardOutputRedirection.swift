import Darwin
import Foundation

/// Temporarily route process stdout to stderr.
///
/// Some native inference stacks write diagnostics directly to file descriptor 1,
/// bypassing Swift logging and `printErr`. CLI commands with stdout payload
/// contracts can use this while doing native work, then restore stdout before
/// emitting the actual payload.
final class StandardOutputRedirection {
    private var savedStdout: Int32?

    init(to targetFileDescriptor: Int32 = STDERR_FILENO) throws {
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard dup2(targetFileDescriptor, STDOUT_FILENO) >= 0 else {
            let errorNumber = errno
            close(saved)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorNumber))
        }
        savedStdout = saved
    }

    func restore() throws {
        guard let saved = savedStdout else { return }
        fflush(stdout)
        guard dup2(saved, STDOUT_FILENO) >= 0 else {
            let errorNumber = errno
            close(saved)
            savedStdout = nil
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorNumber))
        }
        close(saved)
        savedStdout = nil
    }

    deinit {
        guard let saved = savedStdout else { return }
        fflush(stdout)
        _ = dup2(saved, STDOUT_FILENO)
        close(saved)
    }
}
