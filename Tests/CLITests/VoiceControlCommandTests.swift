import ArgumentParser
import Foundation
import XCTest

@testable import CLI
@testable import MacParakeetCore

final class VoiceControlCommandTests: XCTestCase {
    private func writeSession(instruction: String, snapshot: VoiceControlSnapshot) async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-control-cli-\(UUID().uuidString)", isDirectory: true)
        let store = VoiceControlTraceStore(directory: root, pointerDirectory: nil, retention: 2)
        await store.beginTask(id: UUID(), instruction: instruction)
        await store.noteObservation(snapshot)
        return store.latestURL
    }

    func testReplayCompilesAUniqueNamedPressLocallyWithoutJev() async throws {
        let snapshot = VoiceControlSnapshot(
            contextID: "ax:1:1", applicationName: "TextEdit",
            targets: [
                VoiceControlTarget(id: "n:0", label: "Save", role: "AXButton", operations: [.press]),
                VoiceControlTarget(id: "n:1", label: "Cancel", role: "AXButton", operations: [.press]),
            ])
        let url = try await writeSession(instruction: "click Save", snapshot: snapshot)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = try VoiceControlReplayCommand.parse([url.path, "--json"])
        let output = try await captureStandardOutput { try await command.run() }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["goal"] as? String, "click Save")
        XCTAssertEqual(object["situation"] as? String, "plain")
        let decision = try XCTUnwrap(object["decision"] as? [String: Any])
        XCTAssertEqual(decision["kind"] as? String, "action")
        XCTAssertEqual(decision["actor"] as? String, "local")
        let action = try XCTUnwrap(decision["action"] as? [String: Any])
        XCTAssertEqual(action["operation"] as? String, "press")
        XCTAssertEqual(action["targetID"] as? String, "n:0")
        XCTAssertEqual(action["label"] as? String, "Save")
        XCTAssertNil(object["jevRequest"], "a locally compiled action never reaches Jev")
    }

    func testReplayReportsTheOutcomeChoiceJevWouldBeAskedWithoutSending() async throws {
        let snapshot = VoiceControlSnapshot(
            contextID: "ax:2:2", applicationName: "Google Chrome",
            targets: [
                VoiceControlTarget(
                    id: "c0", label: "London, United Kingdom", role: "AXStaticText", operations: [.press, .key]),
                VoiceControlTarget(
                    id: "c1", label: "London, Ontario, Canada", role: "AXStaticText", operations: [.press, .key]),
                VoiceControlTarget(
                    id: "else", label: "Where else?", role: "AXComboBox", operations: [.setValue, .press, .key]),
                VoiceControlTarget(id: "search", label: "Search flights", role: "AXButton", operations: [.press]),
            ])
        let url = try await writeSession(instruction: "Find one-way flights from Zurich to London", snapshot: snapshot)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = try VoiceControlReplayCommand.parse([url.path, "--goal", "pick London", "--json"])
        let output = try await captureStandardOutput { try await command.run() }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["situation"] as? String, "suggestionPicker")
        let decision = try XCTUnwrap(object["decision"] as? [String: Any])
        XCTAssertEqual(decision["kind"] as? String, "clarify")
        let request = try XCTUnwrap(object["jevRequest"] as? [String: Any])
        XCTAssertEqual(request["kind"] as? String, "outcome")
        XCTAssertEqual(request["jev"] as? Bool, false)
        let options = try XCTUnwrap(request["options"] as? [[String: Any]])
        XCTAssertEqual(Set(options.compactMap { $0["id"] as? String }), ["c0", "c1"])
        XCTAssertNil(object["jevDecision"])
    }

    func testHistoryParsingKeepsColonsInTargetIDs() throws {
        let parsed = try VoiceControlReplayCommand.parseHistory("setValue:n:3:transitionObserved, press:app:812")
        XCTAssertEqual(parsed.map(\.operation), [.setValue, .press])
        XCTAssertEqual(parsed.map(\.targetID), ["n:3", "app:812"])
        XCTAssertEqual(parsed.map(\.receiptStatus), [.transitionObserved, .verified])
        XCTAssertThrowsError(try VoiceControlReplayCommand.parseHistory("teleport:n:1"))
        XCTAssertEqual(try VoiceControlReplayCommand.parseHistory(nil), [])
    }

    func testReplayRejectsOutOfRangeObservation() async throws {
        let snapshot = VoiceControlSnapshot(contextID: "ax:3:3", applicationName: "Finder", targets: [])
        let url = try await writeSession(instruction: "open Downloads", snapshot: snapshot)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = try VoiceControlReplayCommand.parse([url.path, "--observation", "4"])
        do {
            try await command.run()
            XCTFail("expected a validation error")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("out of range"))
        }
    }
}
