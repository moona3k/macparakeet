import XCTest
@testable import MacParakeetCore

final class MeetingTranscriptNoiseFilterTests: XCTestCase {
    func testFinalizeDropsFillerOnlyMicrophoneRuns() {
        let finalized = MeetingTranscriptFinalizer.finalize(sourceTranscripts: [
            .init(
                source: .microphone,
                result: STTResult(
                    text: "Uh uh",
                    words: [
                        TimestampedWord(word: "Uh", startMs: 0, endMs: 120, confidence: 0.92),
                        TimestampedWord(word: "uh", startMs: 180, endMs: 300, confidence: 0.90),
                    ]
                ),
                startOffsetMs: 0
            ),
            .init(
                source: .system,
                result: STTResult(
                    text: "lecture content",
                    words: [
                        TimestampedWord(word: "lecture", startMs: 0, endMs: 240, confidence: 0.95),
                        TimestampedWord(word: "content", startMs: 280, endMs: 560, confidence: 0.95),
                    ]
                ),
                startOffsetMs: 0
            ),
        ])

        XCTAssertEqual(finalized.words.map(\.word), ["lecture", "content"])
        XCTAssertEqual(finalized.words.map(\.speakerId), ["system", "system"])
        XCTAssertEqual(finalized.speakers, [
            SpeakerInfo(id: "system", label: "Others"),
        ])
        XCTAssertEqual(finalized.rawTranscript, "lecture content")
    }

    func testFinalizeDropsLowConfidenceMicDuplicateOfSystemRun() {
        let finalized = MeetingTranscriptFinalizer.finalize(sourceTranscripts: [
            .init(
                source: .microphone,
                result: STTResult(
                    text: "account information",
                    words: [
                        TimestampedWord(word: "account", startMs: 80, endMs: 220, confidence: 0.48),
                        TimestampedWord(word: "information", startMs: 240, endMs: 480, confidence: 0.50),
                    ]
                ),
                startOffsetMs: 0
            ),
            .init(
                source: .system,
                result: STTResult(
                    text: "account information",
                    words: [
                        TimestampedWord(word: "account", startMs: 0, endMs: 140, confidence: 0.93),
                        TimestampedWord(word: "information", startMs: 160, endMs: 400, confidence: 0.93),
                    ]
                ),
                startOffsetMs: 0
            ),
        ])

        XCTAssertEqual(finalized.words.map(\.speakerId), ["system", "system"])
        XCTAssertEqual(finalized.rawTranscript, "account information")
    }

    func testFinalizePreservesHighConfidenceOverlappingMicSpeech() {
        let finalized = MeetingTranscriptFinalizer.finalize(sourceTranscripts: [
            .init(
                source: .microphone,
                result: STTResult(
                    text: "Can you hear me",
                    words: [
                        TimestampedWord(word: "Can", startMs: 120, endMs: 220, confidence: 0.90),
                        TimestampedWord(word: "you", startMs: 240, endMs: 320, confidence: 0.90),
                        TimestampedWord(word: "hear", startMs: 340, endMs: 450, confidence: 0.90),
                        TimestampedWord(word: "me", startMs: 470, endMs: 540, confidence: 0.90),
                    ]
                ),
                startOffsetMs: 0
            ),
            .init(
                source: .system,
                result: STTResult(
                    text: "Can you hear me",
                    words: [
                        TimestampedWord(word: "Can", startMs: 0, endMs: 100, confidence: 0.90),
                        TimestampedWord(word: "you", startMs: 120, endMs: 200, confidence: 0.90),
                        TimestampedWord(word: "hear", startMs: 220, endMs: 330, confidence: 0.90),
                        TimestampedWord(word: "me", startMs: 350, endMs: 420, confidence: 0.90),
                    ]
                ),
                startOffsetMs: 0
            ),
        ])

        XCTAssertEqual(
            finalized.words.map(\.speakerId),
            ["system", "microphone", "system", "system", "microphone", "microphone", "system", "microphone"]
        )
    }

    /// Loud speaker playback transcribes confidently, so echo of a long
    /// remote utterance sails past the confidence-gated duplicate rule. A
    /// ≥5-word run matching the remote speaker's simultaneous words (with
    /// minor STT spelling variance) is echo regardless of confidence.
    func testFinalizeDropsLongHighConfidenceSimultaneousEcho() {
        let finalized = MeetingTranscriptFinalizer.finalize(sourceTranscripts: [
            .init(
                source: .microphone,
                result: STTResult(
                    text: "Let's finalize the budget numbers tomorrow",
                    words: [
                        TimestampedWord(word: "Let's", startMs: 200, endMs: 480, confidence: 0.92),
                        TimestampedWord(word: "finalize", startMs: 500, endMs: 900, confidence: 0.91),
                        TimestampedWord(word: "the", startMs: 920, endMs: 1_040, confidence: 0.93),
                        TimestampedWord(word: "budget", startMs: 1_060, endMs: 1_400, confidence: 0.90),
                        TimestampedWord(word: "numbers", startMs: 1_420, endMs: 1_780, confidence: 0.88),
                        TimestampedWord(word: "tomorrow", startMs: 1_800, endMs: 2_300, confidence: 0.92),
                    ]
                ),
                startOffsetMs: 0
            ),
            .init(
                source: .system,
                result: STTResult(
                    text: "Let's finalize the budget number tomorrow",
                    words: [
                        TimestampedWord(word: "Let's", startMs: 0, endMs: 280, confidence: 0.95),
                        TimestampedWord(word: "finalize", startMs: 300, endMs: 700, confidence: 0.95),
                        TimestampedWord(word: "the", startMs: 720, endMs: 840, confidence: 0.95),
                        TimestampedWord(word: "budget", startMs: 860, endMs: 1_200, confidence: 0.95),
                        TimestampedWord(word: "number", startMs: 1_220, endMs: 1_580, confidence: 0.95),
                        TimestampedWord(word: "tomorrow", startMs: 1_600, endMs: 2_100, confidence: 0.95),
                    ]
                ),
                startOffsetMs: 0
            ),
        ])

        XCTAssertEqual(finalized.words.map(\.speakerId), Array(repeating: "system", count: 6))
        XCTAssertEqual(finalized.rawTranscript, "Let's finalize the budget number tomorrow")
    }

    /// The same phrase repeated by the user AFTER the remote speaker finished
    /// is genuine speech (agreement, read-back), not echo — the simultaneity
    /// window must not reach it.
    func testFinalizePreservesDelayedRepetitionOfSystemPhrase() {
        let finalized = MeetingTranscriptFinalizer.finalize(sourceTranscripts: [
            .init(
                source: .microphone,
                result: STTResult(
                    text: "we ship the release on Friday",
                    words: [
                        TimestampedWord(word: "we", startMs: 4_000, endMs: 4_150, confidence: 0.92),
                        TimestampedWord(word: "ship", startMs: 4_170, endMs: 4_400, confidence: 0.91),
                        TimestampedWord(word: "the", startMs: 4_420, endMs: 4_520, confidence: 0.93),
                        TimestampedWord(word: "release", startMs: 4_540, endMs: 4_900, confidence: 0.90),
                        TimestampedWord(word: "on", startMs: 4_920, endMs: 5_000, confidence: 0.92),
                        TimestampedWord(word: "Friday", startMs: 5_020, endMs: 5_400, confidence: 0.94),
                    ]
                ),
                startOffsetMs: 0
            ),
            .init(
                source: .system,
                result: STTResult(
                    text: "we ship the release on Friday",
                    words: [
                        TimestampedWord(word: "we", startMs: 0, endMs: 150, confidence: 0.95),
                        TimestampedWord(word: "ship", startMs: 170, endMs: 400, confidence: 0.95),
                        TimestampedWord(word: "the", startMs: 420, endMs: 520, confidence: 0.95),
                        TimestampedWord(word: "release", startMs: 540, endMs: 900, confidence: 0.95),
                        TimestampedWord(word: "on", startMs: 920, endMs: 1_000, confidence: 0.95),
                        TimestampedWord(word: "Friday", startMs: 1_020, endMs: 1_400, confidence: 0.95),
                    ]
                ),
                startOffsetMs: 0
            ),
        ])

        XCTAssertEqual(
            finalized.words.filter { $0.speakerId == "microphone" }.count,
            6,
            "a repetition that starts seconds after the remote phrase ended is not simultaneous echo"
        )
    }

    func testFinalizePreservesSimultaneousDifferentSpeech() {
        let finalized = MeetingTranscriptFinalizer.finalize(sourceTranscripts: [
            .init(
                source: .microphone,
                result: STTResult(
                    text: "I think we should wait until Monday",
                    words: [
                        TimestampedWord(word: "I", startMs: 100, endMs: 180, confidence: 0.92),
                        TimestampedWord(word: "think", startMs: 200, endMs: 450, confidence: 0.91),
                        TimestampedWord(word: "we", startMs: 470, endMs: 580, confidence: 0.93),
                        TimestampedWord(word: "should", startMs: 600, endMs: 850, confidence: 0.90),
                        TimestampedWord(word: "wait", startMs: 870, endMs: 1_100, confidence: 0.92),
                        TimestampedWord(word: "until", startMs: 1_120, endMs: 1_350, confidence: 0.91),
                        TimestampedWord(word: "Monday", startMs: 1_370, endMs: 1_750, confidence: 0.94),
                    ]
                ),
                startOffsetMs: 0
            ),
            .init(
                source: .system,
                result: STTResult(
                    text: "the deployment pipeline finished without any errors",
                    words: [
                        TimestampedWord(word: "the", startMs: 0, endMs: 120, confidence: 0.95),
                        TimestampedWord(word: "deployment", startMs: 140, endMs: 560, confidence: 0.95),
                        TimestampedWord(word: "pipeline", startMs: 580, endMs: 950, confidence: 0.95),
                        TimestampedWord(word: "finished", startMs: 970, endMs: 1_300, confidence: 0.95),
                        TimestampedWord(word: "without", startMs: 1_320, endMs: 1_600, confidence: 0.95),
                        TimestampedWord(word: "any", startMs: 1_620, endMs: 1_750, confidence: 0.95),
                        TimestampedWord(word: "errors", startMs: 1_770, endMs: 2_100, confidence: 0.95),
                    ]
                ),
                startOffsetMs: 0
            ),
        ])

        XCTAssertEqual(
            finalized.words.filter { $0.speakerId == "microphone" }.count,
            7,
            "cross-talk with different words must never be treated as echo"
        )
    }
}
