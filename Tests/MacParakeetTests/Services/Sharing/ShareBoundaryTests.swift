import XCTest
@testable import MacParakeetCore

final class ShareBoundaryTests: XCTestCase {
    func testLinkRejectsNoncanonicalOriginAndPath() throws {
        let link = ShareLink.generate()
        let path = "/s/\(link.locator.rawValue)"
        let fragment = "#v1.\(link.contentKey.rawValue)"
        for address in [
            "https://user@share.macparakeet.com\(path)\(fragment)",
            "https://share.macparakeet.com:444\(path)\(fragment)",
            "https://share.macparakeet.com\(path)?tracking=1\(fragment)",
            "https://share.macparakeet.com/\(path)\(fragment)",
            "https://share.macparakeet.com\(path)/\(fragment)",
            "https://share.macparakeet.com/%73/\(link.locator.rawValue)\(fragment)",
        ] {
            XCTAssertThrowsError(try ShareLink(url: XCTUnwrap(URL(string: address))))
        }
    }

    func testDeselectedMetadataIsNotProjected() throws {
        let source = Transcription(fileName: "private.wav", rawTranscript: "Selected text.", status: .completed)
        let selection = ShareSelection(
            includeSummary: false, includeNotes: false, includeTranscript: true,
            transcriptOptions: .init(includeTimestamps: false, includeSpeakerLabels: false, includeMetadata: false)
        )
        let bundle = try ShareProjection.project(transcription: source, selection: selection)
        XCTAssertNil(bundle.source)
    }

    func testUnresolvedSpeakerIdentifierNeverBecomesDisplayLabel() throws {
        let source = Transcription(
            fileName: "private.wav",
            wordTimestamps: [
                WordTimestamp(word: "Hello", startMs: 0, endMs: 100, confidence: 1, speakerId: "internal-id")
            ],
            speakers: [SpeakerInfo(id: "different-id", label: "Jordan")], status: .completed
        )
        let selection = ShareSelection(includeSummary: false, includeNotes: false, includeTranscript: true)
        let bundle = try ShareProjection.project(transcription: source, selection: selection)
        guard case .transcript(_, let segments) = bundle.sections[0] else { return XCTFail() }
        XCTAssertNil(segments[0].speaker)
    }

    func testBundleRejectsInvalidDisplayMetadataAndWhitespaceSegments() throws {
        XCTAssertThrowsError(try ShareBundle.TranscriptSegment(text: " \n "))
        XCTAssertThrowsError(
            try ShareBundle(
                publishedAt: Date(), source: .init(kind: .meeting, durationMs: -1),
                sections: [.notes(title: "Notes", markdown: "Text")]
            ))
        XCTAssertThrowsError(
            try ShareBundle(
                publishedAt: Date(timeIntervalSince1970: .infinity),
                sections: [.notes(title: "Notes", markdown: "Text")]
            ))
    }
}
