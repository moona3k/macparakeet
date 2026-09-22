import XCTest
@testable import MacParakeetCore

final class PromptDiffServiceTests: XCTestCase {
    func testIdenticalVersionsHaveNoChanges() {
        let promptId = UUID()
        let oldVersion = version(
            promptId: promptId,
            number: 1,
            content: "# Summary\n\nHello",
            settings: PromptInferenceSettings(temperature: 0.2),
            modelOverride: "local-model"
        )
        let newVersion = version(
            promptId: promptId,
            number: 2,
            content: oldVersion.content,
            settings: oldVersion.inferenceSettings,
            modelOverride: oldVersion.modelOverride
        )

        let result = PromptDiffService.diff(from: oldVersion, to: newVersion)

        XCTAssertFalse(result.hasChanges)
        XCTAssertEqual(result.markdown.lines.map(\.kind), [.unchanged, .unchanged, .unchanged])
        XCTAssertTrue(result.inferenceSettings.isEmpty)
        XCTAssertNil(result.modelOverride)
    }

    func testMarkdownDiffAlignsLinesAndRefinesModifiedLineByWord() throws {
        let result = PromptDiffService.markdownDiff(
            from: "# Résumé\nBonjour 👩🏽‍💻 monde\nFin",
            to: "# Résumé\nBonjour 👩🏽‍💻 équipe\nNouvelle ligne\nFin"
        )

        XCTAssertEqual(result.lines.map(\.kind), [.unchanged, .modified, .added, .unchanged])

        let modified = result.lines[1]
        XCTAssertEqual(modified.oldLineNumber, 2)
        XCTAssertEqual(modified.newLineNumber, 2)
        XCTAssertEqual(modified.oldSegments.map(\.text).joined(), modified.oldText)
        XCTAssertEqual(modified.newSegments.map(\.text).joined(), modified.newText)
        XCTAssertEqual(
            modified.oldSegments.filter { $0.kind == .removed }.map(\.text).joined(),
            "monde"
        )
        XCTAssertEqual(
            modified.newSegments.filter { $0.kind == .added }.map(\.text).joined(),
            "équipe"
        )

        try assertRangesMatchText(modified.oldSegments, in: XCTUnwrap(modified.oldText))
        try assertRangesMatchText(modified.newSegments, in: XCTUnwrap(modified.newText))

        let added = result.lines[2]
        XCTAssertNil(added.oldLineNumber)
        XCTAssertEqual(added.newLineNumber, 3)
        XCTAssertEqual(added.newSegments.first?.kind, .added)
    }

    func testUnicodeRangesUseExtendedGraphemeClusters() throws {
        let result = PromptDiffService.markdownDiff(
            from: "Café 👨‍👩‍👧‍👦 prêt",
            to: "Café 👨‍👩‍👧‍👦 terminé"
        )
        let line = try XCTUnwrap(result.lines.first)

        XCTAssertEqual(line.kind, .modified)
        XCTAssertEqual(line.oldSegments.map(\.text).joined(), "Café 👨‍👩‍👧‍👦 prêt")
        XCTAssertEqual(line.newSegments.map(\.text).joined(), "Café 👨‍👩‍👧‍👦 terminé")
        try assertRangesMatchText(line.oldSegments, in: "Café 👨‍👩‍👧‍👦 prêt")
        try assertRangesMatchText(line.newSegments, in: "Café 👨‍👩‍👧‍👦 terminé")

        let familySegment = try XCTUnwrap(
            line.oldSegments.first { $0.text.contains("👨‍👩‍👧‍👦") }
        )
        XCTAssertEqual(familySegment.characterRange.count, familySegment.text.count)
    }

    func testLineEndingStyleDoesNotCreateContentChanges() {
        let result = PromptDiffService.markdownDiff(
            from: "First\r\nSecond\r\n",
            to: "First\nSecond\n"
        )

        XCTAssertFalse(result.hasChanges)
        XCTAssertEqual(result.lines.count, 3)
    }

    func testLargeComparisonPreservesLineAlignmentAndWordRefinement() {
        let oldLines = (0..<500).map {
            "Instruction \($0): résumer le contexte, les décisions et les actions de cette réunion avec précision."
        }
        let newLines = oldLines.map { $0.replacingOccurrences(of: "précision", with: "concision") }

        let result = PromptDiffService.markdownDiff(
            from: oldLines.joined(separator: "\n"),
            to: newLines.joined(separator: "\n")
        )

        XCTAssertEqual(result.lines.count, 500)
        XCTAssertEqual(result.lines.map(\.kind), Array(repeating: .modified, count: 500))
        XCTAssertEqual(result.lines.compactMap(\.oldText), oldLines)
        XCTAssertEqual(result.lines.compactMap(\.newText), newLines)
        for (index, line) in result.lines.enumerated() {
            XCTAssertEqual(line.oldLineNumber, index + 1)
            XCTAssertEqual(line.newLineNumber, index + 1)
            XCTAssertEqual(line.oldSegments.filter { $0.kind == .removed }.map(\.text), ["précision"])
            XCTAssertEqual(line.newSegments.filter { $0.kind == .added }.map(\.text), ["concision"])
        }
    }

    func testStructuredDiffReportsOnlyChangedInferenceFieldsInStableOrder() {
        let oldSettings = PromptInferenceSettings(
            temperature: 0.2,
            topP: 0.9,
            topK: 20,
            thinkingMode: .enabled,
            reasoningEffort: .low
        )
        let newSettings = PromptInferenceSettings(
            temperature: 0.7,
            topP: 0.9,
            maxTokens: 800,
            thinkingMode: .disabled,
            reasoningEffort: .high
        )

        let changes = PromptDiffService.inferenceSettingsDiff(from: oldSettings, to: newSettings)

        XCTAssertEqual(
            changes.map(\.field),
            [.temperature, .topK, .maxTokens, .thinkingMode, .reasoningEffort]
        )
        XCTAssertEqual(changes[0].oldValue, .decimal(0.2))
        XCTAssertEqual(changes[0].newValue, .decimal(0.7))
        XCTAssertEqual(changes[1].oldValue, .integer(20))
        XCTAssertNil(changes[1].newValue)
        XCTAssertNil(changes[2].oldValue)
        XCTAssertEqual(changes[2].newValue, .integer(800))
        XCTAssertEqual(changes[3].oldValue, .thinkingMode(.enabled))
        XCTAssertEqual(changes[3].newValue, .thinkingMode(.disabled))
        XCTAssertEqual(changes[4].oldValue, .reasoningEffort(.low))
        XCTAssertNil(changes[4].newValue)
    }

    func testDefaultSettingsAndNilAreEquivalent() {
        XCTAssertTrue(
            PromptDiffService.inferenceSettingsDiff(
                from: nil,
                to: PromptInferenceSettings()
            ).isEmpty
        )
    }

    func testVersionDiffReportsModelOverrideChange() throws {
        let promptId = UUID()
        let oldVersion = version(promptId: promptId, number: 1, content: "Prompt")
        let newVersion = version(
            promptId: promptId,
            number: 2,
            content: "Prompt",
            modelOverride: "qwen3.8-flash-next"
        )

        let change = try XCTUnwrap(
            PromptDiffService.diff(from: oldVersion, to: newVersion).modelOverride
        )
        XCTAssertNil(change.oldValue)
        XCTAssertEqual(change.newValue, "qwen3.8-flash-next")
    }

    private func version(
        promptId: UUID,
        number: Int,
        content: String,
        settings: PromptInferenceSettings? = nil,
        modelOverride: String? = nil
    ) -> PromptVersion {
        PromptVersion(
            promptId: promptId,
            versionNumber: number,
            content: content,
            inferenceSettings: settings,
            modelOverride: modelOverride
        )
    }

    private func assertRangesMatchText(
        _ segments: [PromptDiffTextSegment],
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for segment in segments {
            let lower = text.index(text.startIndex, offsetBy: segment.characterRange.lowerBound)
            let upper = text.index(text.startIndex, offsetBy: segment.characterRange.upperBound)
            XCTAssertEqual(String(text[lower..<upper]), segment.text, file: file, line: line)
        }
    }
}
