import XCTest
@testable import MacParakeetCore

final class PodcastEpisodeMatcherTests: XCTestCase {
    private func episodes() -> [PodcastFeedEpisode] {
        [
            PodcastFeedEpisode(title: "Episode 705: Train Your AI Team", audioURL: "https://x/ep705.mp3"),
            PodcastFeedEpisode(title: "Episode 704: Data Strategy", audioURL: "https://x/ep704.mp3"),
            PodcastFeedEpisode(title: "Bonus: Ask Me Anything", audioURL: "https://x/bonus.mp3"),
        ]
    }

    // MARK: - parseFreetextQuery

    func testFreetextWithEpisodeMarkerAndNumber() {
        let (show, hints) = PodcastEpisodeMatcher.parseFreetextQuery("Everyday AI episode 705 train your team")
        XCTAssertEqual(show, "Everyday AI")
        XCTAssertTrue(hints.contains("705"))
        XCTAssertTrue(hints.contains("train"))
    }

    func testFreetextWithBareNumber() {
        let (show, hints) = PodcastEpisodeMatcher.parseFreetextQuery("Lex Fridman 400")
        XCTAssertEqual(show, "Lex Fridman")
        XCTAssertEqual(hints, ["400"])
    }

    func testFreetextWithAttachedEpNumber() {
        let (_, hints) = PodcastEpisodeMatcher.parseFreetextQuery("ep705 Everyday")
        XCTAssertTrue(hints.contains("705"))
    }

    func testFreetextWithNoMarkerKeepsWholeQueryAsShow() {
        // Matches podcast-fetch: the first-3-words fallback only fires when the
        // show-name accumulator ends up empty (query starts with a marker/number).
        let (show, hints) = PodcastEpisodeMatcher.parseFreetextQuery("How I Built This Airbnb founder")
        XCTAssertEqual(show, "How I Built This Airbnb founder")
        XCTAssertTrue(hints.isEmpty)
    }

    func testFreetextLeadingNumberTriggersFallback() {
        let (show, hints) = PodcastEpisodeMatcher.parseFreetextQuery("705 train your team")
        XCTAssertEqual(show, "705 train your")
        XCTAssertEqual(hints, ["team"])
    }

    func testFreetextTrimsPunctuation() {
        let (show1, hints1) = PodcastEpisodeMatcher.parseFreetextQuery("Lex Fridman 400.")
        XCTAssertEqual(show1, "Lex Fridman")
        XCTAssertEqual(hints1, ["400"], "trailing period stripped from the number")

        let (_, hints2) = PodcastEpisodeMatcher.parseFreetextQuery("Everyday AI, episode #705!")
        XCTAssertTrue(hints2.contains("705"), "comma + #705! still yields a 705 hint")
    }

    // MARK: - find / select

    func testFindByTitleExactThenSubstring() {
        let eps = episodes()
        XCTAssertEqual(PodcastEpisodeMatcher.findByTitle(eps, query: "Episode 704: Data Strategy")?.audioURL, "https://x/ep704.mp3")
        XCTAssertEqual(PodcastEpisodeMatcher.findByTitle(eps, query: "train your ai")?.audioURL, "https://x/ep705.mp3")
        XCTAssertNil(PodcastEpisodeMatcher.findByTitle(eps, query: "nonexistent"))
    }

    func testFindByIndex() {
        let eps = episodes()
        XCTAssertEqual(PodcastEpisodeMatcher.findByIndex(eps, index: 0)?.audioURL, "https://x/ep705.mp3")
        XCTAssertEqual(PodcastEpisodeMatcher.findByIndex(eps, index: 1)?.audioURL, "https://x/ep704.mp3")
        XCTAssertNil(PodcastEpisodeMatcher.findByIndex(eps, index: 99))
        XCTAssertNil(PodcastEpisodeMatcher.findByIndex(eps, index: -1))
    }

    func testFindByHintsScoresEpisodeNumberStrongly() {
        let eps = episodes()
        XCTAssertEqual(PodcastEpisodeMatcher.findByHints(eps, hints: ["705"])?.audioURL, "https://x/ep705.mp3")
        XCTAssertEqual(PodcastEpisodeMatcher.findByHints(eps, hints: ["data"])?.audioURL, "https://x/ep704.mp3")
        XCTAssertNil(PodcastEpisodeMatcher.findByHints(eps, hints: ["zzz"]))
    }

    func testSelectEpisodeFallsBackToLatest() {
        let eps = episodes()
        XCTAssertEqual(PodcastEpisodeMatcher.selectEpisode(eps, hints: [])?.audioURL, "https://x/ep705.mp3")
        XCTAssertEqual(PodcastEpisodeMatcher.selectEpisode(eps, hints: ["704"])?.audioURL, "https://x/ep704.mp3")
        XCTAssertEqual(PodcastEpisodeMatcher.selectEpisode(eps, hints: ["zzz"])?.audioURL, "https://x/ep705.mp3", "unmatched hints → latest")
        XCTAssertNil(PodcastEpisodeMatcher.selectEpisode([], hints: []))
    }
}
