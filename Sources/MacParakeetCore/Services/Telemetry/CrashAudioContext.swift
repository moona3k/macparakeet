import MacParakeetObjCShims

/// Numeric, content-free transitions recorded only from normal lifecycle code.
/// Never call this adapter from a render/buffer callback or a fatal handler.
/// Records are history, not authoritative current state: an older attempt can
/// finish after a newer attempt enters the native queue.
enum CrashAudioContext {
    enum Kind: UInt8, CaseIterable, Sendable {
        case phase = 1, attempt, finish, teardown, recovery, workflowChange
    }

    enum Operation: UInt8, CaseIterable, Sendable {
        case start, prepare, recovery, stop
    }

    enum Phase: UInt8, CaseIterable, Sendable {
        case none, queueWait, routeResolution, setDevice, inputNode, voiceProcessing
        case ducking, inputFormat, installTap, prepareEngine, startEngine, firstBuffer
        case validateRoute, teardown, ready, removeTap, stopEngine, disableVoiceProcessing, replaceEngine
    }

    enum Transport: UInt8, CaseIterable, Sendable {
        case unknown, none, builtIn, bluetooth, bluetoothLE, usb, aggregate, virtual
        case aggregateBuiltIn, aggregateBluetooth, aggregateBluetoothLE, aggregateUSB
        case aggregateAggregate, aggregateVirtual, aggregateUnknown

        init(label: String) {
            switch label {
            case "none": self = .none
            case "built-in": self = .builtIn
            case "bluetooth": self = .bluetooth
            case "bluetooth-le": self = .bluetoothLE
            case "usb": self = .usb
            case "aggregate": self = .aggregate
            case "virtual": self = .virtual
            case "aggregate-built-in": self = .aggregateBuiltIn
            case "aggregate-bluetooth": self = .aggregateBluetooth
            case "aggregate-bluetooth-le": self = .aggregateBluetoothLE
            case "aggregate-usb": self = .aggregateUSB
            case "aggregate-aggregate": self = .aggregateAggregate
            case "aggregate-virtual": self = .aggregateVirtual
            case "aggregate-unknown": self = .aggregateUnknown
            default: self = .unknown
            }
        }
    }

    enum Outcome: UInt8, CaseIterable, Sendable {
        case pending, success, failure, cancelled
    }

    enum Reason: UInt8, CaseIterable, Sendable {
        case none, configurationChange, callbackStall, invalidBuffers, failedAttempt, explicitStop, backoff, routeChange

        init(trigger: String) {
            switch trigger {
            case "configuration_change": self = .configurationChange
            case "callback_stall": self = .callbackStall
            case "invalid_buffers": self = .invalidBuffers
            case "backoff": self = .backoff
            case "route_change": self = .routeChange
            default: self = .none
            }
        }
    }

    /// Stable context schema 1 payload:
    /// kind[0:2], operation[3:4], phase[5:9], transport[10:13],
    /// outcome[14:16], reason[17:19], workflow mask[20:21],
    /// reserved zero[22:31], process-local attempt token[32:63].
    /// The mask is meaningful only for workflowChange records. Token zero is
    /// reserved for those records; allocation exhaustion omits native records.
    struct Record: Equatable, Sendable {
        let kind: Kind
        let operation: Operation
        let phase: Phase
        let transport: Transport
        let outcome: Outcome
        let reason: Reason
        let registeredConsumers: UInt8
        let attempt: UInt32

        init(
            kind: Kind,
            operation: Operation = .start,
            phase: Phase = .none,
            transport: Transport = .unknown,
            outcome: Outcome = .pending,
            reason: Reason = .none,
            registeredConsumers: UInt8 = 0,
            attempt: UInt32
        ) {
            self.kind = kind
            self.operation = operation
            self.phase = phase
            self.transport = transport
            self.outcome = outcome
            self.reason = reason
            self.registeredConsumers = registeredConsumers & 3
            self.attempt = attempt
        }

        var packed: UInt64 {
            UInt64(kind.rawValue)
                | (UInt64(operation.rawValue) << 3)
                | (UInt64(phase.rawValue) << 5)
                | (UInt64(transport.rawValue) << 10)
                | (UInt64(outcome.rawValue) << 14)
                | (UInt64(reason.rawValue) << 17)
                | (UInt64(registeredConsumers) << 20)
                | (UInt64(attempt) << 32)
        }

        /// Strict numeric decoding for diagnostics/tests, never the fatal path.
        init?(packed: UInt64) {
            guard packed & 0xFFC0_0000 == 0,
                let kind = Kind(rawValue: UInt8(packed & 7)),
                let operation = Operation(rawValue: UInt8((packed >> 3) & 3)),
                let phase = Phase(rawValue: UInt8((packed >> 5) & 31)),
                let transport = Transport(rawValue: UInt8((packed >> 10) & 15)),
                let outcome = Outcome(rawValue: UInt8((packed >> 14) & 7)),
                let reason = Reason(rawValue: UInt8((packed >> 17) & 7))
            else { return nil }
            let attempt = UInt32(packed >> 32)
            let consumers = UInt8((packed >> 20) & 3)
            guard kind == .workflowChange ? attempt == 0 : (attempt != 0 && consumers == 0) else {
                return nil
            }
            self.init(
                kind: kind, operation: operation, phase: phase, transport: transport,
                outcome: outcome, reason: reason, registeredConsumers: consumers, attempt: attempt
            )
        }
    }

    static func nextAttempt() -> UInt32 {
        MPKNextCrashAttempt()
    }

    static func record(_ record: Record) {
        guard record.attempt != 0 || record.kind == .workflowChange else { return }
        MPKRecordCrashBreadcrumb(record.packed)
    }

    /// Call under the existing workflow registry lock. Mask publication does
    /// not depend on successful ring insertion when another writer contends.
    static func setRegisteredConsumers(_ mask: UInt8) {
        let mask = mask & 3
        MPKSetCrashRegisteredConsumers(UInt32(mask))
        record(Record(kind: .workflowChange, registeredConsumers: mask, attempt: 0))
    }
}

extension CrashAudioContext.Operation {
    init(_ operation: AudioEngineLifecycleSnapshot.Operation) {
        switch operation {
        case .start: self = .start
        case .prepare: self = .prepare
        case .recovery: self = .recovery
        case .stop: self = .stop
        }
    }
}

extension CrashAudioContext.Phase {
    init(_ phase: AudioEngineLifecycleSnapshot.Phase) {
        switch phase {
        case .queueWait: self = .queueWait
        case .routeResolution: self = .routeResolution
        case .setDevice: self = .setDevice
        case .inputNode: self = .inputNode
        case .voiceProcessing: self = .voiceProcessing
        case .ducking: self = .ducking
        case .inputFormat: self = .inputFormat
        case .installTap: self = .installTap
        case .prepareEngine: self = .prepareEngine
        case .startEngine: self = .startEngine
        case .firstBuffer: self = .firstBuffer
        case .validateRoute: self = .validateRoute
        case .teardown: self = .teardown
        case .ready: self = .ready
        }
    }
}
