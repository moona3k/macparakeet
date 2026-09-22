import XCTest
@testable import MacParakeetCore

final class ShareBundleV1Tests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_789_084_800)  // 2026-09-11T00:00:00Z

    private func makeNotesSection(_ markdown: String = "Owner-authored notes.") -> ShareBundle.Section {
        .notes(title: "Notes", markdown: markdown)
    }

    // MARK: - Required fields

    func testAtLeastOneSectionIsRequired() {
        XCTAssertThrowsError(try ShareBundle(publishedAt: fixedDate, sections: [])) { error in
            XCTAssertEqual(error as? ShareBundleError, .noSections)
        }
    }

    func testEmptySectionContentIsRejected() {
        XCTAssertThrowsError(
            try ShareBundle(publishedAt: fixedDate, sections: [.notes(title: "Notes", markdown: "   ")])
        ) { error in
            XCTAssertEqual(error as? ShareBundleError, .emptySectionContent)
        }
    }

    func testValidBundleRoundTripsThroughJSON() throws {
        let segment = try ShareBundle.TranscriptSegment(
            text: "Selected transcript text.", startMs: 12_300, endMs: 15_800, speaker: "Jordan"
        )
        let bundle = try ShareBundle(
            publishedAt: fixedDate,
            title: "Weekly sync",
            source: ShareBundle.Source(kind: .meeting, displayDate: fixedDate, durationMs: 3_600_000),
            sections: [
                .summary(title: "Summary", markdown: "## Decisions\n\nSelected display-ready text."),
                makeNotesSection(),
                .transcript(title: "Transcript", segments: [segment]),
            ]
        )

        let data = try bundle.encodedJSON()
        let decoded = try ShareBundle.decodedFromJSON(data)
        XCTAssertEqual(decoded, bundle)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schema"] as? String, "com.macparakeet.share-bundle")
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["publishedAt"] as? String, "2026-09-11T00:00:00Z")
    }

    // MARK: - Section repetition

    func testSummarySectionsMayRepeatButNotesMayNot() {
        XCTAssertThrowsError(
            try ShareBundle(
                publishedAt: fixedDate,
                sections: [makeNotesSection("First"), makeNotesSection("Second")]
            )
        ) { error in
            XCTAssertEqual(error as? ShareBundleError, .multipleNotesSections)
        }

        XCTAssertNoThrow(
            try ShareBundle(
                publishedAt: fixedDate,
                sections: [
                    .summary(title: "Summary", markdown: "A"),
                    .summary(title: "Decisions", markdown: "B"),
                ]
            )
        )
    }

    func testTranscriptSectionMayNotRepeat() throws {
        let segment = try ShareBundle.TranscriptSegment(text: "One.")
        XCTAssertThrowsError(
            try ShareBundle(
                publishedAt: fixedDate,
                sections: [
                    .transcript(title: "Transcript", segments: [segment]),
                    .transcript(title: "Transcript", segments: [segment]),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? ShareBundleError, .multipleTranscriptSections)
        }
    }

    // MARK: - Transcript timing pairs

    func testTranscriptSegmentRequiresBothOrNeitherTimingBound() {
        XCTAssertThrowsError(try ShareBundle.TranscriptSegment(text: "Hi", startMs: 100, endMs: nil)) { error in
            XCTAssertEqual(error as? ShareBundleError, .invalidTranscriptSegmentTiming)
        }
        XCTAssertThrowsError(try ShareBundle.TranscriptSegment(text: "Hi", startMs: nil, endMs: 100)) { error in
            XCTAssertEqual(error as? ShareBundleError, .invalidTranscriptSegmentTiming)
        }
        XCTAssertThrowsError(try ShareBundle.TranscriptSegment(text: "Hi", startMs: 500, endMs: 100)) { error in
            XCTAssertEqual(error as? ShareBundleError, .invalidTranscriptSegmentTiming)
        }
        XCTAssertThrowsError(try ShareBundle.TranscriptSegment(text: "Hi", startMs: -1, endMs: 100)) { error in
            XCTAssertEqual(error as? ShareBundleError, .invalidTranscriptSegmentTiming)
        }
        XCTAssertNoThrow(try ShareBundle.TranscriptSegment(text: "Hi", startMs: 100, endMs: 100))
        XCTAssertNoThrow(try ShareBundle.TranscriptSegment(text: "Hi"))
    }

    func testTranscriptSegmentRequiresNonEmptyText() {
        XCTAssertThrowsError(try ShareBundle.TranscriptSegment(text: "")) { error in
            XCTAssertEqual(error as? ShareBundleError, .emptySectionContent)
        }
    }

    // MARK: - Speaker omission

    func testSpeakerFieldIsOmittedWhenNotProvided() throws {
        let segment = try ShareBundle.TranscriptSegment(text: "No speaker here.")
        let bundle = try ShareBundle(
            publishedAt: fixedDate, sections: [.transcript(title: "Transcript", segments: [segment])]
        )
        let json = try JSONSerialization.jsonObject(with: try bundle.encodedJSON()) as! [String: Any]
        let sections = json["sections"] as! [[String: Any]]
        let segmentJSON = (sections[0]["segments"] as! [[String: Any]])[0]
        XCTAssertNil(segmentJSON["speaker"])
        XCTAssertNil(segmentJSON["startMs"])
        XCTAssertNil(segmentJSON["endMs"])
    }

    // MARK: - Markdown passes through opaquely (viewer, not Swift, sanitizes)

    func testMarkdownContentIsPreservedByteForByteThroughEncoding() throws {
        let hostileMarkdown = "<script>alert(1)</script>\n\n**bold** _em_ [link](javascript:alert(1))"
        let bundle = try ShareBundle(publishedAt: fixedDate, sections: [makeNotesSection(hostileMarkdown)])
        let decoded = try ShareBundle.decodedFromJSON(try bundle.encodedJSON())
        guard case .notes(_, let markdown) = decoded.sections[0] else {
            return XCTFail("Expected a notes section")
        }
        XCTAssertEqual(markdown, hostileMarkdown)
    }

    // MARK: - Unknown kinds and schema fail before use

    func testUnknownSectionKindFailsToDecode() throws {
        let json = """
            {"schema":"com.macparakeet.share-bundle","schemaVersion":1,"publishedAt":"2026-09-11T22:00:00Z",
            "sections":[{"kind":"attachment","title":"X","markdown":"y"}]}
            """
        XCTAssertThrowsError(try ShareBundle.decodedFromJSON(Data(json.utf8))) { error in
            XCTAssertEqual(error as? ShareBundleError, .unknownSectionKind("attachment"))
        }
    }

    func testUnknownSchemaFailsToDecode() throws {
        let json = """
            {"schema":"com.macparakeet.something-else","schemaVersion":1,"publishedAt":"2026-09-11T22:00:00Z",
            "sections":[{"kind":"notes","title":"Notes","markdown":"y"}]}
            """
        XCTAssertThrowsError(try ShareBundle.decodedFromJSON(Data(json.utf8))) { error in
            XCTAssertEqual(error as? ShareBundleError, .unknownSchema("com.macparakeet.something-else"))
        }
    }

    func testUnknownSchemaVersionFailsToDecode() throws {
        let json = """
            {"schema":"com.macparakeet.share-bundle","schemaVersion":2,"publishedAt":"2026-09-11T22:00:00Z",
            "sections":[{"kind":"notes","title":"Notes","markdown":"y"}]}
            """
        XCTAssertThrowsError(try ShareBundle.decodedFromJSON(Data(json.utf8))) { error in
            XCTAssertEqual(error as? ShareBundleError, .unknownSchemaVersion(2))
        }
    }

    func testUnknownAdditiveFieldsAreIgnored() throws {
        let json = """
            {"schema":"com.macparakeet.share-bundle","schemaVersion":1,"publishedAt":"2026-09-11T22:00:00Z",
            "sections":[{"kind":"notes","title":"Notes","markdown":"y","futureField":"ignored"}],
            "futureTopLevelField":"ignored"}
            """
        let decoded = try ShareBundle.decodedFromJSON(Data(json.utf8))
        XCTAssertEqual(decoded.sections.count, 1)
    }

    // MARK: - Size limits

    func testOversizedPlaintextFailsBeforeAnyIO() throws {
        let oversized = String(repeating: "a", count: ShareBundle.maxPlaintextBytes)
        let bundle = try ShareBundle(publishedAt: fixedDate, sections: [makeNotesSection(oversized)])
        XCTAssertThrowsError(try bundle.encodedJSON()) { error in
            guard case .payloadTooLarge = error as? ShareBundleError else {
                return XCTFail("Expected payloadTooLarge, got \(error)")
            }
        }
    }

    // MARK: - publishedAt reflects the current content revision

    func testPublishedAtIsWholeSecondUTCAndRefreshesOnEachExplicitUpdate() throws {
        let firstPublish = Date(timeIntervalSince1970: 1_789_084_800.75)
        let bundle = try ShareBundle(publishedAt: firstPublish, sections: [makeNotesSection()])
        // Sub-second precision is truncated to the whole second the contract requires.
        XCTAssertEqual(bundle.publishedAt.timeIntervalSince1970, 1_789_084_800)

        let secondPublish = firstPublish.addingTimeInterval(3_600)
        let updated = try ShareBundle(publishedAt: secondPublish, sections: [makeNotesSection("Updated.")])
        XCTAssertNotEqual(updated.publishedAt, bundle.publishedAt)
        XCTAssertEqual(updated.publishedAt.timeIntervalSince1970, bundle.publishedAt.timeIntervalSince1970 + 3_600)
    }

}
