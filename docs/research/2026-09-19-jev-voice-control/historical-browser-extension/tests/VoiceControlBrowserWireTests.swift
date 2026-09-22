import Darwin
import Foundation
import XCTest
@testable import MacParakeetCore

final class VoiceControlBrowserWireTests: XCTestCase {
    func testFramesRoundTripWithoutMergingMessages() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { Darwin.close(descriptors[0]); Darwin.close(descriptors[1]) }
        let first = Data("{\"type\":\"observe\"}".utf8)
        let second = Data("{\"type\":\"revoke\"}".utf8)
        try VoiceControlBrowserWire.writeFrame(first, to: descriptors[1])
        try VoiceControlBrowserWire.writeFrame(second, to: descriptors[1])
        XCTAssertEqual(try VoiceControlBrowserWire.readFrame(from: descriptors[0]), first)
        XCTAssertEqual(try VoiceControlBrowserWire.readFrame(from: descriptors[0]), second)
    }
    func testOversizedHeaderRejectedBeforeReadingBody() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { Darwin.close(descriptors[0]); Darwin.close(descriptors[1]) }
        var length = UInt32(VoiceControlBrowserWire.maximumFrameBytes + 1)
        withUnsafeBytes(of: &length) { _ = Darwin.write(descriptors[1], $0.baseAddress, $0.count) }
        XCTAssertThrowsError(try VoiceControlBrowserWire.readFrame(from: descriptors[0]))
    }
    func testEmptyAndOversizedOutputAreRejected() {
        XCTAssertThrowsError(try VoiceControlBrowserWire.writeFrame(Data(), to: -1))
        XCTAssertThrowsError(
            try VoiceControlBrowserWire.writeFrame(Data(count: VoiceControlBrowserWire.maximumFrameBytes + 1), to: -1))
    }
    func testPartialFrameEOFDoesNotProduceReceipt() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { Darwin.close(descriptors[0]) }
        var length: UInt32 = 10
        withUnsafeBytes(of: &length) { _ = Darwin.write(descriptors[1], $0.baseAddress, $0.count) }
        Darwin.close(descriptors[1])
        XCTAssertThrowsError(try VoiceControlBrowserWire.readFrame(from: descriptors[0]))
    }
    func testRecoversOwnedPrivateStaleSocket() throws {
        let path = "/tmp/mp-browser-\(UUID().uuidString.prefix(8)).sock"
        let stale = try VoiceControlBrowserWire.makeSocket()
        XCTAssertEqual(try VoiceControlBrowserWire.withAddress(path) { Darwin.bind(stale, $0, $1) }, 0)
        XCTAssertEqual(chmod(path, 0o600), 0)
        Darwin.close(stale)
        let replacement = try VoiceControlBrowserWire.makeSocket()
        defer { Darwin.close(replacement); Darwin.unlink(path) }
        XCTAssertNoThrow(try VoiceControlBrowserWire.bindRecoveringStaleSocket(replacement, path: path))
        XCTAssertEqual(Darwin.listen(replacement, 1), 0)
    }

    func testNeverUnlinksLiveSocketOrRegularFile() throws {
        let path = "/tmp/mp-browser-\(UUID().uuidString.prefix(8)).sock"
        let live = try VoiceControlBrowserWire.makeSocket()
        let second = try VoiceControlBrowserWire.makeSocket()
        defer { Darwin.close(live); Darwin.close(second); Darwin.unlink(path) }
        XCTAssertEqual(try VoiceControlBrowserWire.withAddress(path) { Darwin.bind(live, $0, $1) }, 0)
        XCTAssertEqual(chmod(path, 0o600), 0)
        XCTAssertEqual(Darwin.listen(live, 1), 0)
        XCTAssertThrowsError(try VoiceControlBrowserWire.bindRecoveringStaleSocket(second, path: path))
        var metadata = stat()
        XCTAssertEqual(lstat(path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & mode_t(S_IFMT), mode_t(S_IFSOCK))
        let file = path + ".txt"
        try Data("preserve".utf8).write(to: URL(fileURLWithPath: file))
        defer { Darwin.unlink(file) }
        XCTAssertThrowsError(try VoiceControlBrowserWire.bindRecoveringStaleSocket(second, path: file))
        XCTAssertEqual(try String(contentsOfFile: file), "preserve")
    }

    func testNeverUnlinksSymlinkOrNonprivateSocket() throws {
        let path = "/tmp/mp-browser-\(UUID().uuidString.prefix(8)).sock"
        let stale = try VoiceControlBrowserWire.makeSocket()
        let replacement = try VoiceControlBrowserWire.makeSocket()
        defer { Darwin.close(stale); Darwin.close(replacement); Darwin.unlink(path) }
        XCTAssertEqual(try VoiceControlBrowserWire.withAddress(path) { Darwin.bind(stale, $0, $1) }, 0)
        XCTAssertEqual(chmod(path, 0o644), 0)
        XCTAssertThrowsError(try VoiceControlBrowserWire.bindRecoveringStaleSocket(replacement, path: path))
        let link = path + ".link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        defer { Darwin.unlink(link) }
        XCTAssertThrowsError(try VoiceControlBrowserWire.bindRecoveringStaleSocket(replacement, path: link))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), path)
    }

}
