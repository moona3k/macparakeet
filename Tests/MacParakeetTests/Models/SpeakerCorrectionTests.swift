import XCTest
@testable import MacParakeetCore

final class SpeakerCorrectionTests: XCTestCase {
    func testCommandPayloadUsesVersionedStableShapeAndRoundTrips() throws {
        let target = SpeakerCorrectionTarget(
            anchorTranscriptSegmentIDs: [UUID()],
            wordRange: .init(startIndex: 2, endIndexExclusive: 5)
        )
        let commands: [SpeakerCorrectionCommand] = [
            .rename(speakerID: "S1", label: "Alice"),
            .add(speaker: .init(id: "user:\(UUID().uuidString)", label: "Bob"), assigning: [target]),
            .assign(targets: [target], to: .unassigned),
            .split(target: target, atWordIndex: 3),
            .removeSplit(
                boundary: .init(target: target, wordIndex: 3),
                joinedAssignment: .speaker(id: "S1")
            ),
            .merge(sourceSpeakerID: "S2", targetSpeakerID: "S1"),
            .remove(speakerID: "S2", reassignTo: .unassigned),
            .reset,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        for command in commands {
            let data = try encoder.encode(command)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["version"] as? Int, 1)
            XCTAssertNotNil(object["kind"] as? String)
            XCTAssertEqual(try decoder.decode(SpeakerCorrectionCommand.self, from: data), command)
        }
    }

    func testUnsupportedPayloadVersionIsRejected() {
        let data = Data(#"{"version":2,"kind":"reset"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SpeakerCorrectionCommand.self, from: data))
    }

    func testOperationMatchesCommandKind() {
        XCTAssertEqual(
            SpeakerCorrectionCommand.removeSplit(
                boundary: .init(
                    target: .init(
                        anchorTranscriptSegmentIDs: [],
                        wordRange: .init(startIndex: 0, endIndexExclusive: 2)
                    ),
                    wordIndex: 1
                ),
                joinedAssignment: nil
            ).operation, .unsplit)
    }
}
