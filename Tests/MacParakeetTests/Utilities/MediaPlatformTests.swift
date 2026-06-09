import XCTest
@testable import MacParakeetCore

final class MediaPlatformTests: XCTestCase {

    // MARK: - recognize()

    func testRecognizesYouTube() {
        XCTAssertEqual(MediaPlatform.recognize("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), .youtube)
        XCTAssertEqual(MediaPlatform.recognize("https://youtu.be/dQw4w9WgXcQ"), .youtube)
        XCTAssertEqual(MediaPlatform.recognize("https://m.youtube.com/watch?v=dQw4w9WgXcQ"), .youtube)
        XCTAssertEqual(MediaPlatform.recognize("https://music.youtube.com/watch?v=dQw4w9WgXcQ"), .youtube)
        XCTAssertEqual(MediaPlatform.recognize("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"), .youtube)
    }

    func testRecognizesX() {
        XCTAssertEqual(MediaPlatform.recognize("https://x.com/jack/status/20"), .x)
        XCTAssertEqual(MediaPlatform.recognize("https://twitter.com/jack/status/20"), .x)
        XCTAssertEqual(MediaPlatform.recognize("https://mobile.twitter.com/jack/status/20"), .x)
        // Host-based recognition is intentionally looser than the old strict
        // /status/ gate — a profile URL still reads as "X" for display.
        XCTAssertEqual(MediaPlatform.recognize("https://x.com/jack"), .x)
    }

    func testRecognizesVimeo() {
        XCTAssertEqual(MediaPlatform.recognize("https://vimeo.com/76979871"), .vimeo)
        XCTAssertEqual(MediaPlatform.recognize("https://player.vimeo.com/video/76979871"), .vimeo)
        XCTAssertEqual(MediaPlatform.recognize("https://vimeopro.com/org/film/video/202852528"), .vimeo)
    }

    func testRecognizesFacebook() {
        XCTAssertEqual(MediaPlatform.recognize("https://www.facebook.com/watch/?v=10153231379946729"), .facebook)
        XCTAssertEqual(MediaPlatform.recognize("https://web.facebook.com/reel/1846951623322491"), .facebook)
        XCTAssertEqual(MediaPlatform.recognize("https://fb.watch/abc123/"), .facebook)
        XCTAssertEqual(MediaPlatform.recognize("https://fb.com/somepost"), .facebook)
    }

    func testRecognizesTikTok() {
        XCTAssertEqual(MediaPlatform.recognize("https://www.tiktok.com/@scout/video/6718335390845095173"), .tiktok)
        XCTAssertEqual(MediaPlatform.recognize("https://vm.tiktok.com/ZMhvJtRfp/"), .tiktok)
        XCTAssertEqual(MediaPlatform.recognize("https://vt.tiktok.com/ZSjp7d9k8/"), .tiktok)
    }

    func testRecognizesInstagram() {
        XCTAssertEqual(MediaPlatform.recognize("https://www.instagram.com/reel/Cs0bC4iLxkr/"), .instagram)
        XCTAssertEqual(MediaPlatform.recognize("https://instagram.com/p/Aabc_-1XyZ/"), .instagram)
        XCTAssertEqual(MediaPlatform.recognize("https://instagr.am/p/Aabc_-1XyZ/"), .instagram)
    }

    func testRecognizesApplePodcasts() {
        XCTAssertEqual(MediaPlatform.recognize("https://podcasts.apple.com/us/podcast/show/id1234567?i=1000654321"), .applePodcasts)
        XCTAssertEqual(MediaPlatform.recognize("https://podcast.apple.com/us/podcast/show/id1234567"), .applePodcasts)
    }

    func testRecognizesSoundCloudAndTwitch() {
        XCTAssertEqual(MediaPlatform.recognize("https://soundcloud.com/artist/track"), .soundcloud)
        XCTAssertEqual(MediaPlatform.recognize("https://www.twitch.tv/videos/123456789"), .twitch)
    }

    func testRecognizesSchemelessHosts() {
        XCTAssertEqual(MediaPlatform.recognize("youtube.com/watch?v=dQw4w9WgXcQ"), .youtube)
        XCTAssertEqual(MediaPlatform.recognize("vimeo.com/76979871"), .vimeo)
    }

    func testUnrecognizedReturnsNil() {
        XCTAssertNil(MediaPlatform.recognize("https://example.com/video/123"))
        XCTAssertNil(MediaPlatform.recognize("https://news.ycombinator.com"))
        XCTAssertNil(MediaPlatform.recognize("not a url"))
        XCTAssertNil(MediaPlatform.recognize(""))
    }

    func testRecognizeRejectsLookalikeHosts() {
        // A host that merely contains "youtube" but isn't a youtube domain.
        XCTAssertNil(MediaPlatform.recognize("https://notyoutube.com/watch?v=abc"))
        XCTAssertNil(MediaPlatform.recognize("https://youtube.com.evil.com/watch?v=abc"))
        XCTAssertNil(MediaPlatform.recognize("https://fakevimeo.com/123"))
    }

    // MARK: - isTranscribable() — the permissive gate

    func testTranscribableAcceptsRecognizedPlatforms() {
        let accepted = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://x.com/jack/status/20",
            "https://vimeo.com/76979871",
            "https://www.facebook.com/watch/?v=10153231379946729",
            "https://www.tiktok.com/@scout/video/6718335390845095173",
            "https://www.instagram.com/reel/Cs0bC4iLxkr/",
            "https://podcasts.apple.com/us/podcast/show/id1234567",
        ]
        for url in accepted {
            XCTAssertTrue(MediaPlatform.isTranscribable(url), "should accept \(url)")
        }
    }

    func testTranscribableAcceptsAnyHttpMediaURL() {
        // No allowlist: any plausible http(s) URL is accepted and handed to yt-dlp.
        XCTAssertTrue(MediaPlatform.isTranscribable("https://example.com/talk.mp4"))
        XCTAssertTrue(MediaPlatform.isTranscribable("http://archive.org/details/something"))
        XCTAssertTrue(MediaPlatform.isTranscribable("https://dailymotion.com/video/x8abcde"))
    }

    func testTranscribableAcceptsSchemelessRecognizedHost() {
        XCTAssertTrue(MediaPlatform.isTranscribable("youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertTrue(MediaPlatform.isTranscribable("vimeo.com/76979871"))
    }

    func testTranscribableRejectsNonURLText() {
        XCTAssertFalse(MediaPlatform.isTranscribable(""))
        XCTAssertFalse(MediaPlatform.isTranscribable("   "))
        XCTAssertFalse(MediaPlatform.isTranscribable("hello world"))
        XCTAssertFalse(MediaPlatform.isTranscribable("just some notes"))
        // Scheme-less unrecognized host should NOT enable the button (avoid
        // lighting up on arbitrary typed words like "todo.txt").
        XCTAssertFalse(MediaPlatform.isTranscribable("example.com/video"))
        XCTAssertFalse(MediaPlatform.isTranscribable("ftp://example.com/a.mp3"))
    }

    // MARK: - Metadata

    func testDisplayNames() {
        XCTAssertEqual(MediaPlatform.youtube.displayName, "YouTube")
        XCTAssertEqual(MediaPlatform.x.displayName, "X")
        XCTAssertEqual(MediaPlatform.vimeo.displayName, "Vimeo")
        XCTAssertEqual(MediaPlatform.facebook.displayName, "Facebook")
        XCTAssertEqual(MediaPlatform.tiktok.displayName, "TikTok")
        XCTAssertEqual(MediaPlatform.instagram.displayName, "Instagram")
        XCTAssertEqual(MediaPlatform.applePodcasts.displayName, "Apple Podcasts")
    }

    func testAudioFirstFlag() {
        XCTAssertTrue(MediaPlatform.applePodcasts.isAudioFirst)
        XCTAssertTrue(MediaPlatform.soundcloud.isAudioFirst)
        XCTAssertFalse(MediaPlatform.youtube.isAudioFirst)
        XCTAssertFalse(MediaPlatform.tiktok.isAudioFirst)
    }

    // MARK: - normalizedURLString()

    func testNormalizedURLStringAddsSchemeWhenMissing() {
        XCTAssertEqual(MediaPlatform.normalizedURLString("vimeo.com/76979871"), "https://vimeo.com/76979871")
        XCTAssertEqual(MediaPlatform.normalizedURLString("x.com/jack/status/20"), "https://x.com/jack/status/20")
        XCTAssertEqual(MediaPlatform.normalizedURLString("  tiktok.com/@a/video/1  "), "https://tiktok.com/@a/video/1")
    }

    func testNormalizedURLStringLeavesSchemedAndEmptyUntouched() {
        XCTAssertEqual(MediaPlatform.normalizedURLString("https://vimeo.com/1"), "https://vimeo.com/1")
        XCTAssertEqual(MediaPlatform.normalizedURLString("http://example.com/a.mp4"), "http://example.com/a.mp4")
        XCTAssertEqual(MediaPlatform.normalizedURLString(""), "")
        XCTAssertEqual(MediaPlatform.normalizedURLString("   "), "")
    }

    /// Regression guard: every URL the GUI gate accepts must, after normalization,
    /// also be accepted by the download-layer gate. The scheme-less recognized
    /// case used to pass the GUI gate but fail at the downloader (it requires an
    /// explicit scheme), starting a transcription that then errored.
    func testGateAcceptedURLsSurviveDownloaderGateAfterNormalization() {
        let inputs = [
            "vimeo.com/76979871",                       // scheme-less recognized
            "x.com/jack/status/20",
            "tiktok.com/@a/video/123",
            "instagram.com/reel/Cs0bC4iLxkr/",
            "https://vimeo.com/76979871",               // already schemed
            "https://example.com/talk.mp4",             // unrecognized but downloadable
        ]
        for input in inputs {
            XCTAssertTrue(MediaPlatform.isTranscribable(input), "GUI gate should accept \(input)")
            let normalized = MediaPlatform.normalizedURLString(input)
            // The downloader accepts a URL when it is a YouTube URL or a generic
            // http(s) media URL; normalization makes scheme-less hosts qualify.
            let downloaderAccepts = YouTubeURLValidator.isYouTubeURL(normalized)
                || DownloadableMediaURLValidator.isDownloadableMediaURL(normalized)
            XCTAssertTrue(downloaderAccepts, "downloader should accept normalized \(normalized)")
        }
    }
}
