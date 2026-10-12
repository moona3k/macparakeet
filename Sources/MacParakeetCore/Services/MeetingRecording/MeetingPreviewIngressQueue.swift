import Foundation

/// Bounded queue of resampled samples waiting for live-preview ingest.
///
/// The capture consumer writes durable audio first, then enqueues only the
/// preview copy. When preview work falls behind, further preview batches are
/// refused so the capture stream can keep draining. Refused audio is already
/// in the source file; final transcription reads that file. Live preview is
/// the only thing skipped, and the catching-up notice covers that gap.
struct MeetingPreviewIngressQueue: Sendable {
    struct Batch: Sendable, Equatable {
        var source: AudioSource
        var samples: [Float]
        var hostTime: UInt64?
        /// Level captured with the file write. Applied when this batch is
        /// previewed so speaker-dominance checks stay in preview order.
        var bufferRms: Float

        var byteCount: Int {
            samples.count * MemoryLayout<Float>.stride
        }
    }

    /// About two minutes of 16 kHz mono Float32, shared by both sources.
    /// This caps preview memory. It is not a limit on the saved recording.
    static let defaultMaxRetainedBytes = 8 * 1024 * 1024

    /// Stop waits out a short preview tail. A larger backlog is discarded
    /// so an overloaded live preview cannot hold Stop open.
    static let stopDrainByteLimit = 1 * 1024 * 1024

    private(set) var retainedBytes = 0
    private(set) var droppedBatchCount = 0
    private(set) var droppedBytes = 0
    let maxRetainedBytes: Int

    private var batches: [Batch] = []
    private var readIndex = 0

    init(maxRetainedBytes: Int = MeetingPreviewIngressQueue.defaultMaxRetainedBytes) {
        self.maxRetainedBytes = max(0, maxRetainedBytes)
    }

    var isEmpty: Bool {
        readIndex >= batches.count
    }

    /// Returns false when the batch was refused. Empty batches are ignored
    /// and are not counted as drops.
    @discardableResult
    mutating func enqueue(_ batch: Batch) -> Bool {
        let bytes = batch.byteCount
        guard bytes > 0 else { return false }
        guard retainedBytes + bytes <= maxRetainedBytes else {
            droppedBatchCount += 1
            droppedBytes += bytes
            return false
        }
        batches.append(batch)
        retainedBytes += bytes
        return true
    }

    mutating func dequeue() -> Batch? {
        guard readIndex < batches.count else { return nil }
        let batch = batches[readIndex]
        batches[readIndex] = Batch(
            source: batch.source,
            samples: [],
            hostTime: nil,
            bufferRms: 0
        )
        readIndex += 1
        retainedBytes -= batch.byteCount
        if readIndex == batches.count {
            batches.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex > 64, readIndex * 2 > batches.count {
            batches.removeFirst(readIndex)
            readIndex = 0
        }
        return batch
    }

    /// Drops preview work that has not started. An in-flight batch already
    /// left the queue and is unaffected.
    mutating func discardPending() {
        while let batch = dequeue() {
            droppedBatchCount += 1
            droppedBytes += batch.byteCount
        }
    }
}
