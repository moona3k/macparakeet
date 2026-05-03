import XCTest
@testable import MacParakeetCore

final class QuickPromptBundleTests: XCTestCase {
    func testRoundTripPreservesAllFields() throws {
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        let prompts = [
            QuickPrompt(
                id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
                label: "Catch me up",
                prompt: "Summarize the meeting so far.",
                groupLabel: "CATCH UP",
                sortOrder: 0,
                isVisible: true,
                isPinned: false,
                isBuiltIn: false,
                createdAt: now,
                updatedAt: now
            ),
            QuickPrompt(
                id: UUID(uuidString: "22222222-3333-4444-8555-666666666666")!,
                label: "TL;DR",
                prompt: "Punchy two-line summary.",
                groupLabel: nil,
                sortOrder: 4,
                isVisible: false,
                isPinned: true,
                isBuiltIn: false,
                createdAt: now,
                updatedAt: now
            ),
        ]

        let bundle = QuickPromptBundle(from: prompts, exportedAt: now, appVersion: "0.7.0")
        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(QuickPromptBundle.self, from: data)

        XCTAssertEqual(decoded.schema, "macparakeet.quick_prompts")
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.appVersion, "0.7.0")
        XCTAssertEqual(decoded.prompts.count, 2)
        XCTAssertEqual(decoded.prompts.map(\.label), ["Catch me up", "TL;DR"])
        XCTAssertEqual(decoded.prompts.map(\.isPinned), [false, true])
        XCTAssertEqual(decoded.prompts[0].groupLabel, "CATCH UP")
        XCTAssertNil(decoded.prompts[1].groupLabel)
        XCTAssertEqual(decoded.prompts[1].isVisible, false)
    }

    func testValidateRejectsWrongSchema() throws {
        let json = """
            {
              "schema": "macparakeet.vocabulary",
              "version": 2,
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
            XCTAssertEqual(error as? QuickPromptBundleError, .unsupportedVersion(found: 99, supported: 2))
        }
    }

    func testValidateAcceptsLegacyV1Bundle() throws {
        // v1 wire format (kind-based). Decoder must accept it; validate() too.
        let json = """
            {
              "schema": "macparakeet.quick_prompts",
              "version": 1,
              "exportedAt": "2026-05-02T20:00:00Z",
              "prompts": []
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(QuickPromptBundle.self, from: Data(json.utf8))
        XCTAssertNoThrow(try bundle.validate())
        XCTAssertEqual(bundle.version, 1)
    }

    func testForwardCompatIgnoresUnknownTopLevelFields() throws {
        let json = """
            {
              "schema": "macparakeet.quick_prompts",
              "version": 2,
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
              "version": 2,
              "exportedAt": "2026-05-02T20:00:00Z",
              "prompts": [
                {
                  "id": "11111111-2222-4333-8444-555555555555",
                  "label": "Test",
                  "prompt": "Test prompt",
                  "groupLabel": null,
                  "sortOrder": 0,
                  "isVisible": true,
                  "isPinned": false,
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

    func testV1KindFieldDecodesIntoIsPinned() throws {
        // v1 bundle: each prompt carries `kind` instead of `isPinned`. Decoder
        // must derive isPinned from kind ("follow_up" → true, else false).
        let json = """
            {
              "schema": "macparakeet.quick_prompts",
              "version": 1,
              "exportedAt": "2026-05-02T20:00:00Z",
              "prompts": [
                {
                  "id": "11111111-2222-4333-8444-555555555555",
                  "kind": "follow_up",
                  "label": "Why?",
                  "prompt": "Explain.",
                  "groupLabel": null,
                  "sortOrder": 0,
                  "isVisible": true,
                  "isBuiltIn": false
                },
                {
                  "id": "22222222-3333-4444-8555-666666666666",
                  "kind": "starter",
                  "label": "Summarize",
                  "prompt": "Summarize so far.",
                  "groupLabel": "CATCH UP",
                  "sortOrder": 0,
                  "isVisible": true,
                  "isBuiltIn": false
                }
              ]
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(QuickPromptBundle.self, from: Data(json.utf8))

        XCTAssertEqual(bundle.prompts.count, 2)
        XCTAssertTrue(bundle.prompts[0].isPinned, "kind=follow_up should land as isPinned=true")
        XCTAssertFalse(bundle.prompts[1].isPinned, "kind=starter should land as isPinned=false")
    }

    func testMissingIsPinnedAndKindDefaultsToFalse() throws {
        // Defensive: a malformed file with neither field should default
        // isPinned to false rather than throw.
        let json = """
            {
              "schema": "macparakeet.quick_prompts",
              "version": 2,
              "exportedAt": "2026-05-02T20:00:00Z",
              "prompts": [
                {
                  "id": "11111111-2222-4333-8444-555555555555",
                  "label": "Bare",
                  "prompt": "x",
                  "sortOrder": 0,
                  "isVisible": true,
                  "isBuiltIn": false
                }
              ]
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(QuickPromptBundle.self, from: Data(json.utf8))
        XCTAssertEqual(bundle.prompts.first?.isPinned, false)
    }

    func testMaterializeCoercesForgedBuiltIn() {
        let entry = QuickPromptBundle.ExportedQuickPrompt(
            id: UUID(),
            label: "Forged",
            prompt: "x",
            groupLabel: nil,
            sortOrder: 0,
            isVisible: true,
            isPinned: false,
            isBuiltIn: true
        )
        let materialized = QuickPromptBundle.materialize(entry)
        XCTAssertFalse(materialized.isBuiltIn)
    }

    func testMaterializeTrustsRealBuiltInID() {
        let realID = QuickPrompt.builtInPrompts().first!.id
        let entry = QuickPromptBundle.ExportedQuickPrompt(
            id: realID,
            label: "Re-styled",
            prompt: "y",
            groupLabel: "X",
            sortOrder: 0,
            isVisible: true,
            isPinned: false,
            isBuiltIn: true
        )
        let materialized = QuickPromptBundle.materialize(entry)
        XCTAssertTrue(materialized.isBuiltIn)
    }

    func testMaterializePreservesBuiltInPinState() {
        let unpinned = QuickPrompt.builtInPrompts().first { !$0.isPinned }!
        let entry = QuickPromptBundle.ExportedQuickPrompt(
            id: unpinned.id,
            label: "Moved",
            prompt: "should preserve imported pin state",
            groupLabel: "CATCH UP",
            sortOrder: 0,
            isVisible: true,
            isPinned: true,
            isBuiltIn: true
        )

        let materialized = QuickPromptBundle.materialize(entry)
        XCTAssertEqual(materialized.isPinned, true, "pin state is user data even for built-ins")
        XCTAssertTrue(materialized.isBuiltIn)
    }

    func testIsPinnedWireFormatBoolean() throws {
        let prompts = [QuickPrompt(label: "x", prompt: "y", isPinned: true)]
        let bundle = QuickPromptBundle(from: prompts, exportedAt: Date(), appVersion: nil)
        let data = try JSONEncoder().encode(bundle)
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("\"isPinned\":true"), "JSON should emit isPinned as boolean")
        XCTAssertFalse(s.contains("\"kind\""), "v2 export must not emit legacy kind field")
    }
}
