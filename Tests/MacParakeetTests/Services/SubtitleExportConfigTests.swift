import XCTest
@testable import MacParakeetCore

@MainActor
final class SubtitleExportConfigTests: XCTestCase {

    // MARK: - SubtitleExportConfig property mutation

    func testDirectPropertyMutationPreservesValues() {
        var config = SubtitleExportConfig()
        let original = config

        config.maxCharsPerLine = 55
        XCTAssertEqual(config.maxCharsPerLine, 55)
        XCTAssertEqual(config.maxWordsPerCue, original.maxWordsPerCue, "Other fields should be unchanged")

        config.maxDurationMs = 5000
        XCTAssertEqual(config.maxDurationMs, 5000)

        config.gapThresholdMs = 200
        XCTAssertEqual(config.gapThresholdMs, 200)

        config.maxWordsPerCue = 8
        XCTAssertEqual(config.maxWordsPerCue, 8)

        config.maxLinesPerCue = 1
        XCTAssertEqual(config.maxLinesPerCue, 1)

        config.breakOnPunctuation = false
        XCTAssertEqual(config.breakOnPunctuation, false)
    }

    func testRapidPropertyMutationDoesNotCorrupt() {
        var config = SubtitleExportConfig()
        // Simulate rapid slider ticks (like dragging from 10 to 80 char limit)
        for i in 10...80 {
            config.maxCharsPerLine = i
            XCTAssertEqual(config.maxCharsPerLine, i)
        }
        XCTAssertEqual(config.maxCharsPerLine, 80)
        XCTAssertEqual(config.maxWordsPerCue, SubtitleExportConfig().maxWordsPerCue)
        XCTAssertEqual(config.maxDurationMs, SubtitleExportConfig().maxDurationMs)
    }

    func testEdgeCaseValues() {
        var config = SubtitleExportConfig()

        config.maxCharsPerLine = 10
        XCTAssertEqual(config.maxCharsPerLine, 10)

        config.maxCharsPerLine = 80
        XCTAssertEqual(config.maxCharsPerLine, 80)

        config.maxDurationMs = 1000
        XCTAssertEqual(config.maxDurationMs, 1000)

        config.maxDurationMs = 10000
        XCTAssertEqual(config.maxDurationMs, 10000)

        config.maxWordsPerCue = 1
        XCTAssertEqual(config.maxWordsPerCue, 1)

        config.maxWordsPerCue = 50
        XCTAssertEqual(config.maxWordsPerCue, 50)
    }

    // MARK: - TranscriptExportOptions nested mutation

    func testNestedConfigMutationThroughOptions() {
        var options = TranscriptExportOptions()
        let originalTimestamps = options.includeTimestamps

        options.subtitleConfig.maxCharsPerLine = 30
        XCTAssertEqual(options.subtitleConfig.maxCharsPerLine, 30)
        XCTAssertEqual(options.includeTimestamps, originalTimestamps)

        options.subtitleConfig.maxDurationMs = 3000
        options.subtitleConfig.gapThresholdMs = 500
        XCTAssertEqual(options.subtitleConfig.maxCharsPerLine, 30)
        XCTAssertEqual(options.subtitleConfig.maxDurationMs, 3000)
        XCTAssertEqual(options.subtitleConfig.gapThresholdMs, 500)
    }

    func testRapidNestedMutationSimulatingSliderDrag() {
        var options = TranscriptExportOptions()

        for value in stride(from: 42, through: 60, by: 1) {
            options.subtitleConfig.maxCharsPerLine = Int(value)
        }
        XCTAssertEqual(options.subtitleConfig.maxCharsPerLine, 60)

        for value in stride(from: 7000, through: 3000, by: -100) {
            options.subtitleConfig.maxDurationMs = Int(value)
        }
        XCTAssertEqual(options.subtitleConfig.maxDurationMs, 3000)
    }

    func testMultipleFieldRapidMutationSimulatingUserSession() {
        var options = TranscriptExportOptions()

        for v in 42...55 { options.subtitleConfig.maxCharsPerLine = v }
        for v in stride(from: 7000, through: 5000, by: -100) { options.subtitleConfig.maxDurationMs = Int(v) }
        for v in stride(from: 800, through: 200, by: -50) { options.subtitleConfig.gapThresholdMs = Int(v) }
        for v in stride(from: 12, through: 8, by: -1) { options.subtitleConfig.maxWordsPerCue = Int(v) }
        options.subtitleConfig.maxLinesPerCue = 1
        options.subtitleConfig.breakOnPunctuation = false

        XCTAssertEqual(options.subtitleConfig.maxCharsPerLine, 55)
        XCTAssertEqual(options.subtitleConfig.maxDurationMs, 5000)
        XCTAssertEqual(options.subtitleConfig.gapThresholdMs, 200)
        XCTAssertEqual(options.subtitleConfig.maxWordsPerCue, 8)
        XCTAssertEqual(options.subtitleConfig.maxLinesPerCue, 1)
        XCTAssertEqual(options.subtitleConfig.breakOnPunctuation, false)

        XCTAssertTrue(options.includeTimestamps)
        XCTAssertFalse(options.includeSpeakerLabels)
        XCTAssertTrue(options.includeMetadata)
    }

    func testCopyOnWriteSemantics() {
        let original = TranscriptExportOptions()
        var copy = original

        copy.subtitleConfig.maxCharsPerLine = 99
        XCTAssertEqual(copy.subtitleConfig.maxCharsPerLine, 99)
        XCTAssertEqual(original.subtitleConfig.maxCharsPerLine, 42, "Original should be unchanged (value semantics)")
    }

    // MARK: - RawRepresentable roundtrip (verifies Codable fix)

    func testRawValueRoundtrip() {
        var options = TranscriptExportOptions()
        options.includeTimestamps = false
        options.includeSpeakerLabels = false
        options.includeMetadata = true
        options.subtitleConfig.maxCharsPerLine = 55
        options.subtitleConfig.maxDurationMs = 4500
        options.subtitleConfig.gapThresholdMs = 150
        options.subtitleConfig.maxWordsPerCue = 20
        options.subtitleConfig.maxLinesPerCue = 1
        options.subtitleConfig.breakOnPunctuation = false

        let rawValue = options.rawValue
        XCTAssertFalse(rawValue.isEmpty, "Serialization should produce non-empty string")

        guard let decoded = TranscriptExportOptions(rawValue: rawValue) else {
            XCTFail("Failed to decode TranscriptExportOptions from rawValue")
            return
        }
        XCTAssertEqual(decoded.includeTimestamps, options.includeTimestamps)
        XCTAssertEqual(decoded.includeSpeakerLabels, options.includeSpeakerLabels)
        XCTAssertEqual(decoded.includeMetadata, options.includeMetadata)
        XCTAssertEqual(decoded.subtitleConfig.maxCharsPerLine, 55)
        XCTAssertEqual(decoded.subtitleConfig.maxDurationMs, 4500)
        XCTAssertEqual(decoded.subtitleConfig.maxWordsPerCue, 20)
        XCTAssertEqual(decoded.subtitleConfig.maxDurationMs, 4500)
        XCTAssertEqual(decoded.subtitleConfig.maxWordsPerCue, 20)
    }

    func testDefaultOptionsRoundtrip() {
        let original = TranscriptExportOptions()
        let rawValue = original.rawValue
        guard let decoded = TranscriptExportOptions(rawValue: rawValue) else {
            XCTFail("Default options should roundtrip")
            return
        }
        XCTAssertEqual(decoded, original)
    }

    func testInvalidRawValueReturnsNil() {
        XCTAssertNil(TranscriptExportOptions(rawValue: "not json"))
        XCTAssertNil(TranscriptExportOptions(rawValue: ""))
    }
}
