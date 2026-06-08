import XCTest
@testable import MacParakeetCore

final class PodcastFeedParserTests: XCTestCase {

    func testIsAudioURL() {
        XCTAssertTrue(PodcastFeedParser.isAudioURL("https://cdn.example.com/shows/ep.MP3?token=abc"))
        XCTAssertTrue(PodcastFeedParser.isAudioURL("https://example.com/ep.m4a"))
        XCTAssertTrue(PodcastFeedParser.isAudioURL("https://cdn.example.com/audio/123"))
        XCTAssertFalse(PodcastFeedParser.isAudioURL("https://example.com/page.html"))
        XCTAssertFalse(PodcastFeedParser.isAudioURL("https://example.com/image.jpg"))
    }

    func testParseDuration() {
        XCTAssertEqual(PodcastFeedParser.parseDuration("01:02:03"), 3723)
        XCTAssertEqual(PodcastFeedParser.parseDuration("45:00"), 2700)
        XCTAssertEqual(PodcastFeedParser.parseDuration("1830"), 1830)
        XCTAssertNil(PodcastFeedParser.parseDuration("garbage"))
        XCTAssertNil(PodcastFeedParser.parseDuration(""))
        XCTAssertNil(PodcastFeedParser.parseDuration(nil))
    }

    func testParseFeedExtractsAudioItemsOnly() throws {
        let rss = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" version="2.0">
        <channel>
          <title>Test Show</title>
          <item>
            <title>Episode 705: Train Your AI Team</title>
            <description><![CDATA[<p>How to train your team</p>]]></description>
            <enclosure url="https://cdn.example.com/ep705.mp3" length="44100000" type="audio/mpeg"/>
            <itunes:duration>00:45:10</itunes:duration>
            <pubDate>Mon, 01 Jul 2024 07:00:00 GMT</pubDate>
          </item>
          <item>
            <title>Episode 704: Data Strategy</title>
            <itunes:summary>All about data</itunes:summary>
            <enclosure url="https://cdn.example.com/ep704.m4a" type="audio/x-m4a"/>
          </item>
          <item>
            <title>No Audio Item</title>
            <enclosure url="https://example.com/notes.pdf" type="application/pdf"/>
          </item>
        </channel>
        </rss>
        """
        let episodes = try PodcastFeedParser.parse(Data(rss.utf8))

        XCTAssertEqual(episodes.count, 2, "PDF enclosure must be excluded")
        XCTAssertEqual(episodes[0].title, "Episode 705: Train Your AI Team")
        XCTAssertEqual(episodes[0].audioURL, "https://cdn.example.com/ep705.mp3")
        XCTAssertEqual(episodes[0].durationSeconds, 2710)
        XCTAssertEqual(episodes[0].published, "Mon, 01 Jul 2024 07:00:00 GMT")
        XCTAssertTrue(episodes[0].description?.contains("train your team") == true, "CDATA description captured")
        XCTAssertEqual(episodes[1].audioURL, "https://cdn.example.com/ep704.m4a")
        XCTAssertEqual(episodes[1].description, "All about data", "itunes:summary fallback")
    }

    func testParseFeedAcceptsEnclosureByAudioExtensionWithoutMimeType() throws {
        let rss = """
        <rss><channel>
          <item><title>Ep</title><enclosure url="https://cdn/x/ep.mp3"/></item>
        </channel></rss>
        """
        let episodes = try PodcastFeedParser.parse(Data(rss.utf8))
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].audioURL, "https://cdn/x/ep.mp3")
    }

    func testParseMalformedXMLThrows() {
        XCTAssertThrowsError(try PodcastFeedParser.parse(Data("<rss><channel>".utf8)))
    }
}
