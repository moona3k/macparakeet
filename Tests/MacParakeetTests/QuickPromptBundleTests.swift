import XCTest
@testable import MacParakeetCore

final class QuickPromptBundleTests: XCTestCase {
    func testRoundTripPreservesAllFields() throws {
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        let prompts = [
            QuickPrompt(
                id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
                kind: .starter,
                label: "Catch me up",
                prompt: "Summarize the meeting so far.",
                groupLabel: "CATCH UP",
                sortOrder: 0,
                isVisible: true,
                isBuiltIn: false,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "22222222-3333-4444-8555-666666666666")!,
                kind: .followUp,
                label: "TL;DR",
                prompt: "Punchy two-line summary.",
                groupLabel: nil,
                sortOrder: 4,
                isVisible: false,
                isBuiltIn: false,
                createdAt: now,
                updatedAt: now
            ),
        ]

        let bundle = QuickPromptBundle(from: prompts, exportedAt: now, appVersion: "0.7.0")
        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(QuickPromptBundle.self, from: data)

        XCTAssertEqual(decoded.schema, "macparakeet.quick_prompts")
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.appVersion, "0.7.0")
        XCTAssertEqual(decoded.prompts.count, 2)
        XCTAssertEqual(decoded.prompts.map(\.label), ["Catch me up", "TL;DR"])
        XCTAssertEqual(decoded.prompts.map(\.kind), [.starter, .followUp])
        XCTAssertEqual(decoded.prompts[0].groupLabel, "CATCH UP")
        XCTAssertNil(decoded.prompts[1].groupLabel)
        XCTAssertEqual(decoded.prompts[1].isVisible, false)
    }

    func testValidateRejectsWrongSchema() throws {
        let json = """
            {
              "schema": "macparakeet.vocabulary",
              "version": 1,
              "exportedAt": "2026-05-02T20:00:00Z",
              "prompts": []
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(QuickPromptBundle.self, from: Data(json.utf8))

        XCTAssertThrowsError(try bundle.validate()) { error in
            XCTAssertEqual(error as? QuickPromptBundleError, .wrongSchema(found: "macparakeet.vocabulary"))
        }
    }

    func testValidateRejectsFutureSchemaVersion() throws {
        let json = """
            {
              "schema": "macparakeet.quick_prompts",
              "version": 99,
              "exportedAt": "2026-05-02T20:00:00Z",
              "prompts": []
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(QuickPromptBundle.self, from: Data(json.utf8))

        XCTAssertThrowsError(try bundle.validate()) { error in
            XCTAssertEqual(error as? QuickPromptBundleError, .unsupportedVersion(found: 99, supported: 1))
        }
    }

    func testForwardCompatIgnoresUnknownTopLevelFields() throws {
        let json = """
            {
              "schema": "macparakeet.quick_prompts",
              "version": 1,
              "exportedAt": "2026-05-02T20:00:00Z",
              "iAmFromTheFuture": "whatever",
              "prompts": []
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(QuickPromptBundle.self, from: Data(json.utf8))
        try bundle.validate()
        XCTAssertEqual(bundle.prompts.count, 0)
    }

    func testForwardCompatIgnoresUnknownPromptFields() throws {
        let json = """
            {
              "schema": "macparakeet.quick_prompts",
              "version": 1,
              "exportedAt": "2026-05-02T20:00:00Z",
              "prompts": [
                {
                  "id": "11111111-2222-4333-8444-555555555555",
                  "kind": "starter",
                  "label": "Test",
                  "prompt": "Test prompt",
                  "groupLabel": null,
                  "sortOrder": 0,
                  "isVisible": true,
                  "isBuiltIn": false,
                  "experimental": "ignore me"
                }
              ]
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(QuickPromptBundle.self, from: Data(json.utf8))
        XCTAssertEqual(bundle.prompts.count, 1)
        XCTAssertEqual(bundle.prompts.first?.label, "Test")
    }

    func testMaterializeCoercesForgedBuiltIn() {
        let entry = QuickPromptBundle.ExportedQuickPrompt(
            id: UUID(),
            kind: .followUp,
            label: "Forged",
            prompt: "x",
            groupLabel: nil,
            sortOrder: 0,
            isVisible: true,
            isBuiltIn: true
        )
        let materialized = QuickPromptBundle.materialize(entry)
        XCTAssertFalse(materialized.isBuiltIn)
    }

    func testMaterializeTrustsRealBuiltInID() {
        let realID = QuickPrompt.builtInPrompts().first!.id
        let entry = QuickPromptBundle.ExportedQuickPrompt(
            id: realID,
            kind: .starter,
            label: "Re-styled",
            prompt: "y",
            groupLabel: "X",
            sortOrder: 0,
            isVisible: true,
            isBuiltIn: true
        )
        let materialized = QuickPromptBundle.materialize(entry)
        XCTAssertTrue(materialized.isBuiltIn)
    }

    func testMaterializeCanonicalizesBuiltInKind() {
        let starter = QuickPrompt.builtInPrompts(kind: .starter).first!
        let entry = QuickPromptBundle.ExportedQuickPrompt(
            id: starter.id,
            kind: .followUp,
            label: "Moved",
            prompt: "should stay a starter",
            groupLabel: "CATCH UP",
            sortOrder: 0,
            isVisible: true,
            isBuiltIn: true
        )

        let materialized = QuickPromptBundle.materialize(entry)
        XCTAssertEqual(materialized.kind, .starter)
        XCTAssertTrue(materialized.isBuiltIn)
    }

    func testMaterializeDropsGroupLabelForFollowUps() {
        let entry = QuickPromptBundle.ExportedQuickPrompt(
            id: UUID(),
            kind: .followUp,
            label: "Flat",
            prompt: "Stay flat.",
            groupLabel: "SHOULD NOT STICK",
            sortOrder: 0,
            isVisible: true,
            isBuiltIn: false
        )

        let materialized = QuickPromptBundle.materialize(entry)
        XCTAssertNil(materialized.groupLabel)
    }

    func testKindWireFormatIsSnakeCase() throws {
        let prompts = [QuickPrompt(kind: .followUp, label: "x", prompt: "y")]
        let bundle = QuickPromptBundle(from: prompts, exportedAt: Date(), appVersion: nil)
        let data = try JSONEncoder().encode(bundle)
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("\"kind\":\"follow_up\""), "JSON should use snake_case 'follow_up' wire value")
    }
}
