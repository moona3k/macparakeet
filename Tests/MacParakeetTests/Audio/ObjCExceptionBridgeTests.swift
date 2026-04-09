import Foundation
import XCTest
@testable import MacParakeetCore
import MacParakeetObjCShims

/// Tests for the Objective-C exception catcher that protects AVFAudio calls.
/// See issue #91 — without this trampoline, Swift can't catch `NSException`
/// raised by `AVAudioEngine.inputNode.installTap(...)` and the process aborts.
final class ObjCExceptionBridgeTests: XCTestCase {

    // MARK: - MPKTryBlock (the underlying C API)

    func testMPKTryBlockReturnsTrueOnNormalCompletion() {
        var ran = false
        var error: NSError?
        let ok = MPKTryBlock({ ran = true }, &error)

        XCTAssertTrue(ok)
        XCTAssertTrue(ran)
        XCTAssertNil(error)
    }

    func testMPKTryBlockCatchesNSExceptionAndPopulatesError() {
        var error: NSError?
        let ok = MPKTryBlock({
            NSException(
                name: NSExceptionName("TestExceptionName"),
                reason: "synthetic reason for unit test",
                userInfo: ["key": "value"]
            ).raise()
        }, &error)

        XCTAssertFalse(ok)
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.domain, MPKObjCExceptionErrorDomain)
        XCTAssertEqual(error?.userInfo[MPKObjCExceptionNameKey] as? String, "TestExceptionName")
        XCTAssertEqual(
            error?.userInfo[MPKObjCExceptionReasonKey] as? String,
            "synthetic reason for unit test"
        )
        let desc = error?.userInfo[NSLocalizedDescriptionKey] as? String
        XCTAssertEqual(desc, "TestExceptionName: synthetic reason for unit test")

        let userInfo = error?.userInfo[MPKObjCExceptionUserInfoKey] as? [String: Any]
        XCTAssertEqual(userInfo?["key"] as? String, "value")
    }

    func testMPKTryBlockToleratesNilErrorOutParameter() {
        // The API contract allows `error == NULL`. The catcher must not crash
        // when the caller doesn't care about the error value.
        let ok = MPKTryBlock({
            NSException(name: .genericException, reason: "ignored", userInfo: nil).raise()
        }, nil)

        XCTAssertFalse(ok)
    }

    // MARK: - catchingObjCException (the Swift wrapper)

    func testCatchingObjCExceptionReturnsValueOnSuccess() throws {
        let value = try catchingObjCException { 42 }
        XCTAssertEqual(value, 42)
    }

    func testCatchingObjCExceptionRethrowsAsNSError() {
        do {
            try catchingObjCException {
                NSException(
                    name: NSExceptionName("AVFoundationErrorDomain"),
                    reason: "required condition is false: IsFormatSampleRateAndChannelCountValid(hwFormat)",
                    userInfo: nil
                ).raise()
            }
            XCTFail("expected catchingObjCException to throw")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, MPKObjCExceptionErrorDomain)
            XCTAssertEqual(
                error.userInfo[MPKObjCExceptionReasonKey] as? String,
                "required condition is false: IsFormatSampleRateAndChannelCountValid(hwFormat)"
            )
        }
    }

    func testCatchingObjCExceptionPreservesSwiftThrownErrors() {
        struct SampleError: Error, Equatable { let tag: String }

        do {
            _ = try catchingObjCException { () throws -> Int in
                throw SampleError(tag: "swift-path")
            }
            XCTFail("expected catchingObjCException to rethrow Swift error")
        } catch let error as SampleError {
            XCTAssertEqual(error.tag, "swift-path")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
