import XCTest
@testable import MacParakeetCore

final class SystemMediaControllerTests: XCTestCase {
    func testPauseIfPlayingSendsPauseAndReturnsIdentityToken() async {
        let snapshots = SnapshotQueue([
            SystemMediaSnapshot(
                isPlaying: true,
                processIdentifier: 123,
                bundleIdentifier: "com.google.Chrome"
            )
        ])
        let commands = CommandRecorder()
        let controller = makeController(snapshots: snapshots, commands: commands)

        let token = await controller.pauseIfPlaying()

        XCTAssertEqual(token?.processIdentifier, 123)
        XCTAssertEqual(token?.bundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(commands.snapshot(), [1])
    }

    func testPauseIfPlayingSkipsWhenSnapshotUnavailable() async {
        let snapshots = SnapshotQueue([nil])
        let commands = CommandRecorder()
        let controller = makeController(snapshots: snapshots, commands: commands)

        let token = await controller.pauseIfPlaying()

        XCTAssertNil(token)
        XCTAssertEqual(commands.snapshot(), [])
    }

    func testPauseIfPlayingSkipsWhenAlreadyPaused() async {
        let snapshots = SnapshotQueue([
            SystemMediaSnapshot(
                isPlaying: false,
                processIdentifier: 123,
                bundleIdentifier: "com.apple.Music"
            )
        ])
        let commands = CommandRecorder()
        let controller = makeController(snapshots: snapshots, commands: commands)

        let token = await controller.pauseIfPlaying()

        XCTAssertNil(token)
        XCTAssertEqual(commands.snapshot(), [])
    }

    func testPauseIfPlayingRequiresSessionIdentity() async {
        let snapshots = SnapshotQueue([
            SystemMediaSnapshot(
                isPlaying: true,
                processIdentifier: nil,
                bundleIdentifier: nil
            )
        ])
        let commands = CommandRecorder()
        let controller = makeController(snapshots: snapshots, commands: commands)

        let token = await controller.pauseIfPlaying()

        XCTAssertNil(token)
        XCTAssertEqual(commands.snapshot(), [])
    }

    func testResumeSendsPlayWhenSameSessionIsStillPaused() async {
        let token = MediaPauseToken(
            processIdentifier: 123,
            bundleIdentifier: "com.google.Chrome"
        )
        let snapshots = SnapshotQueue([
            SystemMediaSnapshot(
                isPlaying: false,
                processIdentifier: 123,
                bundleIdentifier: "com.google.Chrome"
            )
        ])
        let commands = CommandRecorder()
        let controller = makeController(snapshots: snapshots, commands: commands)

        await controller.resume(token)

        XCTAssertEqual(commands.snapshot(), [0])
    }

    func testResumeSkipsWhenMediaIsAlreadyPlaying() async {
        let token = MediaPauseToken(
            processIdentifier: 123,
            bundleIdentifier: "com.google.Chrome"
        )
        let snapshots = SnapshotQueue([
            SystemMediaSnapshot(
                isPlaying: true,
                processIdentifier: 123,
                bundleIdentifier: "com.google.Chrome"
            )
        ])
        let commands = CommandRecorder()
        let controller = makeController(snapshots: snapshots, commands: commands)

        await controller.resume(token)

        XCTAssertEqual(commands.snapshot(), [])
    }

    func testResumeSkipsWhenNowPlayingSourceChanged() async {
        let token = MediaPauseToken(
            processIdentifier: 123,
            bundleIdentifier: "com.google.Chrome"
        )
        let snapshots = SnapshotQueue([
            SystemMediaSnapshot(
                isPlaying: false,
                processIdentifier: 456,
                bundleIdentifier: "com.apple.Music"
            )
        ])
        let commands = CommandRecorder()
        let controller = makeController(snapshots: snapshots, commands: commands)

        await controller.resume(token)

        XCTAssertEqual(commands.snapshot(), [])
    }

    func testResumeSkipsWhenSnapshotUnavailable() async {
        let token = MediaPauseToken(
            processIdentifier: 123,
            bundleIdentifier: "com.google.Chrome"
        )
        let snapshots = SnapshotQueue([nil])
        let commands = CommandRecorder()
        let controller = makeController(snapshots: snapshots, commands: commands)

        await controller.resume(token)

        XCTAssertEqual(commands.snapshot(), [])
    }

    func testHelperPayloadDecodesPlayingSnapshot() throws {
        let json = """
        {
          "available": true,
          "playing": true,
          "playbackRate": 1,
          "processIdentifier": 123,
          "bundleIdentifier": "com.google.Chrome"
        }
        """

        let snapshot = try XCTUnwrap(
            OsaScriptNowPlayingSnapshotReader.decode(Data(json.utf8))
        )

        XCTAssertEqual(
            snapshot,
            SystemMediaSnapshot(
                isPlaying: true,
                processIdentifier: 123,
                bundleIdentifier: "com.google.Chrome"
            )
        )
    }

    func testHelperPayloadFallsBackToPlaybackRateWhenPlayingIsMissing() throws {
        let json = """
        {
          "available": true,
          "playbackRate": 0,
          "processIdentifier": 456,
          "bundleIdentifier": "com.apple.Music"
        }
        """

        let snapshot = try XCTUnwrap(
            OsaScriptNowPlayingSnapshotReader.decode(Data(json.utf8))
        )

        XCTAssertEqual(
            snapshot,
            SystemMediaSnapshot(
                isPlaying: false,
                processIdentifier: 456,
                bundleIdentifier: "com.apple.Music"
            )
        )
    }

    func testHelperPayloadUnavailableReturnsNil() {
        let json = #"{"available": false}"#

        XCTAssertNil(OsaScriptNowPlayingSnapshotReader.decode(Data(json.utf8)))
    }

    private func makeController(
        snapshots: SnapshotQueue,
        commands: CommandRecorder
    ) -> SystemMediaController {
        SystemMediaController(
            snapshotProvider: {
                snapshots.next()
            },
            commandSender: { command in
                commands.record(command)
                return true
            }
        )
    }
}

private final class SnapshotQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [SystemMediaSnapshot?]

    init(_ snapshots: [SystemMediaSnapshot?]) {
        self.snapshots = snapshots.reversed()
    }

    func next() -> SystemMediaSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.popLast() ?? nil
    }
}

private final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [Int32] = []

    func record(_ command: Int32) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    func snapshot() -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }
}
