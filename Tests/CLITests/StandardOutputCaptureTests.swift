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
