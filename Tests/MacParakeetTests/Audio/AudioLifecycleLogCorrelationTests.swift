import Foundation
import XCTest
@testable import MacParakeetCore

final class AudioLifecycleLogCorrelationTests: XCTestCase {
    override func tearDown() {
        Observability.resetCaptureCorrelation()
        super.tearDown()
    }

    func testDefaultLifecycleSinkPreservesSnapshotWorkflowWithoutAmbientDuplicate() async throws {
        let scopes: [AudioEngineLifecycleSnapshot.Scope?] = [nil, .sharedSubscriptionQueue]
        for scope in scopes {
            let meeting = ObservabilityCaptureCorrelation(workflowID: UUID().uuidString, consumer: .meeting)
            Observability.beginCaptureCorrelation(meeting)
            let recorder = AudioEngineLifecycleDiagnostics(
                operation: .start, scope: scope, vpioEnabled: false, bufferSize: 1024,
                slowThreshold: 0, now: { 0 }, automaticallySchedule: false
            )
            let dictation = ObservabilityCaptureCorrelation(workflowID: UUID().uuidString, consumer: .dictation)
            Observability.beginCaptureCorrelation(dictation)
            Observability.endCaptureCorrelation(workflowID: meeting.workflowID)

            recorder.finish()
            await recorder.flushPendingEmissions()
            await AudioCaptureDiagnostics.flushPendingAppends()

            let logURL = AudioCaptureDiagnostics.diagnosticLogURL()
            XCTAssertTrue(logURL.path.contains("MacParakeetTests/Logs"))
            let contents = try String(contentsOf: logURL, encoding: .utf8)
            let matching = contents.split(separator: "\n").filter {
                $0.contains("audio_engine_lifecycle ") && $0.contains("workflow_id=\(meeting.workflowID)")
            }
            XCTAssertEqual(matching.count, 1)
            let line = try XCTUnwrap(matching.first)
            let fields = line.split(whereSeparator: \.isWhitespace)
            XCTAssertEqual(fields.filter { $0.hasPrefix("workflow_id=") }, ["workflow_id=\(meeting.workflowID)"])
            XCTAssertEqual(fields.filter { $0.hasPrefix("consumer=") }, ["consumer=meeting"])
            XCTAssertFalse(line.contains(dictation.workflowID))
            Observability.resetCaptureCorrelation()
        }
    }

    func testOrdinaryAsyncLogStillCapturesWorkflowAtEnqueue() async throws {
        let meeting = ObservabilityCaptureCorrelation(workflowID: UUID().uuidString, consumer: .meeting)
        Observability.beginCaptureCorrelation(meeting)
        let marker = "unit_test_async_correlation_\(UUID().uuidString)"
        AudioCaptureDiagnostics.appendAsync(marker)
        let dictation = ObservabilityCaptureCorrelation(workflowID: UUID().uuidString, consumer: .dictation)
        Observability.beginCaptureCorrelation(dictation)
        Observability.endCaptureCorrelation(workflowID: meeting.workflowID)
        await AudioCaptureDiagnostics.flushPendingAppends()

        let contents = try String(contentsOf: AudioCaptureDiagnostics.diagnosticLogURL(), encoding: .utf8)
        let line = try XCTUnwrap(contents.split(separator: "\n").first { $0.contains(marker) })
        let fields = line.split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(fields.filter { $0.hasPrefix("workflow_id=") }, ["workflow_id=\(meeting.workflowID)"])
        XCTAssertEqual(fields.filter { $0.hasPrefix("consumer=") }, ["consumer=meeting"])
        XCTAssertFalse(line.contains(dictation.workflowID))
    }
}
