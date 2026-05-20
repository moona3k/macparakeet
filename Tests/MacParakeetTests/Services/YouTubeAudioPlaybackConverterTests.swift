import XCTest
@testable import MacParakeetCore

final class YouTubeAudioPlaybackConverterTests: XCTestCase {

    // MARK: - needsConversion

    func testNeedsConversionFlagsWebM() {
        XCTAssertTrue(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.webm"))
    }

    func testNeedsConversionFlagsOpus() {
        XCTAssertTrue(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.opus"))
    }

    func testNeedsConversionFlagsOgg() {
        XCTAssertTrue(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.ogg"))
    }

    func testNeedsConversionFlagsMkv() {
        XCTAssertTrue(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.mkv"))
    }

    func testNeedsConversionFlagsWeba() {
        // yt-dlp emits `.weba` for audio-only WebM/Opus streams.
        XCTAssertTrue(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.weba"))
    }

    func testNeedsConversionIsCaseInsensitive() {
        XCTAssertTrue(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/A.WEBM"))
    }

    func testNeedsConversionIgnoresM4A() {
        XCTAssertFalse(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.m4a"))
    }

    func testNeedsConversionIgnoresMP3() {
        XCTAssertFalse(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.mp3"))
    }

    func testNeedsConversionIgnoresWAV() {
        XCTAssertFalse(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.wav"))
    }

    func testNeedsConversionIgnoresMP4() {
        // mp4 video container — AVFoundation reads its audio track natively.
        XCTAssertFalse(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.mp4"))
    }

    func testNeedsConversionIgnoresExtensionlessFiles() {
        XCTAssertFalse(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/audio"))
    }

    // MARK: - ffmpegArguments

    func testFFmpegArgumentsTranscodeToAACM4A() {
        let args = YouTubeAudioPlaybackConverter.ffmpegArguments(
            inputPath: "/tmp/source.webm",
            outputPath: "/tmp/source.m4a"
        )

        XCTAssertEqual(args, [
            "-nostdin",
            "-i", "/tmp/source.webm",
            "-vn",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            "-y",
            "/tmp/source.m4a",
        ])
    }

    func testFFmpegArgumentsEmbedMetadataTags() {
        let args = YouTubeAudioPlaybackConverter.ffmpegArguments(
            inputPath: "/tmp/source.webm",
            outputPath: "/tmp/source.m4a",
            metadata: YouTubeAudioArtifactMetadata(
                title: "Video Title",
                artist: "Channel Name",
                description: "Video description"
            )
        )

        XCTAssertTrue(args.containsInOrder(["-metadata", "title=Video Title"]))
        XCTAssertTrue(args.containsInOrder(["-metadata", "artist=Channel Name"]))
        XCTAssertTrue(args.containsInOrder(["-metadata", "album_artist=Channel Name"]))
        XCTAssertTrue(args.containsInOrder(["-metadata", "description=Video description"]))
        XCTAssertTrue(args.containsInOrder(["-metadata", "comment=Video description"]))
    }

    func testFFmpegArgumentsAttachThumbnailWhenProvided() {
        let args = YouTubeAudioPlaybackConverter.ffmpegArguments(
            inputPath: "/tmp/source.webm",
            outputPath: "/tmp/source.m4a",
            thumbnailPath: "/tmp/thumb.jpg"
        )

        XCTAssertEqual(args, [
            "-nostdin",
            "-i", "/tmp/source.webm",
            "-i", "/tmp/thumb.jpg",
            "-map", "0:a:0",
            "-map", "1:v:0",
            "-c:a", "aac",
            "-b:a", "192k",
            "-c:v", "mjpeg",
            "-disposition:v", "attached_pic",
            "-movflags", "+faststart",
            "-y",
            "/tmp/source.m4a",
        ])
    }

    func testTemporaryOutputURLKeepsM4AExtensionForFFmpegFormatDetection() {
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let outputURL = URL(fileURLWithPath: "/tmp/source.m4a")

        let tempURL = YouTubeAudioPlaybackConverter.temporaryOutputURL(
            for: outputURL,
            uuid: uuid
        )

        XCTAssertEqual(tempURL.lastPathComponent, "source.tmp-\(uuid.uuidString).m4a")
        XCTAssertEqual(tempURL.pathExtension, "m4a")
    }

    // MARK: - convertToPlayableM4AIfNeeded passthrough

    func testConvertReturnsInputPathUnchangedForAlreadyPlayableFile() async throws {
        let converter = YouTubeAudioPlaybackConverter()
        // Use a path that doesn't need conversion. We don't even need the
        // file to exist — the function should short-circuit on extension.
        let path = "/tmp/anything.m4a"
        let result = try await converter.convertToPlayableM4AIfNeeded(inputPath: path)
        XCTAssertEqual(result, path)
    }

    func testConvertThrowsSourceMissingWhenFileDoesNotExist() async {
        let converter = YouTubeAudioPlaybackConverter()
        let bogus = "/tmp/macparakeet-nonexistent-\(UUID().uuidString).webm"

        do {
            _ = try await converter.convertToPlayableM4AIfNeeded(inputPath: bogus)
            XCTFail("Expected sourceMissing error")
        } catch let YouTubeAudioPlaybackConverterError.sourceMissing(path) {
            XCTAssertEqual(path, bogus)
        } catch {
            XCTFail("Expected sourceMissing, got \(error)")
        }
    }

    func testConvertReturnsExistingM4AWhenSourceAlreadyMigrated() async throws {
        // Race-window scenario: a prior conversion (post-STT path) already
        // produced the m4a and deleted the source webm. A subsequent call
        // (lazy migration triggered before the DB had the new path) should
        // not crash and should return the m4a path without re-invoking
        // ffmpeg or throwing `sourceMissing`.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-converter-migrated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let webmPath = dir.appendingPathComponent("video.webm").path
        let m4aURL = dir.appendingPathComponent("video.m4a")
        try Data([0x00]).write(to: m4aURL)

        let converter = YouTubeAudioPlaybackConverter()
        let result = try await converter.convertToPlayableM4AIfNeeded(inputPath: webmPath)
        XCTAssertEqual(result, m4aURL.path)
    }
}

private extension Array where Element == String {
    func containsInOrder(_ values: [String]) -> Bool {
        guard !values.isEmpty else { return true }
        for index in indices {
            guard self[index] == values[0] else { continue }
            var candidateIndex = index
            var matched = true
            for value in values.dropFirst() {
                candidateIndex = self.index(after: candidateIndex)
                guard indices.contains(candidateIndex), self[candidateIndex] == value else {
                    matched = false
                    break
                }
            }
            if matched {
                return true
            }
        }
        return false
    }
}
