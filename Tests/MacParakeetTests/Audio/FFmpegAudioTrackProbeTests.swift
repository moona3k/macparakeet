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
        let probe = FFmpegAudioTrackProbe(runProbe: { _ in stderr })

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
        let probe = FFmpegAudioTrackProbe(runProbe: { _ in stderr })

        let tracks = try await probe.tracks(in: URL(fileURLWithPath: "/tmp/episode.webm"))

        XCTAssertEqual(tracks.map(\.ordinal), [0, 1])
        XCTAssertEqual(tracks.map(\.streamIndex), [4, 7])
        XCTAssertEqual(tracks.map(\.displayName), ["Track 1", "Track 2"])
    }

    func testTracksParsesMP4StreamIdentifiers() async throws {
        let stderr = """
              Stream #0:0[0x1](und): Video: h264
              Stream #0:1[0x2](eng): Audio: aac, 48000 Hz, stereo, fltp (default)
            """
        let probe = FFmpegAudioTrackProbe(runProbe: { _ in stderr })

        let tracks = try await probe.tracks(in: URL(fileURLWithPath: "/tmp/episode.mp4"))

        XCTAssertEqual(
            tracks,
            [AudioTrackDescriptor(ordinal: 0, streamIndex: 1, languageCode: "eng", isDefault: true)]
        )
    }
}
