import Darwin
import Foundation

/// Captures stdout payloads emitted by focused CLI unit tests.
/// Stdout is process-global: callers must serialize captures and avoid unrelated printing.
func captureStandardOutput(_ body: () throws -> Void) throws -> String {
    let capture = try StandardOutputCapture()
    var bodyError: Error?
    do {
        try body()
    } catch {
        bodyError = error
    }
    let output = try capture.finish()
    if let bodyError { throw bodyError }
    return output
}

/// Async variant for `AsyncParsableCommand.run()` tests.
/// A regular file avoids blocking a cooperative executor thread on a pipe
/// whose EOF depends on the captured async body getting that same executor.
func captureStandardOutput(_ body: () async throws -> Void) async throws -> String {
    let capture = try StandardOutputCapture()
    var bodyError: Error?
    do {
        try await body()
    } catch {
        bodyError = error
    }
    let output = try capture.finish()
    if let bodyError { throw bodyError }
    return output
}

final class StandardOutputCapture {
    private let file: FileHandle
    private var originalStdout: Int32?
    private let flushStdout: () -> Int32

    init(flushStdout: @escaping () -> Int32 = { fflush(stdout) }) throws {
        self.flushStdout = flushStdout
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-test-stdout-\(UUID().uuidString)").path
        let descriptor = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Self.posixError() }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        // Only the owning descriptors retain this private file, even if a test crashes.
        defer { _ = unlink(path) }
        guard unlink(path) == 0 else { throw Self.posixError() }

        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { throw Self.posixError() }
        var installed = false
        defer { if !installed { close(saved) } }
        guard fcntl(saved, F_SETFD, FD_CLOEXEC) >= 0 else { throw Self.posixError() }
        if let error = flushError() {
            clearerr(stdout)
            throw error
        }
        guard dup2(descriptor, STDOUT_FILENO) >= 0 else { throw Self.posixError() }
        originalStdout = saved
        installed = true
    }

    deinit {
        try? restore()
        if let originalStdout { close(originalStdout) }
    }

    func finish() throws -> String {
        try restore()
        try file.seek(toOffset: 0)
        return String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self)
    }

    private func restore() throws {
        guard let saved = originalStdout else { return }
        let captureError = flushError()
        // Failed captured bytes must never be retried into the restored stdout.
        if captureError != nil { _ = fpurge(stdout) }
        let restored = dup2(saved, STDOUT_FILENO)
        let restoreErrno = errno
        clearerr(stdout)
        guard restored >= 0 else { throw Self.posixError(restoreErrno) }
        close(saved)
        originalStdout = nil
        if let captureError { throw captureError }
    }

    private func flushError() -> NSError? {
        let result = flushStdout()
        let flushErrno = errno
        guard result != 0 || ferror(stdout) != 0 else { return nil }
        // A sticky error may predate this flush. In that case errno can belong
        // to an unrelated operation, so use EIO rather than invent its cause.
        return Self.posixError(result != 0 && flushErrno != 0 ? flushErrno : EIO)
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
