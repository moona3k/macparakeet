import XCTest
@testable import MacParakeetCore

final class SpeakerAttributionResolverTests: XCTestCase {
    func testTextEditReplacesOneEffectiveSegmentWithoutMutatingWords() {
        let transcription = fixture()
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let range = TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 4)
        let edit = correction(
            id: UUID(), parentID: nil, sequence: 1,
            fingerprint: fingerprint, transcription: transcription,
            command: .editText(
                target: target(range, transcription: transcription),
                text: "Corrected phrase."
            )
        )

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: [edit],
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: fingerprint.rawValue,
                headId: edit.id,
                revision: 1
            )
        )

        XCTAssertEqual(resolved.editableSegments.map(\.text), ["Corrected phrase."])
        XCTAssertTrue(resolved.editableSegments[0].isTextEdited)
        XCTAssertTrue(resolved.hasTextCorrections)
        XCTAssertEqual(resolved.words, transcription.wordTimestamps)
        XCTAssertTrue(resolved.unresolvedCorrections.isEmpty)
    }

    func testPartialTextEditNormalizesUntouchedTokenizerWordSlices() {
        let words = [
            WordTimestamp(word: "That's", startMs: 0, endMs: 150, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: " incredible", startMs: 200, endMs: 350, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: ".", startMs: 400, endMs: 450, confidence: 0.9, speakerId: "S1"),
        ]
        let speakers = [SpeakerInfo(id: "S1", label: "Speaker 1")]
        let transcription = Transcription(
            fileName: "tokenizer-words.wav",
            wordTimestamps: words,
            speakers: speakers,
            diarizationSegments: [.init(speakerId: "S1", startMs: 0, endMs: 450)],
            transcriptSegments: TranscriptSegmenter.materializeSegments(
                words: words,
                speakers: speakers,
                idGenerator: sequentialUUIDGenerator()
            ),
            status: .completed
        )
        XCTAssertEqual(
            SpeakerAttributionResolver.resolve(transcription: transcription)
                .editableSegments.map(\.text),
            ["That's incredible."]
        )

        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let wholeRange = TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 3)
        let middleAndSuffixRange = TranscriptSegmentWordRange(startIndex: 1, endIndexExclusive: 3)
        let prefixRange = TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 1)
        let middleRange = TranscriptSegmentWordRange(startIndex: 1, endIndexExclusive: 2)
        let suffixRange = TranscriptSegmentWordRange(startIndex: 2, endIndexExclusive: 3)
        let firstSplitID = UUID()
        let secondSplitID = UUID()
        let editID = UUID()
        let mergeID = UUID()
        let firstSplit = correction(
            id: firstSplitID,
            parentID: nil,
            sequence: 1,
            fingerprint: fingerprint,
            transcription: transcription,
            command: .split(
                target: target(wholeRange, transcription: transcription),
                atWordIndex: 1
            )
        )
        let secondSplit = correction(
            id: secondSplitID,
            parentID: firstSplitID,
            sequence: 2,
            fingerprint: fingerprint,
            transcription: transcription,
            command: .split(
                target: target(middleAndSuffixRange, transcription: transcription),
                atWordIndex: 2
            )
        )
        let edit = correction(
            id: editID,
            parentID: secondSplitID,
            sequence: 3,
            fingerprint: fingerprint,
            transcription: transcription,
            command: .editText(
                target: target(middleRange, transcription: transcription),
                text: "amazing"
            )
        )
        let merge = correction(
            id: mergeID,
            parentID: editID,
            sequence: 4,
            fingerprint: fingerprint,
            transcription: transcription,
            command: .mergeSegments(
                targets: [prefixRange, middleRange, suffixRange].map {
                    target($0, transcription: transcription)
                }
            )
        )

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: [firstSplit, secondSplit, edit, merge],
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: fingerprint.rawValue,
                headId: mergeID,
                revision: 4
            )
        )

        XCTAssertEqual(resolved.editableSegments.map(\.text), ["That's amazing."])
        XCTAssertTrue(resolved.unresolvedCorrections.isEmpty)
    }

    func testMergeComposesAdjacentCurrentTextAndKeepsTimingEnvelope() {
        let transcription = twoSegmentFixture()
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let ranges = TranscriptSegmenter.editableWordRanges(words: transcription.wordTimestamps ?? [])
        XCTAssertEqual(ranges.count, 2)
        let firstEdit = correction(
            id: UUID(), parentID: nil, sequence: 1,
            fingerprint: fingerprint, transcription: transcription,
            command: .editText(
                target: target(ranges[0], transcription: transcription),
                text: "Edited first."
            )
        )
        let merge = correction(
            id: UUID(), parentID: firstEdit.id, sequence: 2,
            fingerprint: fingerprint, transcription: transcription,
            command: .mergeSegments(
                targets: ranges.map { target($0, transcription: transcription) }
            )
        )

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: [firstEdit, merge],
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: fingerprint.rawValue,
                headId: merge.id,
                revision: 2
            )
        )

        XCTAssertEqual(resolved.editableSegments.count, 1)
        XCTAssertEqual(resolved.editableSegments[0].text, "Edited first. three four")
        XCTAssertEqual(resolved.editableSegments[0].startMs, 0)
        XCTAssertEqual(resolved.editableSegments[0].endMs, 3_350)
        XCTAssertEqual(resolved.editableSegments[0].anchorTranscriptSegmentIDs.count, 2)
        XCTAssertTrue(resolved.hasTextCorrections)
        XCTAssertTrue(resolved.unresolvedCorrections.isEmpty)
    }

    func testTextEditRejectsBlankReplacement() {
        let transcription = fixture()
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let edit = correction(
            id: UUID(), parentID: nil, sequence: 1,
            fingerprint: fingerprint, transcription: transcription,
            command: .editText(
                target: target(
                    .init(startIndex: 0, endIndexExclusive: 4),
                    transcription: transcription
                ),
                text: "  \n  "
            )
        )

        let resolved = resolve(transcription, correction: edit, fingerprint: fingerprint)

        XCTAssertEqual(
            resolved.unresolvedCorrections,
            [.init(correctionID: edit.id, reason: .invalidText)]
        )
        XCTAssertFalse(resolved.hasTextCorrections)
    }

    func testMergeRejectsNonAdjacentCurrentSegments() {
        var transcription = fixture()
        var words = transcription.wordTimestamps ?? []
        for index in words.indices {
            words[index].startMs = index * 3_000
            words[index].endMs = index * 3_000 + 150
        }
        transcription.wordTimestamps = words
        transcription.transcriptSegments = TranscriptSegmenter.materializeSegments(
            words: words,
            speakers: transcription.speakers,
            idGenerator: sequentialUUIDGenerator()
        )
        let ranges = TranscriptSegmenter.editableWordRanges(
            words: words
        )
        XCTAssertEqual(ranges.count, 4)
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let merge = correction(
            id: UUID(), parentID: nil, sequence: 1,
            fingerprint: fingerprint, transcription: transcription,
            command: .mergeSegments(
                targets: [ranges[0], ranges[2]].map {
                    target($0, transcription: transcription)
                }
            )
        )

        let resolved = resolve(transcription, correction: merge, fingerprint: fingerprint)

        XCTAssertEqual(
            resolved.unresolvedCorrections,
            [.init(correctionID: merge.id, reason: .nonAdjacentTargets)]
        )
        XCTAssertEqual(resolved.editableSegments.map(\.wordRange), ranges)
    }

    func testMergeRejectsOutOfOrderCurrentSegments() {
        let transcription = twoSegmentFixture()
        let ranges = TranscriptSegmenter.editableWordRanges(
            words: transcription.wordTimestamps ?? []
        )
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let merge = correction(
            id: UUID(), parentID: nil, sequence: 1,
            fingerprint: fingerprint, transcription: transcription,
            command: .mergeSegments(
                targets: ranges.reversed().map {
                    target($0, transcription: transcription)
                }
            )
        )

        let resolved = resolve(transcription, correction: merge, fingerprint: fingerprint)

        XCTAssertEqual(
            resolved.unresolvedCorrections,
            [.init(correctionID: merge.id, reason: .nonAdjacentTargets)]
        )
        XCTAssertEqual(resolved.editableSegments.map(\.wordRange), ranges)
    }

    func testMergeRejectsMixedSpeakerAssignments() {
        var transcription = twoSegmentFixture()
        transcription.wordTimestamps?[2].speakerId = "S2"
        transcription.wordTimestamps?[3].speakerId = "S2"
        transcription.diarizationSegments = [
            .init(speakerId: "S1", startMs: 0, endMs: 350),
            .init(speakerId: "S2", startMs: 3_000, endMs: 3_350),
        ]
        transcription.transcriptSegments = TranscriptSegmenter.materializeSegments(
            words: transcription.wordTimestamps ?? [],
            speakers: transcription.speakers,
            idGenerator: sequentialUUIDGenerator()
        )
        let ranges = TranscriptSegmenter.editableWordRanges(
            words: transcription.wordTimestamps ?? []
        )
        XCTAssertEqual(ranges.count, 2)
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let merge = correction(
            id: UUID(), parentID: nil, sequence: 1,
            fingerprint: fingerprint, transcription: transcription,
            command: .mergeSegments(
                targets: ranges.map { target($0, transcription: transcription) }
            )
        )

        let resolved = resolve(transcription, correction: merge, fingerprint: fingerprint)

        XCTAssertEqual(
            resolved.unresolvedCorrections,
            [.init(correctionID: merge.id, reason: .mixedAssignments)]
        )
        XCTAssertEqual(resolved.editableSegments.map(\.wordRange), ranges)
    }

    func testRemovingSplitAtMergedAutomaticBoundaryRestoresMergeAcrossUndoRedo() {
        let transcription = twoSegmentFixture()
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let ranges = TranscriptSegmenter.editableWordRanges(words: transcription.wordTimestamps ?? [])
        let targets = ranges.map { target($0, transcription: transcription) }
        let whole = target(
            .init(startIndex: ranges[0].startIndex, endIndexExclusive: ranges[1].endIndexExclusive),
            transcription: transcription
        )
        let merge = correction(
            id: UUID(), parentID: nil, sequence: 1,
            fingerprint: fingerprint, transcription: transcription,
            command: .mergeSegments(targets: targets)
        )
        let split = correction(
            id: UUID(), parentID: merge.id, sequence: 2,
            fingerprint: fingerprint, transcription: transcription,
            command: .split(target: whole, atWordIndex: ranges[1].startIndex)
        )
        let unsplit = correction(
            id: UUID(), parentID: split.id, sequence: 3,
            fingerprint: fingerprint, transcription: transcription,
            command: .removeSplit(
                boundary: .init(target: whole, wordIndex: ranges[1].startIndex),
                joinedAssignment: nil
            )
        )
        let history = [merge, split, unsplit]

        let joined = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: history,
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: fingerprint.rawValue,
                headId: unsplit.id,
                revision: 3
            )
        )
        let undone = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: history,
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: fingerprint.rawValue,
                headId: split.id,
                revision: 4
            )
        )

        XCTAssertEqual(joined.editableSegments.map(\.wordRange), [whole.wordRange])
        XCTAssertTrue(joined.editableSegments[0].isTextEdited)
        XCTAssertFalse(joined.editableSegments[0].hasTextOverride)
        XCTAssertEqual(undone.editableSegments.map(\.wordRange), ranges)
        XCTAssertTrue(joined.unresolvedCorrections.isEmpty)
        XCTAssertTrue(undone.unresolvedCorrections.isEmpty)
    }

    func testBoundaryOnlyMergeCanBeSplitAgain() {
        let transcription = twoSegmentFixture()
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let ranges = TranscriptSegmenter.editableWordRanges(words: transcription.wordTimestamps ?? [])
        let targets = ranges.map { target($0, transcription: transcription) }
        let whole = target(
            .init(startIndex: ranges[0].startIndex, endIndexExclusive: ranges[1].endIndexExclusive),
            transcription: transcription
        )
        let merge = correction(
            id: UUID(), parentID: nil, sequence: 1,
            fingerprint: fingerprint, transcription: transcription,
            command: .mergeSegments(targets: targets)
        )
        let split = correction(
            id: UUID(), parentID: merge.id, sequence: 2,
            fingerprint: fingerprint, transcription: transcription,
            command: .split(target: whole, atWordIndex: ranges[1].startIndex)
        )

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: [merge, split],
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: fingerprint.rawValue,
                headId: split.id,
                revision: 2
            )
        )

        XCTAssertEqual(resolved.editableSegments.map(\.wordRange), ranges)
        XCTAssertTrue(resolved.editableSegments.allSatisfy { !$0.hasTextOverride })
        XCTAssertTrue(resolved.unresolvedCorrections.isEmpty)
    }

    func testSplitRejectsBoundaryCrossingEditedText() {
        let transcription = fixture()
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let whole = target(.init(startIndex: 0, endIndexExclusive: 4), transcription: transcription)
        let edit = correction(
            id: UUID(), parentID: nil, sequence: 1,
            fingerprint: fingerprint, transcription: transcription,
            command: .editText(target: whole, text: "One corrected sentence.")
        )
        let split = correction(
            id: UUID(), parentID: edit.id, sequence: 2,
            fingerprint: fingerprint, transcription: transcription,
            command: .split(target: whole, atWordIndex: 2)
        )

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: [edit, split],
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: fingerprint.rawValue,
                headId: split.id,
                revision: 2
            )
        )

        XCTAssertEqual(resolved.editableSegments.map(\.text), ["One corrected sentence."])
        XCTAssertEqual(
            resolved.unresolvedCorrections,
            [.init(correctionID: split.id, reason: .textAlignmentConflict)]
        )
    }

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

    func testExplicitEmptyCursorDoesNotReplayRetainedHistory() {
        let transcription = fixture()
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let retained = correction(
            id: UUID(), parentID: nil, sequence: 1,
            fingerprint: fingerprint, transcription: transcription,
            command: .rename(speakerID: "S1", label: "Retired name")
        )
        let state = SpeakerCorrectionState(
            transcriptionId: transcription.id,
            transcriptFingerprint: fingerprint.rawValue,
            headId: nil, revision: 2
        )

        let resolved = SpeakerAttributionResolver.resolve(
            transcription: transcription, corrections: [retained], state: state
        )

        XCTAssertEqual(resolved.speakers, transcription.speakers)
        XCTAssertEqual(resolved.words, transcription.wordTimestamps)
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

    private func twoSegmentFixture() -> Transcription {
        var transcription = fixture()
        transcription.wordTimestamps?[2].startMs = 3_000
        transcription.wordTimestamps?[2].endMs = 3_150
        transcription.wordTimestamps?[3].startMs = 3_200
        transcription.wordTimestamps?[3].endMs = 3_350
        transcription.transcriptSegments = TranscriptSegmenter.materializeSegments(
            words: transcription.wordTimestamps ?? [],
            speakers: transcription.speakers,
            idGenerator: sequentialUUIDGenerator()
        )
        return transcription
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

    private func resolve(
        _ transcription: Transcription,
        correction: SpeakerCorrection,
        fingerprint: TranscriptFingerprint
    ) -> EffectiveSpeakerAttribution {
        SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: [correction],
            state: .init(
                transcriptionId: transcription.id,
                transcriptFingerprint: fingerprint.rawValue,
                headId: correction.id,
                revision: 1
            )
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
