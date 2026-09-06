import Foundation
import XCTest

@testable import MacParakeetCore

final class PromptCodableCompatibilityTests: XCTestCase {
    func testLegacyPromptDefaultsMissingNotesPreferenceToFalse() throws {
        let data = Data(
            """
            {"id":"3B902BE2-9E61-4147-AEC5-837685D6313B","name":"Legacy",
             "content":"Summarize","category":"summary","isBuiltIn":false,
             "isVisible":true,"isAutoRun":true,"sortOrder":3,"createdAt":100,"updatedAt":200}
            """.utf8)
        let prompt = try JSONDecoder().decode(Prompt.self, from: data)
        XCTAssertFalse(prompt.includeMeetingNotes)
        XCTAssertEqual(prompt.name, "Legacy")
        XCTAssertTrue(prompt.isAutoRun)
        XCTAssertNil(prompt.inferenceSettings)
    }

    func testLegacyResultDefaultsMissingNotesPreferenceToFalse() throws {
        let data = Data(
            """
            {"id":"3B902BE2-9E61-4147-AEC5-837685D6313B",
             "transcriptionId":"A405DCFE-346A-46B4-909F-588A8C0964EC",
             "promptName":"Legacy","promptContent":"Summarize","content":"Result",
             "createdAt":100,"updatedAt":200}
            """.utf8)
        let result = try JSONDecoder().decode(PromptResult.self, from: data)
        XCTAssertFalse(result.includeMeetingNotesSnapshot)
        XCTAssertEqual(result.content, "Result")
        XCTAssertNil(result.inferenceSettingsSnapshot)
    }

    func testPromptRoundTripPreservesAllMetadataAndExplicitPreference() throws {
        for preference in [false, true] {
            let prompt = makePrompt(includeNotes: preference)
            let decoded = try assertRoundTrip(prompt)
            XCTAssertEqual(decoded.includeMeetingNotes, preference)
        }
    }

    func testResultRoundTripPreservesAllReceiptsAndExplicitPreference() throws {
        for preference in [false, true] {
            let result = makeResult(includeNotes: preference)
            let decoded = try assertRoundTrip(result)
            XCTAssertEqual(decoded.includeMeetingNotesSnapshot, preference)
        }
    }

    func testPromptRejectsNullOrMalformedNotesPreference() throws {
        try assertInvalidPreference(makePrompt(), key: "includeMeetingNotes")
    }

    func testResultRejectsNullOrMalformedNotesPreference() throws {
        try assertInvalidPreference(makeResult(), key: "includeMeetingNotesSnapshot")
    }

    func testPromptStillRequiresOriginalRequiredFields() throws {
        try assertRequiredFields(
            makePrompt(),
            keys: [
                "id", "name", "content", "category", "isBuiltIn", "isVisible", "isAutoRun",
                "sortOrder", "createdAt", "updatedAt",
            ])
    }

    func testResultStillRequiresOriginalRequiredFields() throws {
        try assertRequiredFields(
            makeResult(),
            keys: ["id", "transcriptionId", "promptName", "promptContent", "content", "createdAt", "updatedAt"])
    }

    private func makePrompt(includeNotes: Bool = true) -> Prompt {
        Prompt(
            name: "Review", content: "Summarize {{userNotes}}", category: .result,
            isBuiltIn: true, isVisible: false, isAutoRun: true, sortOrder: 7,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200),
            keyboardShortcut: "shortcut", runningLabel: "Reviewing…", appliesToSources: [.meeting],
            inferenceSettings: PromptInferenceSettings(
                temperature: 0.4, thinkingMode: .enabled, reasoningEffort: .high),
            includeMeetingNotes: includeNotes)
    }

    private func makeResult(includeNotes: Bool = true) -> PromptResult {
        PromptResult(
            transcriptionId: UUID(),
            promptName: "Review", promptContent: "Summarize {{userNotes}}", extraInstructions: "Be brief",
            content: "Completed result", userNotesSnapshot: "Meeting notes", includeMeetingNotesSnapshot: includeNotes,
            inferenceSettingsSnapshot: PromptInferenceSettings(
                temperature: 0.4, thinkingMode: .enabled, reasoningEffort: .high),
            createdAt: Date(timeIntervalSinceReferenceDate: 100), updatedAt: Date(timeIntervalSinceReferenceDate: 200))
    }

    @discardableResult
    private func assertRoundTrip<Value: Codable>(_ value: Value) throws -> Value {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let original = try encoder.encode(value)
        let decoded = try JSONDecoder().decode(Value.self, from: original)
        XCTAssertEqual(try encoder.encode(decoded), original)
        return decoded
    }

    private func assertInvalidPreference<Value: Codable>(_ value: Value, key: String) throws {
        let data = try JSONEncoder().encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for malformed: Any in [NSNull(), "true", 1, [], [:]] {
            object[key] = malformed
            let invalid = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(
                try JSONDecoder().decode(Value.self, from: invalid), "Accepted \(malformed) for \(key)")
        }
    }

    private func assertRequiredFields<Value: Codable>(_ value: Value, keys: [String]) throws {
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in keys {
            var legacy = object
            legacy.removeValue(forKey: key)
            let invalid = try JSONSerialization.data(withJSONObject: legacy)
            XCTAssertThrowsError(try JSONDecoder().decode(Value.self, from: invalid), "Accepted missing \(key)")
        }
    }
}
