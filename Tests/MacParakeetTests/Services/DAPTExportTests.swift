import Foundation
import XCTest
@testable import MacParakeetCore

@MainActor
final class DAPTExportTests: XCTestCase {
    private let exportService = ExportService()

    func testTimedSpeakerTranscriptMapsToOriginalTranscriptEvents() throws {
        let transcription = Transcription(
            fileName: "Interview & Review.m4a",
            durationMs: 2_400,
            rawTranscript: "Olá & bem-vindos. Resposta <final>.",
            wordTimestamps: [
                WordTimestamp(word: "Olá", startMs: 0, endMs: 400, confidence: 0.98, speakerId: "S1"),
                WordTimestamp(word: "&", startMs: 400, endMs: 500, confidence: 0.95, speakerId: "S1"),
                WordTimestamp(word: "bem-vindos.", startMs: 500, endMs: 1_000, confidence: 0.97, speakerId: "S1"),
                WordTimestamp(word: "Resposta", startMs: 1_500, endMs: 2_000, confidence: 0.96, speakerId: "S2"),
                WordTimestamp(word: "<final>.", startMs: 2_000, endMs: 2_400, confidence: 0.94, speakerId: "S2"),
            ],
            language: "pt-BR",
            speakers: [
                SpeakerInfo(id: "S1", label: "Ana & Co."),
                SpeakerInfo(id: "S2", label: "Bob <Lead>"),
            ],
            status: .completed
        )

        let xml = exportService.formatDAPT(transcription: transcription)

        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"))
        XCTAssertTrue(xml.contains("xmlns=\"http://www.w3.org/ns/ttml\""))
        XCTAssertTrue(xml.contains("ttp:contentProfiles=\"http://www.w3.org/ns/ttml/profile/dapt1.0/content\""))
        XCTAssertTrue(xml.contains("xml:lang=\"pt-BR\""))
        XCTAssertTrue(xml.contains("daptm:langSrc=\"pt-BR\""))
        XCTAssertTrue(xml.contains("daptm:scriptRepresents=\"audio.dialogue\""))
        XCTAssertTrue(xml.contains("daptm:scriptType=\"originalTranscript\""))
        XCTAssertTrue(xml.contains("<ttm:title>Interview &amp; Review.m4a</ttm:title>"))
        XCTAssertTrue(xml.contains("<ttm:agent type=\"character\" xml:id=\"character_1\">"))
        XCTAssertTrue(xml.contains("<ttm:name type=\"alias\">Ana &amp; Co.</ttm:name>"))
        XCTAssertTrue(xml.contains("<ttm:name type=\"alias\">Bob &lt;Lead&gt;</ttm:name>"))
        XCTAssertTrue(
            xml.contains(
                "<div xml:id=\"event_1\" begin=\"00:00:00.000\" end=\"00:00:01.000\" ttm:agent=\"character_1\" daptm:represents=\"audio.dialogue\">"
            ))
        XCTAssertTrue(xml.contains("<p>Olá &amp; bem-vindos.</p>"))
        XCTAssertTrue(
            xml.contains(
                "<div xml:id=\"event_2\" begin=\"00:00:01.500\" end=\"00:00:02.400\" ttm:agent=\"character_2\" daptm:represents=\"audio.dialogue\">"
            ))
        XCTAssertTrue(xml.contains("<p>Resposta &lt;final&gt;.</p>"))
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
    }

    func testTimedTranscriptWithoutDiarizationOmitsAgentsButKeepsTiming() throws {
        let transcription = Transcription(
            fileName: "solo.wav",
            rawTranscript: "Hello world.",
            wordTimestamps: [
                WordTimestamp(word: "Hello", startMs: 250, endMs: 600, confidence: 0.9),
                WordTimestamp(word: "world.", startMs: 600, endMs: 1_100, confidence: 0.9),
            ],
            language: "en",
            status: .completed
        )

        let xml = exportService.formatDAPT(transcription: transcription)

        XCTAssertTrue(
            xml.contains(
                "<div xml:id=\"event_1\" begin=\"00:00:00.250\" end=\"00:00:01.100\" daptm:represents=\"audio.dialogue\">"
            ))
        XCTAssertFalse(xml.contains("<ttm:agent"))
        XCTAssertFalse(xml.contains("ttm:agent=\""))
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
    }

    func testAlignedSpeakerIDsWithoutRosterUseAnonymousIDAliases() throws {
        let transcription = Transcription(
            fileName: "legacy.wav",
            rawTranscript: "First turn. Second turn.",
            wordTimestamps: [
                WordTimestamp(word: "First", startMs: 0, endMs: 300, confidence: 0.9, speakerId: "S1"),
                WordTimestamp(word: "turn.", startMs: 300, endMs: 700, confidence: 0.9, speakerId: "S1"),
                WordTimestamp(word: "Second", startMs: 900, endMs: 1_200, confidence: 0.9, speakerId: "S2"),
                WordTimestamp(word: "turn.", startMs: 1_200, endMs: 1_600, confidence: 0.9, speakerId: "S2"),
            ],
            speakers: nil,
            status: .completed
        )

        let xml = exportService.formatDAPT(transcription: transcription)

        XCTAssertTrue(xml.contains("<ttm:name type=\"alias\">S1</ttm:name>"))
        XCTAssertTrue(xml.contains("<ttm:name type=\"alias\">S2</ttm:name>"))
        XCTAssertTrue(
            xml.contains(
                "xml:id=\"event_1\" begin=\"00:00:00.000\" end=\"00:00:00.700\" ttm:agent=\"character_1\""))
        XCTAssertTrue(
            xml.contains(
                "xml:id=\"event_2\" begin=\"00:00:00.900\" end=\"00:00:01.600\" ttm:agent=\"character_2\""))
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
    }

    func testPartialDiarizationAttributesOnlyAlignedSpeakerEvents() throws {
        let transcription = Transcription(
            fileName: "partial.wav",
            rawTranscript: "Known speaker. Unattributed words.",
            wordTimestamps: [
                WordTimestamp(word: "Known", startMs: 0, endMs: 300, confidence: 0.9, speakerId: "S1"),
                WordTimestamp(word: "speaker.", startMs: 300, endMs: 700, confidence: 0.9, speakerId: "S1"),
                WordTimestamp(word: "Unattributed", startMs: 900, endMs: 1_300, confidence: 0.9),
                WordTimestamp(word: "words.", startMs: 1_300, endMs: 1_700, confidence: 0.9),
            ],
            speakers: [SpeakerInfo(id: "S1", label: "Alice")],
            status: .completed
        )

        let xml = exportService.formatDAPT(transcription: transcription)

        XCTAssertTrue(xml.contains("<ttm:name type=\"alias\">Alice</ttm:name>"))
        XCTAssertTrue(
            xml.contains("xml:id=\"event_1\" begin=\"00:00:00.000\" end=\"00:00:00.700\" ttm:agent=\"character_1\""))
        XCTAssertTrue(
            xml.contains(
                "xml:id=\"event_2\" begin=\"00:00:00.900\" end=\"00:00:01.700\" daptm:represents=\"audio.dialogue\""))
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
    }

    func testTimestamplessTranscriptUsesUntimedEventWithoutSyntheticSpeaker() throws {
        let transcription = Transcription(
            fileName: "cohere.wav",
            durationMs: 65_000,
            rawTranscript: "Plain <text> & nothing invented.",
            wordTimestamps: nil,
            language: nil,
            speakerCount: 2,
            speakers: [SpeakerInfo(id: "S1", label: "Speaker 1")],
            status: .completed
        )

        let xml = exportService.formatDAPT(transcription: transcription)

        XCTAssertTrue(xml.contains("xml:lang=\"und\""))
        XCTAssertFalse(xml.contains("daptm:langSrc="))
        XCTAssertTrue(xml.contains("<div xml:id=\"event_1\" daptm:represents=\"audio.dialogue\">"))
        XCTAssertTrue(xml.contains("<p>Plain &lt;text&gt; &amp; nothing invented.</p>"))
        XCTAssertFalse(xml.contains("begin=\""))
        XCTAssertFalse(xml.contains("end=\""))
        XCTAssertFalse(xml.contains("<ttm:agent"))
        XCTAssertFalse(xml.contains("ttm:agent=\""))
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
    }

    func testEditedTranscriptDropsStaleTimingAndSpeakerAttribution() {
        let transcription = Transcription(
            fileName: "edited.wav",
            rawTranscript: "Old words.",
            cleanTranscript: "Corrected transcript.",
            wordTimestamps: [
                WordTimestamp(word: "Old", startMs: 0, endMs: 400, confidence: 0.9, speakerId: "S1"),
                WordTimestamp(word: "words.", startMs: 400, endMs: 900, confidence: 0.9, speakerId: "S1"),
            ],
            speakers: [SpeakerInfo(id: "S1", label: "Alice")],
            status: .completed,
            isTranscriptEdited: true
        )

        let xml = exportService.formatDAPT(transcription: transcription)

        XCTAssertTrue(xml.contains("<p>Corrected transcript.</p>"))
        XCTAssertFalse(xml.contains("Old words."))
        XCTAssertFalse(xml.contains("begin=\""))
        XCTAssertFalse(xml.contains("<ttm:agent"))
        XCTAssertFalse(xml.contains("ttm:agent=\""))
    }

    func testXML10InvalidCharactersAreRemoved() throws {
        let transcription = Transcription(
            fileName: "Bad\u{0001} title.wav",
            rawTranscript: "Hello\u{0008} world.",
            status: .completed
        )

        let xml = exportService.formatDAPT(transcription: transcription)

        XCTAssertFalse(xml.contains("\u{0001}"))
        XCTAssertFalse(xml.contains("\u{0008}"))
        XCTAssertTrue(xml.contains("<ttm:title>Bad title.wav</ttm:title>"))
        XCTAssertTrue(xml.contains("<p>Hello world.</p>"))
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
    }

    func testExportToDAPTWritesUTF8DocumentWithoutBOM() throws {
        let transcription = Transcription(
            fileName: "export.wav",
            rawTranscript: "Export me.",
            status: .completed
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dapt-export-\(UUID().uuidString).dapt.xml")
        defer { try? FileManager.default.removeItem(at: url) }

        try exportService.exportToDAPT(transcription: transcription, url: url)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(5)), Array("<?xml".utf8))
        XCTAssertNotEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix("\n"))
    }
}
