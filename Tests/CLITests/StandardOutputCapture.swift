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

private final class StandardOutputCapture {
    private let file: FileHandle
    private var originalStdout: Int32?

    init() throws {
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
        fflush(stdout)
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
        fflush(stdout)
        guard dup2(saved, STDOUT_FILENO) >= 0 else { throw Self.posixError() }
        close(saved)
        originalStdout = nil
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
