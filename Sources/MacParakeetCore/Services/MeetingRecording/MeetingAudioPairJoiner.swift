import Foundation

struct MeetingAudioPair: Sendable, Equatable {
    let microphoneSamples: [Float]
    let systemSamples: [Float]
    let microphoneHostTime: UInt64?
    let systemHostTime: UInt64?
    let hasMicrophoneSignal: Bool
    let hasSystemSignal: Bool
}

struct MeetingAudioJoinerDiagnostic: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case queueOverflow(source: AudioSource, droppedFrames: Int, queueDepth: Int)
    }

    let kind: Kind
}

struct MeetingAudioPairJoiner {
    private struct QueuedSamples {
        let samples: [Float]
        let hostTime: UInt64?
    }

    private struct SampleQueue {
        private var storage: [QueuedSamples] = []
        private var headIndex: Int = 0

        var count: Int {
            storage.count - headIndex
        }

        var isEmpty: Bool {
            count == 0
        }

        var first: QueuedSamples? {
            guard headIndex < storage.count else { return nil }
            return storage[headIndex]
        }

        mutating func append(_ queued: QueuedSamples) {
            storage.append(queued)
        }

        mutating func prepend(_ queued: QueuedSamples) {
            compactIfNeeded(force: true)
            storage.insert(queued, at: headIndex)
        }

        mutating func popFirst() -> QueuedSamples? {
            guard headIndex < storage.count else { return nil }
            let queued = storage[headIndex]
            headIndex += 1
            compactIfNeeded()
            return queued
        }

        mutating func dropOldest(_ countToDrop: Int) {
            guard countToDrop > 0 else { return }
            let clamped = min(countToDrop, count)
            guard clamped > 0 else { return }
            headIndex += clamped
            compactIfNeeded(force: count == 0)
        }

        mutating func removeAll(keepingCapacity: Bool) {
            headIndex = 0
            if keepingCapacity {
                storage.removeAll(keepingCapacity: true)
            } else {
                storage = []
            }
        }

        func totalSampleCount() -> Int {
            guard !isEmpty else { return 0 }
            var total = 0
            for index in headIndex..<storage.count {
                total += storage[index].samples.count
            }
            return total
        }

        private mutating func compactIfNeeded(force: Bool = false) {
            guard headIndex > 0 else { return }
            if force || (headIndex >= 64 && headIndex * 2 >= storage.count) {
                storage.removeFirst(headIndex)
                headIndex = 0
            }
        }
    }

    static let maxLag = 4
    private static let defaultSampleRate = 16_000
    private static let maxLagDurationSeconds = 1
    private static let maxQueueSize = 30

    private let maxLagSamples: Int
    private var microphoneQueue = SampleQueue()
    private var systemQueue = SampleQueue()
    private var activeSoloSource: AudioSource?
    private var diagnostics: [MeetingAudioJoinerDiagnostic] = []

    init(sampleRate: Int = Self.defaultSampleRate) {
        self.maxLagSamples = max(sampleRate, 1) * Self.maxLagDurationSeconds
    }

    mutating func reset() {
        microphoneQueue.removeAll(keepingCapacity: true)
        systemQueue.removeAll(keepingCapacity: true)
        activeSoloSource = nil
        diagnostics.removeAll(keepingCapacity: true)
    }

    mutating func push(samples: [Float], hostTime: UInt64?, source: AudioSource) {
        guard !samples.isEmpty else { return }
        if let activeSoloSource, activeSoloSource != source {
            self.activeSoloSource = nil
        }
        switch source {
        case .microphone:
            microphoneQueue.append(QueuedSamples(samples: samples, hostTime: hostTime))
            let dropped = Self.trimQueueIfNeeded(&microphoneQueue)
            if dropped > 0 {
                diagnostics.append(
                    MeetingAudioJoinerDiagnostic(
                        kind: .queueOverflow(source: .microphone, droppedFrames: dropped, queueDepth: microphoneQueue.count)
                    )
                )
            }
        case .system:
            systemQueue.append(QueuedSamples(samples: samples, hostTime: hostTime))
            let dropped = Self.trimQueueIfNeeded(&systemQueue)
            if dropped > 0 {
                diagnostics.append(
                    MeetingAudioJoinerDiagnostic(
                        kind: .queueOverflow(source: .system, droppedFrames: dropped, queueDepth: systemQueue.count)
                    )
                )
            }
        }
    }

    mutating func drainPairs() -> [MeetingAudioPair] {
        var pairs: [MeetingAudioPair] = []
        while let pair = popPair() {
            pairs.append(pair)
        }
        return pairs
    }

    mutating func flushRemainingPairs() -> [MeetingAudioPair] {
        var pairs: [MeetingAudioPair] = []
        while let pair = popPairWhenFlushing() {
            pairs.append(pair)
        }
        return pairs
    }

    mutating func drainDiagnostics() -> [MeetingAudioJoinerDiagnostic] {
        guard !diagnostics.isEmpty else { return [] }
        let drained = diagnostics
        diagnostics.removeAll(keepingCapacity: true)
        return drained
    }

    private mutating func popPair() -> MeetingAudioPair? {
        if microphoneQueue.first != nil, systemQueue.first != nil,
           let microphone = microphoneQueue.popFirst(),
           let system = systemQueue.popFirst() {
            let frameCount = min(microphone.samples.count, system.samples.count)
            guard frameCount > 0 else { return nil }

            if microphone.samples.count > frameCount {
                microphoneQueue.prepend(
                    QueuedSamples(
                        samples: Array(microphone.samples.dropFirst(frameCount)),
                        hostTime: nil
                    )
                )
            }
            if system.samples.count > frameCount {
                systemQueue.prepend(
                    QueuedSamples(
                        samples: Array(system.samples.dropFirst(frameCount)),
                        hostTime: nil
                    )
                )
            }

            activeSoloSource = nil
            return MeetingAudioPair(
                microphoneSamples: Array(microphone.samples.prefix(frameCount)),
                systemSamples: Array(system.samples.prefix(frameCount)),
                microphoneHostTime: microphone.hostTime,
                systemHostTime: system.hostTime,
                hasMicrophoneSignal: true,
                hasSystemSignal: true
            )
        }

        if let microphone = microphoneQueue.first,
           systemQueue.isEmpty,
           (activeSoloSource == .microphone
            || microphoneQueue.count > Self.maxLag
            || queuedSampleCount(in: microphoneQueue) > maxLagSamples) {
            _ = microphoneQueue.popFirst()
            activeSoloSource = .microphone
            return MeetingAudioPair(
                microphoneSamples: microphone.samples,
                systemSamples: Array(repeating: 0, count: microphone.samples.count),
                microphoneHostTime: microphone.hostTime,
                systemHostTime: nil,
                hasMicrophoneSignal: true,
                hasSystemSignal: false
            )
        }

        if let system = systemQueue.first,
           microphoneQueue.isEmpty,
           (activeSoloSource == .system
            || systemQueue.count > Self.maxLag
            || queuedSampleCount(in: systemQueue) > maxLagSamples) {
            _ = systemQueue.popFirst()
            activeSoloSource = .system
            return MeetingAudioPair(
                microphoneSamples: Array(repeating: 0, count: system.samples.count),
                systemSamples: system.samples,
                microphoneHostTime: nil,
                systemHostTime: system.hostTime,
                hasMicrophoneSignal: false,
                hasSystemSignal: true
            )
        }

        return nil
    }

    private mutating func popPairWhenFlushing() -> MeetingAudioPair? {
        if let pair = popPair() {
            return pair
        }

        if let microphone = microphoneQueue.first {
            _ = microphoneQueue.popFirst()
            activeSoloSource = .microphone
            return MeetingAudioPair(
                microphoneSamples: microphone.samples,
                systemSamples: Array(repeating: 0, count: microphone.samples.count),
                microphoneHostTime: microphone.hostTime,
                systemHostTime: nil,
                hasMicrophoneSignal: true,
                hasSystemSignal: false
            )
        }

        if let system = systemQueue.first {
            _ = systemQueue.popFirst()
            activeSoloSource = .system
            return MeetingAudioPair(
                microphoneSamples: Array(repeating: 0, count: system.samples.count),
                systemSamples: system.samples,
                microphoneHostTime: nil,
                systemHostTime: system.hostTime,
                hasMicrophoneSignal: false,
                hasSystemSignal: true
            )
        }

        return nil
    }

    private static func trimQueueIfNeeded(_ queue: inout SampleQueue) -> Int {
        guard queue.count > Self.maxQueueSize else { return 0 }
        let dropped = queue.count - Self.maxQueueSize
        queue.dropOldest(dropped)
        return dropped
    }

    private func queuedSampleCount(in queue: SampleQueue) -> Int {
        queue.totalSampleCount()
    }

}
