import Foundation
import MacParakeetObjCShims
import os
import XCTest
@testable import MacParakeetCore

final class CrashAudioContextTests: XCTestCase {
    override func tearDown() {
        Observability.resetCaptureCorrelation()
        super.tearDown()
    }

    func testSchemaOneHasStableBitPositionsAndRejectsUnknownValues() {
        let record = CrashAudioContext.Record(
            kind: .teardown, operation: .recovery, phase: .replaceEngine,
            transport: .usb, outcome: .failure, reason: .failedAttempt,
            attempt: 0x1234_5678
        )
        // Keep each term typed: one long literal expression times out CI's type checker.
        let fields: [UInt64] = [4, 2 << 3, 18 << 5, 5 << 10, 2 << 14, 4 << 17, 0x1234_5678 << 32]
        let expected = fields.reduce(0, |)
        XCTAssertEqual(record.packed, expected)
        XCTAssertEqual(CrashAudioContext.Record(packed: expected), record)
        XCTAssertNil(CrashAudioContext.Record(packed: expected | (1 << 22)))
        XCTAssertNil(CrashAudioContext.Record(packed: (expected & ~7) | 7))
        XCTAssertNil(CrashAudioContext.Record(packed: (expected & ~(31 << 5)) | (31 << 5)))
        XCTAssertNil(CrashAudioContext.Record(packed: (expected & ~(15 << 10)) | (15 << 10)))
        XCTAssertNil(CrashAudioContext.Record(packed: (expected & ~(7 << 14)) | (7 << 14)))
        XCTAssertNil(CrashAudioContext.Record(packed: expected & 0xFFFF_FFFF))
        XCTAssertNil(CrashAudioContext.Record(packed: expected | (1 << 20)))
    }

    func testFiniteMappingsPreserveKnownCategoriesAndDropArbitraryLabels() {
        let known: [(String, CrashAudioContext.Transport)] = [
            ("unknown", .unknown), ("none", .none), ("built-in", .builtIn),
            ("bluetooth", .bluetooth), ("bluetooth-le", .bluetoothLE), ("usb", .usb),
            ("aggregate", .aggregate), ("virtual", .virtual), ("aggregate-built-in", .aggregateBuiltIn),
            ("aggregate-bluetooth", .aggregateBluetooth), ("aggregate-bluetooth-le", .aggregateBluetoothLE),
            ("aggregate-usb", .aggregateUSB), ("aggregate-aggregate", .aggregateAggregate),
            ("aggregate-virtual", .aggregateVirtual), ("aggregate-unknown", .aggregateUnknown),
        ]
        for (label, expected) in known {
            XCTAssertEqual(CrashAudioContext.Transport(label: label), expected)
        }
        XCTAssertEqual(CrashAudioContext.Transport(label: "private microphone name"), .unknown)
        XCTAssertEqual(CrashAudioContext.Reason(trigger: "private failure text"), .none)
        XCTAssertEqual(CrashAudioContext.Reason(trigger: "callback_stall"), .callbackStall)
        XCTAssertEqual(CrashAudioContext.Reason(trigger: "invalid_buffers"), .invalidBuffers)
        XCTAssertEqual(CrashAudioContext.Reason(trigger: "configuration_change"), .configurationChange)
        XCTAssertEqual(CrashAudioContext.Reason(trigger: "backoff"), .backoff)
        XCTAssertEqual(CrashAudioContext.Reason(trigger: "route_change"), .routeChange)
        for phase in AudioEngineLifecycleSnapshot.Phase.allCases {
            let record = CrashAudioContext.Record(kind: .phase, phase: .init(phase), attempt: 1)
            XCTAssertEqual(CrashAudioContext.Record(packed: record.packed), record)
        }
    }

    func testNativeAdapterWritesDecodablePayloadToRealBoundedRing() throws {
        let attempt = CrashAudioContext.nextAttempt()
        XCTAssertNotEqual(attempt, 0)
        for _ in 0..<40 {
            CrashAudioContext.record(.init(
                kind: .phase, operation: .start, phase: .startEngine, transport: .usb, attempt: attempt
            ))
        }
        let text = copiedContext()
        XCTAssertTrue(text.contains("crash_context_version: 1"))
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("breadcrumb: ") }
        XCTAssertLessThanOrEqual(lines.count, 32)
        let matching = lines.compactMap { line -> CrashAudioContext.Record? in
            guard let hex = line.split(separator: ",").last,
                let packed = UInt64(hex.dropFirst(2), radix: 16)
            else { return nil }
            return CrashAudioContext.Record(packed: packed)
        }.filter { $0.attempt == attempt }
        XCTAssertFalse(matching.isEmpty)
        XCTAssertTrue(matching.allSatisfy { $0.phase == .startEngine && $0.transport == .usb })
    }

    func testWorkflowMaskPreservesOverlapAndRejectsStaleCompletion() {
        let meeting = ObservabilityCaptureCorrelation(workflowID: UUID().uuidString, consumer: .meeting)
        let old = ObservabilityCaptureCorrelation(workflowID: UUID().uuidString, consumer: .dictation)
        let replacement = ObservabilityCaptureCorrelation(workflowID: UUID().uuidString, consumer: .dictation)
        Observability.resetCaptureCorrelation()
        XCTAssertTrue(copiedContext().contains("crash_registered_consumers: 0\n"))
        Observability.beginCaptureCorrelation(meeting)
        XCTAssertTrue(copiedContext().contains("crash_registered_consumers: 2\n"))
        Observability.beginCaptureCorrelation(old)
        Observability.beginCaptureCorrelation(replacement)
        Observability.endCaptureCorrelation(workflowID: old.workflowID)
        XCTAssertTrue(copiedContext().contains("crash_registered_consumers: 3\n"))
        Observability.endCaptureCorrelation(workflowID: replacement.workflowID)
        XCTAssertTrue(copiedContext().contains("crash_registered_consumers: 2\n"))
        Observability.endCaptureCorrelation(workflowID: meeting.workflowID)
        XCTAssertTrue(copiedContext().contains("crash_registered_consumers: 0\n"))
    }

    func testInitialAndScopedQueueWaitingNeverProduceNativeTransitions() {
        let output = CrashOutput()
        let idle = recorder(.prepare, output: output)
        idle.enter(.queueWait)
        idle.finish()
        XCTAssertTrue(output.records.isEmpty)

        let scoped = AudioEngineLifecycleDiagnostics(
            operation: .start, scope: .sharedSubscriptionQueue, vpioEnabled: false, bufferSize: 512,
            automaticallySchedule: false, crashSink: { output.append($0) }, sink: { _ in }
        )
        scoped.beginAttempt(source: "selected", transport: "usb", prepared: false)
        scoped.enter(.startEngine)
        scoped.finish()
        XCTAssertEqual(scoped.crashAttemptToken, 0)
        XCTAssertTrue(output.records.isEmpty)
    }

    func testUnchangedPhasesAndRepeatedFinishAreSuppressedWithoutChangingFastStopPolicy() async {
        let output = CrashOutput()
        let ordinary = OSAllocatedUnfairLock<[AudioEngineLifecycleSnapshot]>(initialState: [])
        let recorder = AudioEngineLifecycleDiagnostics(
            operation: .stop, vpioEnabled: false, bufferSize: 512,
            automaticallySchedule: false, crashSink: { output.append($0) },
            sink: { value in ordinary.withLock { $0.append(value) } }
        )
        recorder.enter(.teardown)
        recorder.enter(.teardown)
        recorder.recordCrashTeardown(.replaceEngine)
        recorder.finish()
        recorder.finish()
        recorder.enter(.ready)
        recorder.recordCrashRecovery(.backoff)
        await recorder.flushPendingEmissions()
        XCTAssertEqual(output.records.map(\.kind), [.phase, .teardown, .finish])
        XCTAssertEqual(output.records.last?.outcome, .success)
        XCTAssertTrue(ordinary.withLock { $0.isEmpty })
    }

    func testLateFinishRemainsTaggedWithOriginalAttemptAfterReplacementProgress() {
        let output = CrashOutput()
        let first = recorder(.start, output: output)
        let second = recorder(.recovery, output: output)
        first.beginAttempt(source: "selected", transport: "usb", prepared: false)
        first.enter(.startEngine)
        second.recordCrashRecovery(.callbackStall)
        second.beginAttempt(source: "built_in", transport: "built-in", prepared: false)
        second.enter(.firstBuffer)
        first.finish(error: CancellationError())
        let events = output.records
        XCTAssertNotEqual(first.crashAttemptToken, second.crashAttemptToken)
        XCTAssertEqual(events.last?.attempt, first.crashAttemptToken)
        XCTAssertEqual(events.last?.outcome, .cancelled)
        XCTAssertEqual(events.last?.transport, .usb)
        let newer = events.filter { $0.attempt == second.crashAttemptToken }
        XCTAssertEqual(newer.first?.reason, .callbackStall)
        XCTAssertEqual(newer.last?.phase, .firstBuffer)
        XCTAssertEqual(newer.last?.transport, .builtIn)
        XCTAssertFalse(newer.contains { $0.kind == .finish })
    }

    private func recorder(
        _ operation: AudioEngineLifecycleSnapshot.Operation,
        output: CrashOutput
    ) -> AudioEngineLifecycleDiagnostics {
        AudioEngineLifecycleDiagnostics(
            operation: operation, vpioEnabled: false, bufferSize: 512,
            automaticallySchedule: false, crashSink: { output.append($0) }, sink: { _ in }
        )
    }

    private func copiedContext() -> String {
        var bytes = [CChar](repeating: 0, count: 4_096)
        let count = bytes.withUnsafeMutableBufferPointer {
            MPKCopyCrashContext($0.baseAddress, $0.count)
        }
        return String(decoding: bytes.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private final class CrashOutput: @unchecked Sendable {
    private let values = OSAllocatedUnfairLock<[CrashAudioContext.Record]>(initialState: [])
    var records: [CrashAudioContext.Record] { values.withLock { $0 } }
    func append(_ record: CrashAudioContext.Record) { values.withLock { $0.append(record) } }
}
