import XCTest
@testable import MacParakeetCore

final class ShareBoundaryTests: XCTestCase {
    func testDebugSQLTraceSuppressesSharingStatements() {
        #if DEBUG
        XCTAssertNil(DatabaseManager.safeSQLTrace("INSERT INTO share_outbox_operations VALUES ('private')"))
        XCTAssertNil(DatabaseManager.safeSQLTrace("SELECT * FROM SHARE_PUBLICATIONS WHERE id = ?"))
        XCTAssertEqual(
            DatabaseManager.safeSQLTrace("SELECT * FROM transcriptions WHERE id = ?"),
            "SELECT * FROM transcriptions WHERE id = ?")
        #endif
    }

    func testSelectedDisplayedResultsPreserveTheirOrderAndExactContent() throws {
        let transcription = Transcription(fileName: "private.wav", status: .completed)
        let bundle = try ShareProjection.project(
            transcription: transcription,
            summaries: [
                .init(title: "Second visible tab", markdown: "**Only this output.**\n"),
                .init(title: "First visible tab", markdown: "Different selected output."),
            ], selection: .init(includeSummary: true, includeNotes: false, includeTranscript: false))
        XCTAssertEqual(
            bundle.sections,
            [
                .summary(title: "Second visible tab", markdown: "**Only this output.**\n"),
                .summary(title: "First visible tab", markdown: "Different selected output."),
            ])
    }

    func testContentDigestIgnoresPublishTimeButDetectsSelectedContentChanges() throws {
        let first = try ShareBundle(
            publishedAt: Date(timeIntervalSince1970: 100), sections: [.notes(title: "Notes", markdown: "Text")])
        let later = try ShareBundle(publishedAt: Date(timeIntervalSince1970: 200), sections: first.sections)
        let changed = try ShareBundle(
            publishedAt: later.publishedAt, sections: [.notes(title: "Notes", markdown: "Changed")])
        XCTAssertEqual(try first.contentDigest(), try later.contentDigest())
        XCTAssertNotEqual(try first.contentDigest(), try changed.contentDigest())
        XCTAssertEqual(try first.encodedJSON(), try first.encodedJSON())
    }

    func testSourceDateUsesLiteralWholeSecondUTCWireFormat() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let bundle = try ShareBundle(
            publishedAt: date, source: .init(kind: .meeting, displayDate: date),
            sections: [.notes(title: "Notes", markdown: "Text")])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bundle.encodedJSON()) as? [String: Any])
        let source = try XCTUnwrap(json["source"] as? [String: Any])
        XCTAssertEqual(source["displayDate"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(try ShareBundle.decodedFromJSON(bundle.encodedJSON()), bundle)
    }

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
        guard case .transcript(_, let segments) = bundle.sections[0] else {
            return XCTFail("Expected transcript section")
        }
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
