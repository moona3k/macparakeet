import AVFoundation
import Darwin
import XCTest
@testable import MacParakeetCore

final class VideoStreamServiceTests: XCTestCase {
    private let sourceURL = "https://www.youtube.com/watch?v=P-4nHu9y9gk"

    func testCombinedStreamUsesRemoteResourceAndCacheWithoutFFmpeg() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = ProcessStub(output: "https://example.invalid/combined.mp4\n")
        let service = makeService(root: root, stub: stub, ffmpegPath: { throw StubError.unexpectedFFmpeg })

        let first = try await service.playbackResource(for: sourceURL)
        let second = try await service.playbackResource(for: sourceURL)

        XCTAssertEqual(first.url, URL(string: "https://example.invalid/combined.mp4"))
        XCTAssertEqual(second.url, first.url)
        let calls = await stub.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].arguments.contains("--get-url"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])

        service.invalidateCache(for: sourceURL)
        _ = try await service.playbackResource(for: sourceURL)
        let refreshedCalls = await stub.calls
        XCTAssertEqual(refreshedCalls.count, 2)
    }

    func testSeparateStreamsCombineBothTracksAndRetainOnlyOwnedMedia() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let retainedAudio = root.appendingPathComponent("retained-audio.m4a")
        try Data("keep me".utf8).write(to: retainedAudio)
        let stub = ProcessStub()
        let service = makeService(root: root, stub: stub)
        let stages = StageRecorder()

        var resource: VideoPlaybackResource? = try await service.playbackResource(for: sourceURL) {
            await stages.append($0)
        }
        let url = try XCTUnwrap(resource).url
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(try Data(contentsOf: url), Data("combined video and audio".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["playback.mp4"])
        let observedStages = await stages.values
        XCTAssertEqual(observedStages, [.extracting, .downloading, .combining])
        let calls = await stub.calls
        XCTAssertEqual(calls.map(\.executable), ["yt-dlp-fixture", "yt-dlp-fixture", "ffmpeg-fixture"])
        let download = calls[1].arguments
        let selectorIndex = try XCTUnwrap(download.firstIndex(of: "-f"))
        XCTAssertTrue(download[selectorIndex + 1].contains(","), "Downloads must stay separate so yt-dlp cannot spawn an unowned mux process")
        XCTAssertFalse(download[selectorIndex + 1].contains("+"))
        let selectors = download[selectorIndex + 1].split(separator: ",")
        XCTAssertEqual(selectors.count, 2)
        XCTAssertTrue(selectors.allSatisfy { $0.contains("[filesize<=?512M]") },
                      "Known oversized formats must be excluded before choosing the best track")
        XCTAssertTrue(selectors[0].contains("[vcodec^=avc1][height<=1080][protocol=https]"))
        XCTAssertTrue(selectors[1].contains("[acodec^=mp4a][protocol=https]"))
        XCTAssertEqual(Array(download.suffix(2)), ["--", sourceURL])
        XCTAssertTrue(download.containsSequence(["--fixup", "never"]))
        XCTAssertTrue(download.containsSequence(["--max-filesize", "512M"]))
        XCTAssertTrue(calls[2].arguments.containsSequence(["-map", "0:v:0", "-map", "1:a:0", "-c", "copy"]))

        var anotherOwner = resource
        resource = nil
        XCTAssertEqual(anotherOwner?.url, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        anotherOwner = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: retainedAudio), Data("keep me".utf8))
    }

    func testSeparateStreamsAreNotPutInTheSharedURLCache() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = ProcessStub()
        let service = makeService(root: root, stub: stub)
        let first = try await service.playbackResource(for: sourceURL)
        let second = try await service.playbackResource(for: sourceURL)
        XCTAssertNotEqual(first.url, second.url)
        let calls = await stub.calls
        XCTAssertEqual(calls.filter { $0.arguments.contains("--get-url") }.count, 2)
        withExtendedLifetime((first, second)) {}
    }

    func testInvalidOrUnexpectedExtractionOutputIsRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for output in [
            "", "\n", "not a URL", "file:///tmp/not-a-stream.mp4", "https://",
            "https://example.invalid/one\nhttps://example.invalid/two\nhttps://example.invalid/three\n",
        ] {
            let stub = ProcessStub(output: output)
            let service = makeService(root: root, stub: stub)
            do {
                _ = try await service.playbackResource(for: sourceURL)
                XCTFail("Accepted invalid output: \(output)")
            } catch VideoStreamError.invalidStreamURL {
                // Expected: do not silently use the first line.
            }
            let calls = await stub.calls
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testDownloadAndMergeFailureRemovePartialFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for failure in [ProcessStub.Failure.download, .merge] {
            let stub = ProcessStub(failure: failure)
            let service = makeService(root: root, stub: stub)
            do {
                _ = try await service.playbackResource(for: sourceURL)
                XCTFail("Expected helper failure")
            } catch StubError.processFailed {
                // Preserve the helper failure, after removing its partial output.
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testMissingEmptyAndOversizedTracksCannotProduceSilentVideo() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for failure in [ProcessStub.Failure.missingAudio, .emptyAudio, .oversizedVideo, .emptyMerge] {
            let stub = ProcessStub(failure: failure)
            let service = makeService(root: root, stub: stub)
            do {
                _ = try await service.playbackResource(for: sourceURL)
                XCTFail("Expected incomplete output to fail")
            } catch VideoStreamError.preparationFailed {
                // yt-dlp can exit successfully after --max-filesize skips a track.
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testCancellationBetweenStagesRemovesOwnedFilesAndStartsNoSuccessor() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for stage in [VideoPreparationStage.downloading, .combining] {
            let stub = ProcessStub()
            let service = makeService(root: root, stub: stub)
            let source = sourceURL
            let task = Task {
                try await service.playbackResource(for: source) { current in
                    if current == stage {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // The current load was cancelled, including all of its temporary media.
            }
            let calls = await stub.calls
            XCTAssertEqual(calls.count, stage == .downloading ? 1 : 2)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testRunningHelperStopsBeforeCancellationOrTimeoutRemovesItsDirectory() async throws {
        for cancel in [true, false] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let ready = root.appendingPathComponent("ready")
            let pidFile = root.appendingPathComponent("pid")
            let exitState = root.appendingPathComponent("exit-state")
            let script = """
                trap 'if test -f "$1/source.mp4"; then printf present > "$2"; fi; exit 0' TERM
                printf '%s' "$$" > "$3"
                printf partial > "$1/source.mp4"
                printf '%s\\n' "$1" > "$4"
                deadline=$((SECONDS + 10))
                while ((SECONDS < deadline)); do :; done
                """
            let service = VideoStreamService(
                ytDlpPath: { "yt-dlp-fixture" }, ffmpegPath: { "ffmpeg-fixture" }, temporaryRoot: root
            ) { _, arguments, _, directory in
                if arguments.contains("--get-url") {
                    return "https://example.invalid/video.mp4\nhttps://example.invalid/audio.m4a\n"
                }
                return try await VideoStreamService.runProcess(
                    "/bin/bash",
                    arguments: ["-c", script, "video-helper", directory.path, exitState.path, pidFile.path, ready.path],
                    timeout: cancel ? 5 : 0.5,
                    directory: directory
                )
            }
            let source = sourceURL
            let task = Task { try await service.playbackResource(for: source) }
            defer { task.cancel() }
            let deadline = ContinuousClock.now + .seconds(3)
            var preparedDirectory: String?
            while ContinuousClock.now < deadline {
                if let value = try? String(contentsOf: ready, encoding: .utf8), value.hasSuffix("\n") {
                    preparedDirectory = value.trimmingCharacters(in: .newlines)
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let directory = preparedDirectory else {
                task.cancel()
                _ = try? await task.value
                XCTFail("Helper did not start before the readiness deadline")
                continue
            }
            let pid = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8)))
            if cancel { task.cancel() }

            do {
                _ = try await task.value
                XCTFail("Expected running helper to be interrupted")
            } catch is CancellationError {
                XCTAssertTrue(cancel)
            } catch VideoStreamError.preparationFailed(let reason) {
                XCTAssertFalse(cancel)
                XCTAssertTrue(reason.contains("timed out"))
            }

            let processStatus = kill(pid, 0)
            let processError = errno
            XCTAssertEqual(processStatus, -1, "The helper must exit before preparation returns")
            XCTAssertEqual(processError, ESRCH)
            XCTAssertEqual(try String(contentsOf: exitState, encoding: .utf8), "present",
                           "The helper must still own its partial file when it handles termination")
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
        }
    }

    func testMissingFFmpegDoesNotStartFallbackDownload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = ProcessStub()
        let service = makeService(root: root, stub: stub, ffmpegPath: { throw StubError.unexpectedFFmpeg })
        do {
            _ = try await service.playbackResource(for: sourceURL)
            XCTFail("Expected missing FFmpeg to fail before downloading")
        } catch StubError.unexpectedFFmpeg {
        }
        let calls = await stub.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testRealFFmpegFallbackProducesPlayableVideoAndAudioTracks() async throws {
        guard let ffmpeg = BinaryBootstrap.findSystemFFmpeg() else {
            throw XCTSkip("System FFmpeg is unavailable; GitHub CI installs it")
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("fixture-video.mp4")
        let audio = root.appendingPathComponent("fixture-audio.m4a")
        _ = try await VideoStreamService.runProcess(ffmpeg, arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
            "-i", "color=c=black:s=160x90:r=10", "-t", "1", "-an", "-c:v", "libx264",
            "-pix_fmt", "yuv420p", "-y", video.path,
        ], timeout: 30, directory: root)
        _ = try await VideoStreamService.runProcess(ffmpeg, arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
            "-i", "sine=frequency=1000:sample_rate=44100", "-t", "1", "-vn", "-c:a", "aac", "-y", audio.path,
        ], timeout: 30, directory: root)

        let service = VideoStreamService(
            ytDlpPath: { "yt-dlp-fixture" }, ffmpegPath: { ffmpeg }, temporaryRoot: root
        ) { executable, arguments, timeout, directory in
            if executable == "yt-dlp-fixture" {
                if arguments.contains("--get-url") {
                    return "https://example.invalid/video.mp4\nhttps://example.invalid/audio.m4a\n"
                }
                try FileManager.default.copyItem(at: video, to: directory.appendingPathComponent("source.mp4"))
                try FileManager.default.copyItem(at: audio, to: directory.appendingPathComponent("source.m4a"))
                return ""
            }
            return try await VideoStreamService.runProcess(executable, arguments: arguments, timeout: min(timeout, 30), directory: directory)
        }
        let resource = try await service.playbackResource(for: sourceURL)
        let asset = AVURLAsset(url: resource.url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let isPlayable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertTrue(isPlayable)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.15)
        withExtendedLifetime(resource) {}
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoStreamServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeService(
        root: URL,
        stub: ProcessStub,
        ffmpegPath: @escaping @Sendable () throws -> String = { "ffmpeg-fixture" }
    ) -> VideoStreamService {
        VideoStreamService(ytDlpPath: { "yt-dlp-fixture" }, ffmpegPath: ffmpegPath, temporaryRoot: root) {
            try await stub.run(executable: $0, arguments: $1, directory: $3)
        }
    }
}

private enum StubError: Error {
    case unexpectedFFmpeg
    case processFailed
}

private actor StageRecorder {
    var values: [VideoPreparationStage] = []
    func append(_ value: VideoPreparationStage) { values.append(value) }
}

private actor ProcessStub {
    enum Failure: Sendable {
        case download, merge, missingAudio, emptyAudio, oversizedVideo, emptyMerge
    }

    struct Call: Sendable {
        let executable: String
        let arguments: [String]
    }

    let output: String
    let failure: Failure?
    var calls: [Call] = []

    init(
        output: String = "https://example.invalid/video.mp4\nhttps://example.invalid/audio.m4a\n",
        failure: Failure? = nil
    ) {
        self.output = output
        self.failure = failure
    }

    func run(executable: String, arguments: [String], directory: URL) throws -> String {
        calls.append(Call(executable: executable, arguments: arguments))
        if arguments.contains("--get-url") { return output }
        if executable == "yt-dlp-fixture" {
            let video = directory.appendingPathComponent("source.mp4")
            try Data("video".utf8).write(to: video)
            if failure == .oversizedVideo {
                let handle = try FileHandle(forWritingTo: video)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 512 * 1024 * 1024 + 1)
            }
            if failure == .download { throw StubError.processFailed }
            if failure != .missingAudio {
                try (failure == .emptyAudio ? Data() : Data("audio".utf8))
                    .write(to: directory.appendingPathComponent("source.m4a"))
            }
        } else {
            let video = try Data(contentsOf: directory.appendingPathComponent("source.mp4"))
            let audio = try Data(contentsOf: directory.appendingPathComponent("source.m4a"))
            guard video == Data("video".utf8), audio == Data("audio".utf8) else {
                throw StubError.processFailed
            }
            try (failure == .emptyMerge ? Data() : Data("combined video and audio".utf8))
                .write(to: directory.appendingPathComponent("playback.mp4"))
            if failure == .merge { throw StubError.processFailed }
        }
        return ""
    }
}

private extension Array where Element == String {
    func containsSequence(_ values: [String]) -> Bool {
        guard values.count <= count else { return false }
        return (0...(count - values.count)).contains { start in
            Array(self[start..<(start + values.count)]) == values
        }
    }
}
