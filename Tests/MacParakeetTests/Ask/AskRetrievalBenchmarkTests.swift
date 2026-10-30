import Foundation
import XCTest
@testable import MacParakeetCore

final class AskRetrievalBenchmarkTests: XCTestCase {
    func testSyntheticRetrievalBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MACPARAKEET_ASK_BENCHMARK"] == "1" else {
            throw XCTSkip("Development benchmark; set MACPARAKEET_ASK_BENCHMARK=1 to run")
        }
        for size in [10_000, 50_000] {
            let manager = try DatabaseManager()
            let repository = TranscriptionRepository(dbQueue: manager.dbQueue)
            let service = AskSourceService(dbQueue: manager.dbQueue)
            var ids: [UUID] = []
            for sourceIndex in 0..<32 {
                let count = size / 32 + (sourceIndex < size % 32 ? 1 : 0)
                let source = Transcription(
                    fileName: "Synthetic \(sourceIndex)",
                    transcriptSegments: (0..<count).map { n in
                        TranscriptSegmentRecord(
                            startMs: n * 1_000, endMs: (n + 1) * 1_000,
                            speakerId: nil, speakerLabel: "Speaker",
                            text: n == count - 1
                                ? "The telescope launch moved to October 24."
                                : "Launch planning covered documentation, packaging, support readiness, testing and routine administration.",
                            wordRange: TranscriptSegmentWordRange(startIndex: n, endIndexExclusive: n + 1))
                    }, status: .completed, sourceType: .meeting)
                try repository.save(source)
                ids.append(source.id)
            }
            let snapshots = try service.snapshot(sourceIDs: ids)
            XCTAssertEqual(snapshots.reduce(0) { $0 + $1.passageCount }, size)
            let revisions = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.descriptor.id, $0.revision) })
            for query in ["telescope", "launch", "日期 launch"] {
                var samples: [Double] = []
                for _ in 0..<5 {
                    let start = Date()
                    let hits = try service.search(query: query, sourceRevisions: revisions, limit: 12)
                    samples.append(Date().timeIntervalSince(start))
                    XCTAssertEqual(hits.count, 12)
                }
                print("RETRIEVAL_BENCH size=\(size) sources=32 query=\(query) seconds=\(samples)")
            }
        }
    }
}
