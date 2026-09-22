import Foundation
import XCTest
@testable import MacParakeetCore

final class VoiceControlTraceStoreTests: XCTestCase {
    func testPersistedSessionIncludesInstructionAndLabelsButOmitsValues() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-control-logs-\(UUID().uuidString)", isDirectory: true)
        let pointer = root.appendingPathComponent("pointer", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceControlTraceStore(directory: root, pointerDirectory: pointer, retention: 5)
        let runner = VoiceControlTurnRunner(
            adapter: TraceStoreAdapter(),
            engine: TraceClarifyEngine(),
            sink: store)
        await runner.submit("Find one-way flights from Zurich to London")
        await runner.flushTraces()

        let traces = String(decoding: try JSONEncoder().encode(await runner.traceSnapshot()), as: UTF8.self)
        XCTAssertFalse(traces.contains("Find one-way"))
        XCTAssertFalse(traces.contains("Where from?"))
        XCTAssertFalse(traces.contains("SECRET_VALUE"))
        XCTAssertFalse(traces.contains("SECRET_SELECTION"))

        let loaded = await store.loadLatest()
        let session = try XCTUnwrap(loaded)
        XCTAssertEqual(session.instruction, "Find one-way flights from Zurich to London")
        XCTAssertEqual(session.applicationName, "Google Chrome")
        XCTAssertEqual(session.observations.last?.targets.map(\.label), ["Where from?"])
        XCTAssertEqual(session.observations.last?.targets.first?.hasValue, true)
        XCTAssertTrue(session.records.contains { $0.stage == "decision" && $0.outcome == "clarify" })
        XCTAssertTrue(session.records.contains { $0.stage == "policy" && $0.outcome == "clarification_needed" })
        XCTAssertEqual(session.summary?.outcome, "clarification_needed")
        XCTAssertEqual(session.schema, VoiceControlTraceStore.schema)

        let disk = String(decoding: try Data(contentsOf: store.latestURL), as: UTF8.self)
        XCTAssertFalse(disk.contains("SECRET_VALUE"))
        XCTAssertFalse(disk.contains("SECRET_SELECTION"))
        XCTAssertTrue(disk.contains("Where from?"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pointer.appendingPathComponent("latest.json").path))
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: store.latestURL.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        XCTAssertTrue(
            String(decoding: try Data(contentsOf: pointer.appendingPathComponent("WHERE")), as: UTF8.self).contains(
                root.path))
    }

    func testPointerSkipsASymlinkDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-control-logs-\(UUID().uuidString)", isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("link")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let store = VoiceControlTraceStore(
            directory: root.appendingPathComponent("logs"), pointerDirectory: link, retention: 2)
        await store.beginTask(id: UUID(), instruction: "Synthetic instruction")
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.appendingPathComponent("latest.json").path))
    }

    func testRetentionKeepsOnlyRecentSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-control-logs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceControlTraceStore(directory: root, pointerDirectory: nil, retention: 2)
        for index in 1...3 {
            let id = UUID()
            await store.beginTask(id: id, instruction: "task \(index)")
            await store.record(
                VoiceControlTraceRecord(
                    id: UUID(), taskID: id, revision: 0, timestamp: Date(), stage: "task",
                    operation: nil, outcome: "started", durationMilliseconds: nil, candidateCount: nil,
                    observationComplete: nil, modelID: nil, decisionScore: nil, detail: nil))
        }
        let sessions = try FileManager.default.contentsOfDirectory(
            at: store.sessionsDirectory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(sessions.count, 2)
    }

    func testInboxParsesJSONAndPlainText() {
        XCTAssertEqual(
            VoiceControlInboxCommand.parse("Find flights to London"),
            VoiceControlInboxCommand(action: .submit, text: "Find flights to London"))
        XCTAssertEqual(
            VoiceControlInboxCommand.parse(#"{"action":"revise","text":"Actually Paris"}"#),
            VoiceControlInboxCommand(action: .revise, text: "Actually Paris"))
        XCTAssertEqual(
            VoiceControlInboxCommand.parse(
                #"{"action":"submit","text":"Find flights","activate":"com.google.Chrome"}"#),
            VoiceControlInboxCommand(
                action: .submit, text: "Find flights", activate: "com.google.Chrome"))
        XCTAssertEqual(
            VoiceControlInboxCommand.parse(#"{"action":"continue"}"#),
            VoiceControlInboxCommand(action: .continueTask, text: ""))
        XCTAssertNil(VoiceControlInboxCommand.parse(#"{"action":"submit"}"#))
        XCTAssertNil(VoiceControlInboxCommand.parse("   "))
    }

    func testFailedObservationRecordsClosedErrorDetail() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-control-logs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceControlTraceStore(directory: root, pointerDirectory: nil, retention: 5)
        let runner = VoiceControlTurnRunner(
            adapter: FailingObserveAdapter(),
            engine: TraceClarifyEngine(),
            sink: store)
        await runner.submit("Find one-way flights from Zurich to London")
        await runner.flushTraces()
        let traces = await runner.traceSnapshot()
        XCTAssertTrue(
            traces.contains { $0.stage == "observation" && $0.outcome == "failed" && $0.detail == "noWindow" })
        let loaded = await store.loadLatest()
        let session = try XCTUnwrap(loaded)
        XCTAssertTrue(session.records.contains { $0.detail == "noWindow" })
        XCTAssertEqual(session.summary?.outcome, "failed")
        XCTAssertTrue(session.summary?.why?.contains("noWindow") == true)
        XCTAssertTrue(session.status == nil || session.status?.contains("accessible window") == true)
    }

    func testTurnSummaryAnswersWhyATurnStalledAndShareableOmitsLabels() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-control-logs-\(UUID().uuidString)", isDirectory: true)
        let pointer = root.appendingPathComponent("pointer", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceControlTraceStore(directory: root, pointerDirectory: pointer, retention: 5)
        let runner = VoiceControlTurnRunner(
            adapter: DuplicatePressAdapter(),
            engine: DuplicatePressEngine(),
            sink: store)
        await runner.submit("Open Google Flights")
        await runner.flushTraces()

        let traces = await runner.traceSnapshot()
        XCTAssertTrue(traces.contains { $0.outcome == "duplicate_blocked" && $0.targetLabel == "Google Flights" })
        XCTAssertTrue(
            traces.contains { $0.actor == "local" && $0.route == "destination" && $0.targetID == "web:google-flights" })
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(traces), as: UTF8.self).contains("SECRET_VALUE"))

        let loaded = await store.loadLatest()
        let session = try XCTUnwrap(loaded)
        XCTAssertEqual(session.instruction, "Open Google Flights")
        XCTAssertEqual(session.summary?.outcome, "duplicate_blocked")
        XCTAssertEqual(session.summary?.lastTargetLabel, "Google Flights")
        XCTAssertEqual(session.summary?.lastTargetID, "web:google-flights")
        XCTAssertEqual(session.summary?.actor, "local")
        XCTAssertEqual(session.summary?.route, "destination")
        XCTAssertTrue(session.summary?.why?.contains("duplicate_blocked") == true)
        XCTAssertTrue(session.summary?.why?.contains("destination") == true)
        XCTAssertTrue(session.summary?.localDecisions ?? 0 >= 1)

        let markdown = String(decoding: try Data(contentsOf: store.latestMarkdownURL), as: UTF8.self)
        XCTAssertTrue(markdown.contains("outcome: duplicate_blocked"))
        XCTAssertTrue(markdown.contains("Google Flights"))
        XCTAssertTrue(markdown.contains("Open Google Flights"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pointer.appendingPathComponent("latest.md").path))
        XCTAssertTrue(
            String(decoding: try Data(contentsOf: pointer.appendingPathComponent("WHERE")), as: UTF8.self)
                .contains("latest.md"))

        let events = String(decoding: try Data(contentsOf: store.eventsURL), as: UTF8.self)
        XCTAssertTrue(events.contains("\"type\":\"step\""))
        XCTAssertTrue(events.contains("\"type\":\"turn\""))
        XCTAssertTrue(events.contains("duplicate_blocked"))
        XCTAssertTrue(events.contains("web:google-flights"))
        XCTAssertTrue(events.contains("Google Flights"))
        XCTAssertFalse(events.contains("SECRET_VALUE"))

        let export = VoiceControlShareableDiagnostics.make(
            schema: VoiceControlTraceStore.schema, taskID: session.taskID,
            summary: session.summary, records: traces)
        let shareable = String(decoding: try JSONEncoder().encode(export), as: UTF8.self)
        XCTAssertFalse(shareable.contains("Open Google Flights"))
        XCTAssertFalse(shareable.contains("Google Flights"))
        XCTAssertTrue(shareable.contains("web:google-flights"))
        XCTAssertTrue(shareable.contains("duplicate_blocked"))
        XCTAssertEqual(export.summary?.lastTargetLabel, nil)
        XCTAssertEqual(export.records.first { $0.outcome == "duplicate_blocked" }?.targetLabel, nil)
    }
}

private actor DuplicatePressEngine: VoiceControlDecisionEngine {
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        .action(
            VoiceControlAction(
                operation: .press, targetID: "web:google-flights", consequence: .ordinary))
    }
}

private actor DuplicatePressAdapter: VoiceControlAdapter {
    func observe() async throws -> VoiceControlSnapshot {
        VoiceControlSnapshot(
            contextID: "chrome", applicationName: "Google Chrome",
            targets: [
                VoiceControlTarget(
                    id: "web:google-flights", label: "Google Flights", role: "url",
                    value: "SECRET_VALUE", operations: [.press])
            ])
    }
    func execute(
        action: VoiceControlAction, snapshot: VoiceControlSnapshot, authority: ActionAuthority
    ) async throws -> VoiceControlReceipt {
        VoiceControlReceipt(status: .verified)
    }
}

private actor TraceClarifyEngine: VoiceControlDecisionEngine {
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        .clarify("Which control should I use?")
    }
}

private actor TraceStoreAdapter: VoiceControlAdapter {
    func observe() async throws -> VoiceControlSnapshot {
        VoiceControlSnapshot(
            contextID: "chrome", applicationName: "Google Chrome",
            targets: [
                VoiceControlTarget(
                    id: "from", label: "Where from?", role: "AXComboBox",
                    value: "SECRET_VALUE", operations: [.setValue, .press],
                    selectedText: "SECRET_SELECTION")
            ])
    }
    func execute(
        action: VoiceControlAction, snapshot: VoiceControlSnapshot, authority: ActionAuthority
    ) async throws -> VoiceControlReceipt {
        VoiceControlReceipt(status: .verified)
    }
}

private actor FailingObserveAdapter: VoiceControlAdapter {
    func observe() async throws -> VoiceControlSnapshot {
        throw NativeVoiceControlError.noWindow
    }
    func execute(
        action: VoiceControlAction, snapshot: VoiceControlSnapshot, authority: ActionAuthority
    ) async throws -> VoiceControlReceipt {
        VoiceControlReceipt(status: .verified)
    }
}
