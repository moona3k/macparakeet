import Darwin
import Foundation
import XCTest

final class StandardOutputCaptureTests: XCTestCase {
    func testSynchronousCapturePreservesLargePayloadAndNestedOutput() throws {
        let payload = String(repeating: "large payload\n", count: 20_000)
        let output = try captureStandardOutput {
            print("before")
            let inner = try captureStandardOutput { print(payload, terminator: "") }
            XCTAssertEqual(inner, payload)
            print("after")
        }
        XCTAssertEqual(output, "before\nafter\n")
    }

    func testAsyncCapturePreservesLargePayloadAcrossActorSuspension() async throws {
        let writer = CaptureTestWriter()
        let payload = String(repeating: "async payload\n", count: 20_000)
        let output = try await captureStandardOutput {
            await Task.yield()
            await writer.write(payload)
        }
        XCTAssertEqual(output, payload)
    }

    func testThrowingBodiesRestoreOriginalStdout() async throws {
        let original = try stdoutIdentity()
        XCTAssertThrowsError(
            try captureStandardOutput {
                print("discarded"); throw CaptureTestError.expected
            }
        ) {
            XCTAssertTrue($0 is CaptureTestError)
        }
        do {
            _ = try await captureStandardOutput {
                await Task.yield()
                print("discarded")
                throw CaptureTestError.expected
            }
            XCTFail("Expected the body error")
        } catch is CaptureTestError {}
        let restored = try stdoutIdentity()
        XCTAssertEqual(restored.device, original.device)
        XCTAssertEqual(restored.inode, original.inode)
        XCTAssertEqual(try captureStandardOutput { print("restored") }, "restored\n")
    }

    func testCancellationRestoresOriginalStdout() async throws {
        let original = try stdoutIdentity()
        let entered = expectation(description: "Capture body entered")
        let task = Task {
            try await captureStandardOutput {
                entered.fulfill()
                try await Task.sleep(for: .seconds(30))
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let restored = try stdoutIdentity()
        XCTAssertEqual(restored.device, original.device)
        XCTAssertEqual(restored.inode, original.inode)
        XCTAssertEqual(try captureStandardOutput { print("restored") }, "restored\n")
    }

    func testInitialFlushFailurePreservesStdoutAndErrno() throws {
        let original = try stdoutIdentity()
        XCTAssertThrowsError(
            try StandardOutputCapture(flushStdout: {
                errno = ENOSPC
                return EOF
            })
        ) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOSPC))
        }
        try assertStdoutRestored(original)
    }

    func testFinalFlushFailureRestoresStdoutBeforeThrowing() throws {
        let original = try stdoutIdentity()
        var calls = 0
        let capture = try StandardOutputCapture(flushStdout: {
            calls += 1
            if calls == 1 { return fflush(stdout) }
            errno = ENOSPC
            return EOF
        })
        fputs("capture bytes that must not escape", stdout)
        XCTAssertThrowsError(try capture.finish()) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOSPC))
        }
        XCTAssertEqual(calls, 2)
        try assertStdoutRestored(original)
    }

    func testStickyWriteErrorIsReportedAndClearedForNextCapture() throws {
        let original = try stdoutIdentity()
        let capture = try StandardOutputCapture()
        let target = dup(STDOUT_FILENO)
        guard target >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(target) }
        let readOnly = open("/dev/null", O_RDONLY)
        guard readOnly >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(readOnly) }
        XCTAssertGreaterThanOrEqual(dup2(readOnly, STDOUT_FILENO), 0)
        fputs("failed write", stdout)
        _ = fflush(stdout)
        XCTAssertNotEqual(ferror(stdout), 0, "The test must create a real stdio write error")
        XCTAssertGreaterThanOrEqual(dup2(target, STDOUT_FILENO), 0)
        errno = EACCES  // A successful flush must not reuse an unrelated errno.
        XCTAssertThrowsError(try capture.finish()) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EIO))
        }
        try assertStdoutRestored(original)
    }

    private func assertStdoutRestored(_ original: (device: dev_t, inode: ino_t)) throws {
        let restored = try stdoutIdentity()
        XCTAssertEqual(restored.device, original.device)
        XCTAssertEqual(restored.inode, original.inode)
        XCTAssertEqual(ferror(stdout), 0, "Capture failures must not poison the stdout stream")
        XCTAssertEqual(try captureStandardOutput { print("next capture") }, "next capture\n")
    }

    private func stdoutIdentity() throws -> (device: dev_t, inode: ino_t) {
        var info = stat()
        guard fstat(STDOUT_FILENO, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return (info.st_dev, info.st_ino)
    }
}

private enum CaptureTestError: Error { case expected }

private actor CaptureTestWriter {
    func write(_ text: String) { print(text, terminator: "") }
}
