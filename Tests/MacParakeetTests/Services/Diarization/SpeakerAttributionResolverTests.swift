import XCTest
@testable import MacParakeetCore

final class SpeakerAttributionResolverTests: XCTestCase {
    func testEmptyCorrectionLogPreservesAutomaticProjectionAndPresentationBoundaries() {
        let transcription = fixture()

        let resolved = SpeakerAttributionResolver.resolve(transcription: transcription)
        let legacySegments = TranscriptSegmenter.groupIntoSegments(
            words: transcription.wordTimestamps ?? []
        )

        XCTAssertEqual(resolved.words, transcription.wordTimestamps)
        XCTAssertEqual(resolved.speakers, transcription.speakers)
        XCTAssertEqual(resolved.diarizationSegments, transcription.diarizationSegments)
        XCTAssertEqual(resolved.editableSegments.map(\.startMs), legacySegments.map(\.startMs))
        XCTAssertEqual(resolved.editableSegments.map(\.text), legacySegments.map(\.text))
        XCTAssertEqual(
            resolved.editableSegments.map(\.wordRange),
            TranscriptSegmenter.editableWordRanges(words: transcription.wordTimestamps ?? [])
        )
        XCTAssertTrue(resolved.unresolvedCorrections.isEmpty)
    }

    func testSplitThenAddAndAssignCreatesStableIndependentSlices() {
        let transcription = fixture()
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let originalRange = TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 4)
        let originalTarget = target(originalRange, transcription: transcription)
        let rightRange = TranscriptSegmentWordRange(startIndex: 2, endIndexExclusive: 4)
        let rightTarget = target(rightRange, transcription: transcription)
        let splitID = UUID()
        let addID = UUID()
        let manualID = "user:\(UUID().uuidString)"
        let corrections = [
            correction(
                id: splitID,
                parentID: nil,
                sequence: 1,
                fingerprint: fingerprint,
                transcription: transcription,
                command: .split(target: originalTarget, atWordIndex: 2)
            ),
            correction(
                id: addID,
                parentID: splitID,
                sequence: 2,
                fingerprint: fingerprint,
                transcription: transcription,
                command: .add(
                    speaker: ManualSpeaker(id: manualID, label: "Alice"),
                    assigning: [rightTarget]
                )
            ),
        ]
        let state = SpeakerCorrectionState(
            transcriptionId: transcription.id,
            transcriptFingerprint: fingerprint.rawValue,
            headId: addID,
            revision: 2
        )

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: corrections,
            state: state
        )

        XCTAssertEqual(
            resolved.editableSegments.map(\.wordRange),
            [
                .init(startIndex: 0, endIndexExclusive: 2),
                .init(startIndex: 2, endIndexExclusive: 4),
            ])
        XCTAssertEqual(resolved.editableSegments[1].assignment, .speaker(id: manualID))
        XCTAssertEqual(resolved.editableSegments[1].text, "three four")
        XCTAssertEqual(resolved.editableSegments[1].startMs, 400)
        XCTAssertEqual(resolved.editableSegments[1].endMs, 750)
        XCTAssertEqual(resolved.words.map(\.speakerId), ["S1", "S1", manualID, manualID])
        XCTAssertEqual(resolved.speakers.last, SpeakerInfo(id: manualID, label: "Alice"))
        XCTAssertTrue(resolved.editableSegments.allSatisfy(\.isManuallySplit))
        XCTAssertTrue(resolved.unresolvedCorrections.isEmpty)

        let resolvedAgain = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: corrections,
            state: state
        )
        XCTAssertEqual(resolved.editableSegments.map(\.id), resolvedAgain.editableSegments.map(\.id))
    }

    func testExplicitUnassignedDoesNotInheritDuringTurnGrouping() {
        let transcription = fixture()
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let target = target(
            .init(startIndex: 0, endIndexExclusive: 4),
            transcription: transcription
        )
        let correction = correction(
            id: UUID(),
            parentID: nil,
            sequence: 1,
            fingerprint: fingerprint,
            transcription: transcription,
            command: .assign(targets: [target], to: .unassigned)
        )
        let state = SpeakerCorrectionState(
            transcriptionId: transcription.id,
            transcriptFingerprint: fingerprint.rawValue,
            headId: correction.id,
            revision: 1
        )

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: [correction],
            state: state
        )

        XCTAssertEqual(resolved.editableSegments.map(\.assignment), [.unassigned])
        XCTAssertEqual(resolved.turns.map(\.assignment), [.unassigned])
        XCTAssertEqual(resolved.turns.map(\.speakerLabel), ["Unassigned"])
        XCTAssertEqual(resolved.words.map(\.speakerId), [nil, nil, nil, nil])
    }

    func testCrossSourceAssignmentPreservesAutomaticWordProvenance() {
        var transcription = fixture()
        transcription.wordTimestamps?[0].speakerId = AudioSource.microphone.rawValue
        transcription.wordTimestamps?[1].speakerId = "system:S1"
        transcription.speakers = [
            .init(id: AudioSource.microphone.rawValue, label: "Me"),
            .init(id: "system:S1", label: "Other 1"),
        ]
        transcription.transcriptSegments = TranscriptSegmenter.materializeSegments(
            words: transcription.wordTimestamps ?? [],
            speakers: transcription.speakers,
            idGenerator: sequentialUUIDGenerator()
        )
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let firstRange = TranscriptSegmenter.editableWordRanges(
            words: transcription.wordTimestamps ?? []
        )[0]
        let command = SpeakerCorrectionCommand.assign(
            targets: [target(firstRange, transcription: transcription)],
            to: .speaker(id: "system:S1")
        )
        let correction = correction(
            id: UUID(),
            parentID: nil,
            sequence: 1,
            fingerprint: fingerprint,
            transcription: transcription,
            command: command
        )

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: [correction],
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: fingerprint.rawValue,
                headId: correction.id,
                revision: 1
            )
        )

        XCTAssertEqual(resolved.words[0].speakerId, "system:S1")
        XCTAssertEqual(resolved.provenanceByWord[0].automaticSpeakerID, "microphone")
        XCTAssertEqual(resolved.provenanceByWord[0].audioSource, .microphone)
        XCTAssertEqual(resolved.provenanceByWord[1].audioSource, .system)
    }

    func testWrongFingerprintLeavesBaselineAndReportsCorrection() {
        let transcription = fixture()
        let realFingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let correction = correction(
            id: UUID(),
            parentID: nil,
            sequence: 1,
            fingerprint: realFingerprint,
            transcription: transcription,
            command: .rename(speakerID: "S1", label: "Alice")
        )

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: [correction],
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: "stale",
                headId: correction.id,
                revision: 4
            )
        )

        XCTAssertEqual(resolved.speakers, transcription.speakers)
        XCTAssertEqual(
            resolved.unresolvedCorrections,
            [
                .init(correctionID: correction.id, reason: .wrongFingerprint)
            ])
        XCTAssertEqual(resolved.correctionRevision, 4)
    }

    func testResetRestoresBaselineAfterAssignmentAndRename() {
        let transcription = fixture()
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let assignID = UUID()
        let renameID = UUID()
        let resetID = UUID()
        let whole = target(
            .init(startIndex: 0, endIndexExclusive: 4),
            transcription: transcription
        )
        let corrections = [
            correction(
                id: assignID,
                parentID: nil,
                sequence: 1,
                fingerprint: fingerprint,
                transcription: transcription,
                command: .assign(targets: [whole], to: .speaker(id: "S2"))
            ),
            correction(
                id: renameID,
                parentID: assignID,
                sequence: 2,
                fingerprint: fingerprint,
                transcription: transcription,
                command: .rename(speakerID: "S2", label: "Bob")
            ),
            correction(
                id: resetID,
                parentID: renameID,
                sequence: 3,
                fingerprint: fingerprint,
                transcription: transcription,
                command: .reset
            ),
        ]

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: corrections,
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: fingerprint.rawValue,
                headId: resetID,
                revision: 3
            )
        )

        XCTAssertEqual(resolved.speakers, transcription.speakers)
        XCTAssertEqual(resolved.words, transcription.wordTimestamps)
        XCTAssertEqual(resolved.diarizationSegments, transcription.diarizationSegments)
    }

    func testAssignmentRebuildPreservesLongSilenceBetweenSameSpeakerWords() {
        let words = [
            WordTimestamp(word: "one", startMs: 0, endMs: 150, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: "two", startMs: 200, endMs: 350, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: "three", startMs: 400, endMs: 550, confidence: 0.9, speakerId: "S2"),
            WordTimestamp(word: "four", startMs: 5000, endMs: 5150, confidence: 0.9, speakerId: "S1"),
        ]
        let speakers = [
            SpeakerInfo(id: "S1", label: "Speaker 1"),
            SpeakerInfo(id: "S2", label: "Speaker 2"),
        ]
        let transcription = Transcription(
            fileName: "long-gap.wav",
            wordTimestamps: words,
            speakers: speakers,
            diarizationSegments: [
                .init(speakerId: "S1", startMs: 0, endMs: 350),
                .init(speakerId: "S2", startMs: 400, endMs: 550),
                .init(speakerId: "S1", startMs: 5000, endMs: 5150),
            ],
            transcriptSegments: TranscriptSegmenter.materializeSegments(
                words: words,
                speakers: speakers,
                idGenerator: sequentialUUIDGenerator()
            ),
            status: .completed
        )
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let correction = correction(
            id: UUID(),
            parentID: nil,
            sequence: 1,
            fingerprint: fingerprint,
            transcription: transcription,
            command: .assign(
                targets: [target(.init(startIndex: 2, endIndexExclusive: 3), transcription: transcription)],
                to: .speaker(id: "S1")
            )
        )

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: [correction],
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: fingerprint.rawValue,
                headId: correction.id,
                revision: 1
            )
        )

        XCTAssertEqual(
            resolved.diarizationSegments,
            [
                .init(speakerId: "S1", startMs: 0, endMs: 550),
                .init(speakerId: "S1", startMs: 5000, endMs: 5150),
            ]
        )
        XCTAssertEqual(resolved.statistics["S1"]?.speakingTimeMs, 700)
    }

    func testRemoveSplitRejectsTargetThatDoesNotMatchAdjacentSlices() {
        let transcription = fixture()
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let splitID = UUID()
        let removeID = UUID()
        let split = correction(
            id: splitID,
            parentID: nil,
            sequence: 1,
            fingerprint: fingerprint,
            transcription: transcription,
            command: .split(
                target: target(.init(startIndex: 0, endIndexExclusive: 4), transcription: transcription),
                atWordIndex: 2
            )
        )
        let forgedTarget = target(
            .init(startIndex: 1, endIndexExclusive: 3),
            transcription: transcription
        )
        let remove = correction(
            id: removeID,
            parentID: splitID,
            sequence: 2,
            fingerprint: fingerprint,
            transcription: transcription,
            command: .removeSplit(
                boundary: .init(target: forgedTarget, wordIndex: 2),
                joinedAssignment: nil
            )
        )

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: [split, remove],
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: fingerprint.rawValue,
                headId: removeID,
                revision: 2
            )
        )

        XCTAssertEqual(
            resolved.editableSegments.map(\.wordRange),
            [
                .init(startIndex: 0, endIndexExclusive: 2),
                .init(startIndex: 2, endIndexExclusive: 4),
            ]
        )
        XCTAssertEqual(
            resolved.unresolvedCorrections,
            [.init(correctionID: removeID, reason: .invalidBoundary)]
        )
    }

    func testRemoveSplitAcceptsTargetMatchingAdjacentSlices() {
        let transcription = fixture()
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let splitID = UUID()
        let removeID = UUID()
        let wholeTarget = target(
            .init(startIndex: 0, endIndexExclusive: 4),
            transcription: transcription
        )
        let split = correction(
            id: splitID,
            parentID: nil,
            sequence: 1,
            fingerprint: fingerprint,
            transcription: transcription,
            command: .split(target: wholeTarget, atWordIndex: 2)
        )
        let remove = correction(
            id: removeID,
            parentID: splitID,
            sequence: 2,
            fingerprint: fingerprint,
            transcription: transcription,
            command: .removeSplit(
                boundary: .init(target: wholeTarget, wordIndex: 2),
                joinedAssignment: nil
            )
        )

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: [split, remove],
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: fingerprint.rawValue,
                headId: removeID,
                revision: 2
            )
        )

        XCTAssertEqual(
            resolved.editableSegments.map(\.wordRange),
            [.init(startIndex: 0, endIndexExclusive: 4)]
        )
        XCTAssertTrue(resolved.unresolvedCorrections.isEmpty)
    }

    func testRemoveSplitRejectsBoundaryOutsideTargetRange() {
        let transcription = fixture()
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let splitID = UUID()
        let removeID = UUID()
        let split = correction(
            id: splitID,
            parentID: nil,
            sequence: 1,
            fingerprint: fingerprint,
            transcription: transcription,
            command: .split(
                target: target(.init(startIndex: 0, endIndexExclusive: 4), transcription: transcription),
                atWordIndex: 2
            )
        )
        let remove = correction(
            id: removeID,
            parentID: splitID,
            sequence: 2,
            fingerprint: fingerprint,
            transcription: transcription,
            command: .removeSplit(
                boundary: .init(
                    target: target(.init(startIndex: 0, endIndexExclusive: 1), transcription: transcription),
                    wordIndex: 2
                ),
                joinedAssignment: nil
            )
        )

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: [split, remove],
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: fingerprint.rawValue,
                headId: removeID,
                revision: 2
            )
        )

        XCTAssertEqual(
            resolved.unresolvedCorrections,
            [.init(correctionID: removeID, reason: .invalidBoundary)]
        )
    }

    private func fixture() -> Transcription {
        let words = [
            WordTimestamp(word: "one", startMs: 0, endMs: 150, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: "two", startMs: 200, endMs: 350, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: "three", startMs: 400, endMs: 550, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: "four", startMs: 600, endMs: 750, confidence: 0.9, speakerId: "S1"),
        ]
        let speakers = [
            SpeakerInfo(id: "S1", label: "Speaker 1"),
            SpeakerInfo(id: "S2", label: "Speaker 2"),
        ]
        return Transcription(
            fileName: "fixture.wav",
            wordTimestamps: words,
            speakers: speakers,
            diarizationSegments: [
                .init(speakerId: "S1", startMs: 0, endMs: 750)
            ],
            transcriptSegments: TranscriptSegmenter.materializeSegments(
                words: words,
                speakers: speakers,
                idGenerator: sequentialUUIDGenerator()
            ),
            status: .completed
        )
    }

    private func target(
        _ range: TranscriptSegmentWordRange,
        transcription: Transcription
    ) -> SpeakerCorrectionTarget {
        let anchors = (transcription.transcriptSegments ?? []).compactMap { segment in
            segment.wordRange.startIndex < range.endIndexExclusive
                && range.startIndex < segment.wordRange.endIndexExclusive ? segment.id : nil
        }
        return .init(anchorTranscriptSegmentIDs: anchors, wordRange: range)
    }

    private func correction(
        id: UUID,
        parentID: UUID?,
        sequence: Int,
        fingerprint: TranscriptFingerprint,
        transcription: Transcription,
        command: SpeakerCorrectionCommand
    ) -> SpeakerCorrection {
        SpeakerCorrection(
            id: id,
            transcriptionId: transcription.id,
            parentId: parentID,
            sequence: sequence,
            transcriptFingerprint: fingerprint,
            payload: command,
            createdAt: Date(timeIntervalSince1970: TimeInterval(sequence))
        )
    }

    private func sequentialUUIDGenerator() -> () -> UUID {
        var value: UInt8 = 0
        return {
            defer { value += 1 }
            return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
        }
    }
}
