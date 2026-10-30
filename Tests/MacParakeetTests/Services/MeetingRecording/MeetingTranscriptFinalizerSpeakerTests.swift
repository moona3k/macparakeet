import XCTest
@testable import MacParakeetCore

/// System-track words that no diarized cluster claims (#1228).
final class MeetingTranscriptFinalizerSpeakerTests: XCTestCase {
    private let clusters = [
        SpeakerInfo(id: "system:S1", label: "Others 1"),
        SpeakerInfo(id: "system:S2", label: "Others 2"),
    ]

    func testUncoveredWordBetweenOneClusterJoinsThatCluster() {
        let finalized = finalize(
            systemWords: [
                TimestampedWord(word: "we", startMs: 0, endMs: 200, confidence: 0.9),
                TimestampedWord(word: "can", startMs: 400, endMs: 600, confidence: 0.9),
                TimestampedWord(word: "start", startMs: 800, endMs: 1_000, confidence: 0.9),
            ],
            segments: [
                SpeakerSegment(speakerId: "system:S1", startMs: 0, endMs: 300),
                SpeakerSegment(speakerId: "system:S1", startMs: 700, endMs: 1_100),
            ]
        )

        XCTAssertEqual(finalized.words.map(\.speakerId), ["system:S1", "system:S1", "system:S1"])
        XCTAssertEqual(finalized.speakers, [SpeakerInfo(id: "system:S1", label: "Others 1")])
    }

    func testUncoveredWordBetweenTwoClustersIsUnattributedAndNotCounted() {
        let finalized = finalize(
            systemWords: [
                TimestampedWord(word: "yes", startMs: 0, endMs: 200, confidence: 0.9),
                TimestampedWord(word: "so", startMs: 400, endMs: 600, confidence: 0.9),
                TimestampedWord(word: "right", startMs: 800, endMs: 1_000, confidence: 0.9),
            ],
            segments: [
                SpeakerSegment(speakerId: "system:S1", startMs: 0, endMs: 300),
                SpeakerSegment(speakerId: "system:S2", startMs: 700, endMs: 1_100),
            ]
        )

        XCTAssertEqual(finalized.words.map(\.speakerId), ["system:S1", "system", "system:S2"])
        XCTAssertEqual(
            finalized.speakers,
            [
                SpeakerInfo(id: "system", label: "Unattributed"),
                SpeakerInfo(id: "system:S1", label: "Others 1"),
                SpeakerInfo(id: "system:S2", label: "Others 2"),
            ])
        XCTAssertEqual(SpeakerInfo.participants(in: finalized.speakers).map(\.id), ["system:S1", "system:S2"])
    }

    /// Before the uncovered system word the transcript has a `Me` turn. The
    /// word must stay on the system track instead of reading as the user's.
    func testUncoveredWordAfterMicrophoneTurnStaysOnSystemTrack() {
        let finalized = finalize(
            microphoneWords: [
                TimestampedWord(word: "okay", startMs: 300, endMs: 500, confidence: 0.9)
            ],
            systemWords: [
                TimestampedWord(word: "thanks", startMs: 0, endMs: 200, confidence: 0.9),
                TimestampedWord(word: "bye", startMs: 700, endMs: 900, confidence: 0.9),
            ],
            segments: [
                SpeakerSegment(speakerId: "system:S1", startMs: 0, endMs: 250)
            ]
        )

        XCTAssertEqual(finalized.words.map(\.speakerId), ["system:S1", "microphone", "system"])
        XCTAssertEqual(finalized.speakers.map(\.label), ["Me", "Unattributed", "Others 1"])
        XCTAssertEqual(SpeakerInfo.participants(in: finalized.speakers).map(\.label), ["Me", "Others 1"])
    }

    func testSystemTrackWithoutDiarizationKeepsOthers() {
        let finalized = finalize(
            systemWords: [
                TimestampedWord(word: "hello", startMs: 0, endMs: 200, confidence: 0.9)
            ],
            segments: nil
        )

        XCTAssertEqual(finalized.words.map(\.speakerId), ["system"])
        XCTAssertEqual(finalized.speakers, [SpeakerInfo(id: "system", label: "Others")])
        XCTAssertEqual(SpeakerInfo.participants(in: finalized.speakers).count, 1)
    }

    func testSystemTrackWhenNoClusterWinsAWordKeepsOthers() {
        let finalized = finalize(
            systemWords: [
                TimestampedWord(word: "hello", startMs: 1_000, endMs: 1_200, confidence: 0.9)
            ],
            segments: [
                SpeakerSegment(speakerId: "system:S1", startMs: 0, endMs: 500)
            ]
        )

        XCTAssertEqual(finalized.words.map(\.speakerId), ["system"])
        XCTAssertEqual(finalized.speakers, [SpeakerInfo(id: "system", label: "Others")])
    }

    /// Rows saved before #1228 label the bucket "Others", and users can rename
    /// it, so counting must not depend on the label.
    func testCountedSpeakersExcludesLegacyAndRenamedBucketBesideClusters() {
        let legacy = [
            SpeakerInfo(id: "microphone", label: "Me"),
            SpeakerInfo(id: "system", label: "Others"),
            SpeakerInfo(id: "system:S1", label: "Others 1"),
            SpeakerInfo(id: "user:6F9619FF-8B86-D011-B42D-00CF4FC964FF", label: "Dana"),
        ]
        XCTAssertEqual(
            SpeakerInfo.participants(in: legacy).map(\.label),
            ["Me", "Others 1", "Dana"]
        )

        var renamed = legacy
        renamed[1].label = "Room"
        XCTAssertEqual(SpeakerInfo.participants(in: renamed).count, 3)
    }

    /// Merging every cluster into a manual speaker removes the `system:` ids;
    /// the bucket must still not count as a person.
    func testUnattributedBucketStaysUncountedAfterLastClusterIsMerged() {
        let merged = [
            SpeakerInfo(id: "microphone", label: "Me"),
            SpeakerInfo(id: "system", label: "Unattributed"),
            SpeakerInfo(id: "user:6F9619FF-8B86-D011-B42D-00CF4FC964FF", label: "Dana"),
        ]
        XCTAssertEqual(SpeakerInfo.participants(in: merged).map(\.label), ["Me", "Dana"])

        // Without diarization, `Others` beside a manual speaker is still everyone else.
        var undiarized = merged
        undiarized[1].label = "Others"
        XCTAssertEqual(SpeakerInfo.participants(in: undiarized).count, 3)
    }

    private func finalize(
        microphoneWords: [TimestampedWord] = [],
        systemWords: [TimestampedWord],
        segments: [SpeakerSegment]?
    ) -> MeetingTranscriptFinalizer.FinalizedTranscript {
        var sources: [MeetingTranscriptFinalizer.SourceTranscript] = []
        if !microphoneWords.isEmpty {
            sources.append(
                .init(
                    source: .microphone,
                    result: STTResult(text: microphoneWords.map(\.word).joined(separator: " "), words: microphoneWords),
                    startOffsetMs: 0
                ))
        }
        sources.append(
            .init(
                source: .system,
                result: STTResult(text: systemWords.map(\.word).joined(separator: " "), words: systemWords),
                startOffsetMs: 0
            ))
        return MeetingTranscriptFinalizer.finalize(
            sourceTranscripts: sources,
            systemDiarization: segments.map {
                MeetingTranscriptFinalizer.SystemDiarization(speakers: clusters, segments: $0)
            }
        )
    }
}
