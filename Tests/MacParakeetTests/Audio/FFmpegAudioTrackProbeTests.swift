import XCTest
@testable import MacParakeetCore

final class FFmpegAudioTrackProbeTests: XCTestCase {
    func testTracksReportsAudioOrdinalsLanguageAndDefaultState() async throws {
        let stderr = """
            Input #0, matroska,webm, from '/tmp/episode.mkv':
              Stream #0:0: Video: h264
              Stream #0:1(jpn): Audio: aac, 48000 Hz, stereo, fltp (default)
              Stream #0:2(eng): Audio: aac, 48000 Hz, stereo, fltp
            At least one output file must be specified
            """
        let probe = FFmpegAudioTrackProbe(runProbe: { _ in
            .init(output: stderr, terminationStatus: 0)
        })

        let tracks = try await probe.tracks(in: URL(fileURLWithPath: "/tmp/episode.mkv"))

        XCTAssertEqual(
            tracks,
            [
                AudioTrackDescriptor(ordinal: 0, streamIndex: 1, languageCode: "jpn", isDefault: true),
                AudioTrackDescriptor(ordinal: 1, streamIndex: 2, languageCode: "eng", isDefault: false),
            ]
        )
        XCTAssertEqual(tracks[0].displayName, "Track 1 — Japanese (Default)")
        XCTAssertEqual(tracks[1].displayName, "Track 2 — English")
    }

    func testTracksUseNumberedFallbackWhenMetadataIsMissing() async throws {
        let stderr = """
              Stream #0:4: Audio: opus, 48000 Hz, stereo, fltp
              Stream #0:7: Audio: opus, 48000 Hz, stereo, fltp
              Stream #0:0: Video: vp9
              Stream #0:4 -> #0:0 (opus (native) -> pcm_s16le (native))
            """
        let probe = FFmpegAudioTrackProbe(runProbe: { _ in
            .init(output: stderr, terminationStatus: 0)
        })

        let tracks = try await probe.tracks(in: URL(fileURLWithPath: "/tmp/episode.webm"))

        XCTAssertEqual(tracks.map(\.ordinal), [0, 1])
        XCTAssertEqual(tracks.map(\.streamIndex), [4, 7])
        XCTAssertEqual(tracks.map(\.displayName), ["Track 1", "Track 2"])
    }

    func testTracksParsesMP4StreamIdentifiers() async throws {
        let stderr = """
              Stream #0:0[0x1](und): Video: h264
              Stream #0:1[0x2](eng): Audio: aac, 48000 Hz, stereo, fltp (default)
            Stream mapping:
              Stream #0:1 -> #0:0 (copy)
            Output #0, null, to 'pipe:':
              Stream #0:0(eng): Audio: aac, 48000 Hz, stereo, fltp (default)
            """
        let probe = FFmpegAudioTrackProbe(runProbe: { _ in
            .init(output: stderr, terminationStatus: 0)
        })

        let tracks = try await probe.tracks(in: URL(fileURLWithPath: "/tmp/episode.mp4"))

        XCTAssertEqual(
            tracks,
            [AudioTrackDescriptor(ordinal: 0, streamIndex: 1, languageCode: "eng", isDefault: true)]
        )
    }

    func testTracksReportsFFmpegFailureInsteadOfNoAudioTracks() async {
        let stderr = """
            [in#0 @ 0x123] Error opening input: Invalid data found when processing input
            Error opening input file /tmp/corrupt.mkv.
            Error opening input files: Invalid data found when processing input
            """
        let probe = FFmpegAudioTrackProbe(runProbe: { _ in
            .init(output: stderr, terminationStatus: 1)
        })

        do {
            _ = try await probe.tracks(in: URL(fileURLWithPath: "/tmp/corrupt.mkv"))
            XCTFail("Expected a probe failure")
        } catch let AudioProcessorError.conversionFailed(reason) {
            XCTAssertTrue(reason.contains("Invalid data found when processing input"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProbeCreatesMissingTemporaryRootAndParsesTracksFromProcessOutput() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("missing/parent/macparakeet", isDirectory: true)
        let ffmpeg = try makeFakeFFmpeg(
            in: sandbox,
            body: """
                printf 'title : \\377\\n' >&2
                echo '  Stream #0:1(eng): Audio: aac, 48000 Hz, stereo, fltp (default)' >&2
                """)
        let probe = FFmpegAudioTrackProbe(runProbe: { fileURL in
            try await FFmpegAudioTrackProbe.runFFmpegProbe(
                fileURL: fileURL, ffmpegPath: ffmpeg.path, temporaryRoot: root)
        })

        let tracks = try await probe.tracks(in: URL(fileURLWithPath: "/tmp/episode.mkv"))

        XCTAssertEqual(
            tracks,
            [AudioTrackDescriptor(ordinal: 0, streamIndex: 1, languageCode: "eng", isDefault: true)]
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testProbeFailsWithoutLaunchingWhenTemporaryRootCannotBeCreated() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let blocker = sandbox.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: blocker)
        let launched = sandbox.appendingPathComponent("launched")
        let ffmpeg = try makeFakeFFmpeg(in: sandbox, body: "touch '\(launched.path)'")

        do {
            _ = try await FFmpegAudioTrackProbe.runFFmpegProbe(
                fileURL: URL(fileURLWithPath: "/tmp/episode.mkv"),
                ffmpegPath: ffmpeg.path,
                temporaryRoot: blocker.appendingPathComponent("macparakeet", isDirectory: true))
            XCTFail("Expected the probe to fail when temporary storage is unavailable")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: launched.path))
        }
    }

    func testProbeRemovesLogWhenProcessCannotLaunch() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("macparakeet", isDirectory: true)

        do {
            _ = try await FFmpegAudioTrackProbe.runFFmpegProbe(
                fileURL: URL(fileURLWithPath: "/tmp/episode.mkv"),
                ffmpegPath: sandbox.appendingPathComponent("missing-ffmpeg").path,
                temporaryRoot: root)
            XCTFail("Expected the missing executable to fail")
        } catch {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testProbeReportsUnreadableOutputInsteadOfEmptyTracksAndRemovesLog() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("macparakeet", isDirectory: true)
        let replacedLog = sandbox.appendingPathComponent("replaced-log")
        let helperExitStatus = sandbox.appendingPathComponent("helper-exit-status")
        let ffmpeg = try makeFakeFFmpeg(
            in: sandbox,
            body: """
                set -eu
                trap 'helper_status=$?; printf "%s" "$helper_status" > "\(helperExitStatus.path)"' EXIT
                echo '  Stream #0:1(eng): Audio: aac' >&2
                for log in '\(root.path)'/macparakeet-audio-tracks-*.log; do
                  rm -f "$log"
                  mkdir "$log"
                  printf '%s' "$log" > '\(replacedLog.path)'
                done
                """)
        let probe = FFmpegAudioTrackProbe(runProbe: { fileURL in
            try await FFmpegAudioTrackProbe.runFFmpegProbe(
                fileURL: fileURL, ffmpegPath: ffmpeg.path, temporaryRoot: root)
        })

        do {
            let tracks = try await probe.tracks(in: URL(fileURLWithPath: "/tmp/episode.mkv"))
            XCTFail("Expected an output read failure, got \(tracks)")
        } catch {
            XCTAssertEqual(try String(contentsOf: helperExitStatus, encoding: .utf8), "0")
            let expectedLogPath = try String(contentsOf: replacedLog, encoding: .utf8)
            let readError = error as NSError
            XCTAssertEqual(readError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(readError.code, NSFileReadUnknownError)
            XCTAssertEqual(readError.userInfo[NSFilePathErrorKey] as? String, expectedLogPath)
            let underlying = try XCTUnwrap(readError.userInfo[NSUnderlyingErrorKey] as? NSError)
            XCTAssertEqual(underlying.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(underlying.code, Int(POSIXErrorCode.EISDIR.rawValue))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testCancelledProbeTerminatesProcessAndRemovesLog() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("macparakeet", isDirectory: true)
        let started = sandbox.appendingPathComponent("started")
        let ffmpeg = try makeFakeFFmpeg(
            in: sandbox,
            body: """
                touch '\(started.path)'
                exec sleep 30
                """)
        let task = Task {
            try await FFmpegAudioTrackProbe.runFFmpegProbe(
                fileURL: URL(fileURLWithPath: "/tmp/episode.mkv"),
                ffmpegPath: ffmpeg.path,
                temporaryRoot: root)
        }
        var attempts = 0
        while !FileManager.default.fileExists(atPath: started.path), attempts < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            attempts += 1
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path), "The probe process never started")

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeSandbox() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffmpeg-track-probe-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFakeFFmpeg(in directory: URL, body: String) throws -> URL {
        let url = directory.appendingPathComponent("ffmpeg")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
