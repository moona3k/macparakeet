import AVFoundation
import CryptoKit
import os
import XCTest
@testable import MacParakeetCore

/// Coverage for `MeetingSplitAudioExporter` (plan #895 U3). Fixtures are
/// synthetic tones whose frequency is a deterministic function of the
/// *global* recording timeline, so decoded output can be checked against the
/// exact absolute time it should represent, not just container duration.
final class MeetingSplitAudioExporterTests: XCTestCase {

    // MARK: - Fixture layout shared by the main alignment tests

    private struct Fixture {
        let sourceFolderURL: URL
        let alignment: MeetingSourceAlignment
    }

    /// playback: 48 kHz, [0, 8000)ms.
    /// rawMicrophone: 44.1 kHz, starts 500ms late, [500, 6500)ms.
    /// rawSystem: 48 kHz, starts on time, ends early, [0, 5000)ms.
    /// cleanedMicrophone: 44.1 kHz, shares the mic's start offset but is much
    /// shorter than the raw mic: [500, 1700)ms. This must never be assumed
    /// from the mic's own length.
    private func makeMainFixture() throws -> Fixture {
        let folder = try makeTemporaryDirectory()
        try writeToneM4A(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000, durationMs: 8_000, globalStartMs: 0)
        try writeToneM4A(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.rawMicrophone),
            sampleRate: 44_100, durationMs: 6_000, globalStartMs: 500)
        try writeToneM4A(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.rawSystem),
            sampleRate: 48_000, durationMs: 5_000, globalStartMs: 0)
        try writeToneM4A(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.cleanedMicrophone),
            sampleRate: 44_100, durationMs: 1_200, globalStartMs: 500)

        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 1,
            microphone: .init(
                firstHostTime: 1, lastHostTime: 2, startOffsetMs: 500,
                writtenFrameCount: Int64(6.0 * 44_100), sampleRate: 44_100),
            system: .init(
                firstHostTime: 1, lastHostTime: 2, startOffsetMs: 0,
                writtenFrameCount: Int64(5.0 * 48_000), sampleRate: 48_000)
        )
        return Fixture(sourceFolderURL: folder, alignment: alignment)
    }

    // MARK: - Core intersection math across three children

    func testAsymmetricStartsEndsAndMixedRatesAcrossThreeRanges() async throws {
        let fixture = try makeMainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sourceFolderURL) }
        let destinationRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationRoot) }

        let childA = UUID()
        let childB = UUID()
        let childC = UUID()
        let requests = [
            MeetingSplitAudioChildRequest(
                childId: childA, range: .init(startMs: 0, endMs: 2_000),
                destinationFolderURL: destinationRoot.appendingPathComponent("A")),
            MeetingSplitAudioChildRequest(
                childId: childB, range: .init(startMs: 2_000, endMs: 6_000),
                destinationFolderURL: destinationRoot.appendingPathComponent("B")),
            MeetingSplitAudioChildRequest(
                childId: childC, range: .init(startMs: 6_000, endMs: 8_000),
                destinationFolderURL: destinationRoot.appendingPathComponent("C")),
        ]

        let sourceHashesBefore = try sourceHashes(in: fixture.sourceFolderURL)
        let exporter = MeetingSplitAudioExporter()
        let results = try await exporter.export(
            sourceFolderURL: fixture.sourceFolderURL,
            sourceAlignment: fixture.alignment,
            children: requests)
        XCTAssertEqual(try sourceHashes(in: fixture.sourceFolderURL), sourceHashesBefore, "sources must be read-only")

        XCTAssertEqual(results.count, 3)
        let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.childId, $0) })

        // Playback: always full coverage, always offset 0, contiguous and gapless.
        try assertTrack(byId[childA]!.playback, offsetMs: 0, durationMs: 2_000, sampleRate: 48_000)
        try assertTrack(byId[childB]!.playback, offsetMs: 0, durationMs: 4_000, sampleRate: 48_000)
        try assertTrack(byId[childC]!.playback, offsetMs: 0, durationMs: 2_000, sampleRate: 48_000)

        // Raw microphone: starts 500ms late, present (partially) in every child.
        try assertTrack(byId[childA]!.rawMicrophone, offsetMs: 500, durationMs: 1_500, sampleRate: 44_100)
        try assertTrack(byId[childB]!.rawMicrophone, offsetMs: 0, durationMs: 4_000, sampleRate: 44_100)
        try assertTrack(byId[childC]!.rawMicrophone, offsetMs: 0, durationMs: 500, sampleRate: 44_100)

        // Raw system: ends at 5000ms, absent from the last child entirely.
        try assertTrack(byId[childA]!.rawSystem, offsetMs: 0, durationMs: 2_000, sampleRate: 48_000)
        try assertTrack(byId[childB]!.rawSystem, offsetMs: 0, durationMs: 3_000, sampleRate: 48_000)
        XCTAssertNil(byId[childC]!.rawSystem, "system track ended before this child starts")

        // Cleaned mic: much shorter than the raw mic; present only in the first child,
        // proving its own decoded length is used, not the raw mic's.
        try assertTrack(byId[childA]!.cleanedMicrophone, offsetMs: 500, durationMs: 1_200, sampleRate: 44_100)
        XCTAssertNil(byId[childB]!.cleanedMicrophone, "cleaned mic ended before this child starts")
        XCTAssertNil(byId[childC]!.cleanedMicrophone, "cleaned mic ended before this child starts")

        // Decoded content around the cuts: check absolute source time landed in the right child.
        try await assertPlaybackFrequency(
            fileURL: destinationRoot.appendingPathComponent("A").appendingPathComponent(
                MeetingArtifactAudioFileNames.playback),
            localWindowStartMs: 200, windowMs: 400, expectedGlobalMs: 200)
        try await assertPlaybackFrequency(
            fileURL: destinationRoot.appendingPathComponent("B").appendingPathComponent(
                MeetingArtifactAudioFileNames.playback),
            localWindowStartMs: 500, windowMs: 400, expectedGlobalMs: 2_500)
        try await assertPlaybackFrequency(
            fileURL: destinationRoot.appendingPathComponent("C").appendingPathComponent(
                MeetingArtifactAudioFileNames.playback),
            localWindowStartMs: 500, windowMs: 400, expectedGlobalMs: 6_500)
    }

    // MARK: - Legacy filenames

    func testLegacyFilenamesAreReadAndCanonicalNamesAreWritten() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeToneM4A(to: folder.appendingPathComponent("meeting.m4a"), sampleRate: 48_000, durationMs: 4_000)
        try writeToneM4A(to: folder.appendingPathComponent("microphone.m4a"), sampleRate: 48_000, durationMs: 4_000)
        try writeToneM4A(to: folder.appendingPathComponent("system.m4a"), sampleRate: 48_000, durationMs: 4_000)

        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 1,
            microphone: .init(
                firstHostTime: 1, lastHostTime: 2, startOffsetMs: 0, writtenFrameCount: 192_000, sampleRate: 48_000),
            system: .init(
                firstHostTime: 1, lastHostTime: 2, startOffsetMs: 0, writtenFrameCount: 192_000, sampleRate: 48_000)
        )
        let exporter = MeetingSplitAudioExporter()
        let results = try await exporter.export(
            sourceFolderURL: folder,
            sourceAlignment: alignment,
            children: [
                .init(childId: UUID(), range: .init(startMs: 0, endMs: 4_000), destinationFolderURL: destination)
            ])

        let child = try XCTUnwrap(results.first)
        XCTAssertEqual(child.playback.fileName, MeetingArtifactAudioFileNames.playback)
        XCTAssertEqual(child.rawMicrophone?.fileName, MeetingArtifactAudioFileNames.rawMicrophone)
        XCTAssertEqual(child.rawSystem?.fileName, MeetingArtifactAudioFileNames.rawSystem)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(MeetingArtifactAudioFileNames.playback).path))
    }

    // MARK: - Canonical-only source (no optional tracks at all)

    func testCanonicalOnlySourceExportsPlaybackAndOmitsOptionalTracks() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeToneM4A(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000, durationMs: 3_000)
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        let exporter = MeetingSplitAudioExporter()
        let results = try await exporter.export(
            sourceFolderURL: folder,
            sourceAlignment: MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil),
            children: [
                .init(childId: UUID(), range: .init(startMs: 0, endMs: 3_000), destinationFolderURL: destination)
            ])

        let child = try XCTUnwrap(results.first)
        try assertTrack(child.playback, offsetMs: 0, durationMs: 3_000, sampleRate: 48_000)
        XCTAssertNil(child.rawMicrophone)
        XCTAssertNil(child.rawSystem)
        XCTAssertNil(child.cleanedMicrophone)
    }

    // MARK: - Read-only source inspection

    func testInspectSourceReportsDurationSizeAndTrackAvailabilityWithoutWriting() async throws {
        let fixture = try makeMainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sourceFolderURL) }
        let sourceHashesBefore = try sourceHashes(in: fixture.sourceFolderURL)

        let exporter = MeetingSplitAudioExporter()
        let inspection = try await exporter.inspectSource(sourceFolderURL: fixture.sourceFolderURL)

        XCTAssertEqual(inspection.durationMs, 8_000, accuracy: 1)
        XCTAssertTrue(inspection.hasRawMicrophone)
        XCTAssertTrue(inspection.hasRawSystem)
        XCTAssertTrue(inspection.hasCleanedMicrophone)
        XCTAssertGreaterThan(inspection.sizeBytes, 0)
        XCTAssertEqual(
            try sourceHashes(in: fixture.sourceFolderURL), sourceHashesBefore, "inspection must not write anything")
    }

    func testInspectSourceOnCanonicalOnlySourceReportsNoOptionalTracks() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeToneM4A(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000, durationMs: 3_000)

        let exporter = MeetingSplitAudioExporter()
        let inspection = try await exporter.inspectSource(sourceFolderURL: folder)

        XCTAssertEqual(inspection.durationMs, 3_000, accuracy: 1)
        XCTAssertFalse(inspection.hasRawMicrophone)
        XCTAssertFalse(inspection.hasRawSystem)
        XCTAssertFalse(inspection.hasCleanedMicrophone)
    }

    // MARK: - Failure paths

    func testDestinationAlreadyExistingIsRejectedWithoutOverwriting() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeToneM4A(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000, durationMs: 3_000)
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let existingURL = destination.appendingPathComponent(MeetingArtifactAudioFileNames.playback)
        try Data("not-audio".utf8).write(to: existingURL)

        let exporter = MeetingSplitAudioExporter()
        do {
            _ = try await exporter.export(
                sourceFolderURL: folder,
                sourceAlignment: MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil),
                children: [
                    .init(childId: UUID(), range: .init(startMs: 0, endMs: 3_000), destinationFolderURL: destination)
                ])
            XCTFail("expected destinationAlreadyExists")
        } catch MeetingSplitAudioExportError.destinationAlreadyExists {
            // expected
        }
        XCTAssertEqual(
            try Data(contentsOf: existingURL), Data("not-audio".utf8), "must not overwrite the existing file")
    }

    func testDestinationEqualToSourceFolderIsRejectedWithoutTouchingIt() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let playbackURL = folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback)
        try writeToneM4A(to: playbackURL, sampleRate: 48_000, durationMs: 3_000)
        let sourceHashBefore = try Data(contentsOf: playbackURL)

        let exporter = MeetingSplitAudioExporter()
        do {
            _ = try await exporter.export(
                sourceFolderURL: folder,
                sourceAlignment: MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil),
                children: [
                    .init(childId: UUID(), range: .init(startMs: 0, endMs: 3_000), destinationFolderURL: folder)
                ])
            XCTFail("expected destinationOverlapsSource")
        } catch MeetingSplitAudioExportError.destinationOverlapsSource {
            // expected
        }
        XCTAssertEqual(try Data(contentsOf: playbackURL), sourceHashBefore, "the source file must be untouched")
    }

    func testDestinationNestedInsideSourceFolderIsRejected() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeToneM4A(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000, durationMs: 3_000)
        let nestedDestination = folder.appendingPathComponent("child-inside-source")

        let exporter = MeetingSplitAudioExporter()
        do {
            _ = try await exporter.export(
                sourceFolderURL: folder,
                sourceAlignment: MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil),
                children: [
                    .init(childId: UUID(), range: .init(startMs: 0, endMs: 3_000), destinationFolderURL: nestedDestination)
                ])
            XCTFail("expected destinationOverlapsSource")
        } catch MeetingSplitAudioExportError.destinationOverlapsSource {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedDestination.path))
    }

    /// Only the canonical playback file is fatal when unreadable: a
    /// corrupt/unalignable optional raw or cleaned track must instead be
    /// dropped for every child (see
    /// `testCorruptOptionalTrackIsDroppedRatherThanFailingTheWholeBatch`).
    func testMalformedCanonicalPlaybackFailsBeforeAnyChildIsWritten() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not-audio".utf8).write(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback))
        let destinationRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationRoot) }
        let childDestination = destinationRoot.appendingPathComponent("A")

        let exporter = MeetingSplitAudioExporter()
        do {
            _ = try await exporter.export(
                sourceFolderURL: folder,
                sourceAlignment: MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil),
                children: [
                    .init(
                        childId: UUID(), range: .init(startMs: 0, endMs: 3_000), destinationFolderURL: childDestination)
                ])
            XCTFail("expected malformedSource")
        } catch MeetingSplitAudioExportError.malformedSource {
            // expected
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: childDestination.path),
            "no destination folder should be created before source validation succeeds")
    }

    /// A damaged or unalignable optional raw/cleaned track must not make
    /// otherwise-usable canonical playback ineligible for splitting: it is
    /// dropped (never exported for any child) rather than failing the batch.
    func testCorruptOptionalTrackIsDroppedRatherThanFailingTheWholeBatch() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeToneM4A(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000, durationMs: 3_000)
        try Data("not-audio".utf8).write(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.rawMicrophone))
        let destinationRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationRoot) }
        let childDestination = destinationRoot.appendingPathComponent("A")

        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: nil,
            microphone: .init(
                firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 1, sampleRate: 48_000),
            system: nil)
        let exporter = MeetingSplitAudioExporter()
        let results = try await exporter.export(
            sourceFolderURL: folder,
            sourceAlignment: alignment,
            children: [
                .init(childId: UUID(), range: .init(startMs: 0, endMs: 3_000), destinationFolderURL: childDestination)
            ])

        let child = try XCTUnwrap(results.first)
        try assertTrack(child.playback, offsetMs: 0, durationMs: 3_000, sampleRate: 48_000)
        XCTAssertNil(child.rawMicrophone, "the corrupt track must be dropped, not exported")
    }

    // MARK: - Structurally invalid ranges (rejected before any AVAudioFile seek)

    func testNegativeRangeStartIsRejectedBeforeAnySeek() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeToneM4A(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000, durationMs: 3_000)
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let childId = UUID()

        let exporter = MeetingSplitAudioExporter()
        do {
            _ = try await exporter.export(
                sourceFolderURL: folder,
                sourceAlignment: MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil),
                children: [
                    .init(childId: childId, range: .init(startMs: -100, endMs: 1_000), destinationFolderURL: destination)
                ])
            XCTFail("expected emptyRange for a negative start")
        } catch MeetingSplitAudioExportError.emptyRange(let rejectedChildId) {
            XCTAssertEqual(rejectedChildId, childId)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destination.path), [],
            "no AVAudioFile seek/write should have happened before structural validation rejected the range")
    }

    func testReversedRangeIsRejectedBeforeAnySeek() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeToneM4A(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000, durationMs: 3_000)
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let childId = UUID()

        let exporter = MeetingSplitAudioExporter()
        do {
            _ = try await exporter.export(
                sourceFolderURL: folder,
                sourceAlignment: MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil),
                children: [
                    .init(childId: childId, range: .init(startMs: 2_000, endMs: 1_000), destinationFolderURL: destination)
                ])
            XCTFail("expected emptyRange for a reversed range")
        } catch MeetingSplitAudioExportError.emptyRange(let rejectedChildId) {
            XCTAssertEqual(rejectedChildId, childId)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destination.path), [],
            "no AVAudioFile seek/write should have happened before structural validation rejected the range")
    }

    // MARK: - Fractional-millisecond final frame (Foundation follow-up)

    /// When the decoded duration's true value rounds DOWN to an integer
    /// millisecond, the final range's end (which always equals that rounded
    /// `durationMs`) must still consume the source's actual final decoded
    /// frame, not `msToFrame(durationMs)` (which would drop the fractional
    /// tail the rounding already lost once).
    func testFinalRangeCapturesFractionalTailFrameWhenDurationRoundsDown() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sampleRate = 44_100.0
        // 88,213 frames at 44.1kHz is exactly ~2000.294ms: rounds DOWN to
        // 2000ms, while `msToFrame(2000ms)` (round(2000 * 44100 / 1000)) is
        // only 88,200 frames — 13 frames short of the true decoded extent.
        let exactFrameCount = 88_213
        try writeToneM4AExactFrameCount(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: sampleRate, frameCount: exactFrameCount)
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        let exporter = MeetingSplitAudioExporter()
        let inspection = try await exporter.inspectSource(sourceFolderURL: folder)
        XCTAssertEqual(inspection.durationMs, 2_000, "duration must round DOWN from ~2000.294ms")

        let results = try await exporter.export(
            sourceFolderURL: folder,
            sourceAlignment: MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil),
            children: [
                .init(
                    childId: UUID(), range: .init(startMs: 0, endMs: inspection.durationMs),
                    destinationFolderURL: destination)
            ])

        let child = try XCTUnwrap(results.first)
        let outputFrameCount = try AVAudioFile(
            forReading: destination.appendingPathComponent(MeetingArtifactAudioFileNames.playback)
        ).length
        XCTAssertEqual(
            Int(outputFrameCount), exactFrameCount,
            "must include the fractional tail frame, not stop at msToFrame(2000ms)")
        XCTAssertGreaterThan(child.playback.sizeBytes, 0)
    }

    func testInsufficientStorageIsRejectedBeforeAnyWrites() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeToneM4A(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000, durationMs: 3_000)
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let childDestination = destination.appendingPathComponent("A")

        let exporter = MeetingSplitAudioExporter(availableCapacityBytes: { _ in 10 })
        do {
            _ = try await exporter.export(
                sourceFolderURL: folder,
                sourceAlignment: MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil),
                children: [
                    .init(
                        childId: UUID(), range: .init(startMs: 0, endMs: 3_000), destinationFolderURL: childDestination)
                ])
            XCTFail("expected insufficientStorage")
        } catch MeetingSplitAudioExportError.insufficientStorage {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: childDestination.path))
    }

    func testSourceChangedBetweenChildrenIsRejected() async throws {
        let fixture = try makeMainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sourceFolderURL) }
        let destinationRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationRoot) }
        let micURL = fixture.sourceFolderURL.appendingPathComponent(MeetingArtifactAudioFileNames.rawMicrophone)

        let mutatedOnce = OSAllocatedUnfairLock(initialState: false)
        let hooks = MeetingSplitAudioExporter.TestHooks(afterEachChunk: { _ in
            let shouldMutate = mutatedOnce.withLock { didMutate -> Bool in
                guard !didMutate else { return false }
                didMutate = true
                return true
            }
            guard shouldMutate else { return }
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: micURL.path)
        })
        let exporter = MeetingSplitAudioExporter(testHooks: hooks)

        do {
            _ = try await exporter.export(
                sourceFolderURL: fixture.sourceFolderURL,
                sourceAlignment: fixture.alignment,
                children: [
                    .init(
                        childId: UUID(), range: .init(startMs: 0, endMs: 2_000),
                        destinationFolderURL: destinationRoot.appendingPathComponent("A")),
                    .init(
                        childId: UUID(), range: .init(startMs: 2_000, endMs: 4_000),
                        destinationFolderURL: destinationRoot.appendingPathComponent("B")),
                ])
            XCTFail("expected sourceChanged after the first child's export mutated the mic file")
        } catch MeetingSplitAudioExportError.sourceChanged {
            // expected
        }
    }

    // MARK: - Cancellation

    func testCancellationBeforeWorkWritesNothing() async throws {
        let fixture = try makeMainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sourceFolderURL) }
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let childDestination = destination.appendingPathComponent("A")

        let exporter = MeetingSplitAudioExporter()
        let task = Task {
            try await exporter.export(
                sourceFolderURL: fixture.sourceFolderURL,
                sourceAlignment: fixture.alignment,
                children: [
                    .init(
                        childId: UUID(), range: .init(startMs: 0, endMs: 2_000), destinationFolderURL: childDestination)
                ])
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: childDestination.path))
    }

    func testCancellationDuringWorkStopsTheWriterAndLeavesNoPartialFile() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A few-second, high sample-rate fixture gives the writer loop enough
        // chunks to still be mid-flight when the signal fires.
        try writeToneM4A(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000, durationMs: 6_000)
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let childDestination = destination.appendingPathComponent("A")

        let signal = ChunkSignal(target: 1)
        let hooks = MeetingSplitAudioExporter.TestHooks(afterEachChunk: { count in signal.hook(count) })
        let exporter = MeetingSplitAudioExporter(testHooks: hooks)

        let task = Task {
            try await exporter.export(
                sourceFolderURL: folder,
                sourceAlignment: MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil),
                children: [
                    .init(
                        childId: UUID(), range: .init(startMs: 0, endMs: 6_000), destinationFolderURL: childDestination)
                ])
        }
        await signal.wait()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: childDestination.appendingPathComponent(MeetingArtifactAudioFileNames.playback).path),
            "a cancelled slice must not leave a partial destination file")
    }

    /// Proves the initial source *probe* (`decodedExtent`, used to establish
    /// each source file's decoded duration before any child is exported) is
    /// itself cancellable, not just the write loop: cancellation must be
    /// forwarded into its detached task, not leave it decoding unattended
    /// after the caller has already observed `CancellationError`.
    func testCancellationDuringSourceProbeStopsPromptlyWithoutFinishingTheDecode() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // At 48kHz with the exporter's 32,768-frame chunk size, a 60s source
        // takes ~88 probe chunks to fully decode; cancelling after 2 leaves
        // enormous headroom to detect "kept running anyway" reliably.
        try writeToneM4A(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000, durationMs: 60_000)
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let childDestination = destination.appendingPathComponent("A")

        let signal = ChunkSignal(target: 2)
        let observedChunks = OSAllocatedUnfairLock(initialState: 0)
        let hooks = MeetingSplitAudioExporter.TestHooks(
            afterEachProbeChunk: { count in
                observedChunks.withLock { $0 = count }
                signal.hook(count)
            })
        let exporter = MeetingSplitAudioExporter(testHooks: hooks)

        let task = Task {
            try await exporter.export(
                sourceFolderURL: folder,
                sourceAlignment: MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil),
                children: [
                    .init(
                        childId: UUID(), range: .init(startMs: 0, endMs: 60_000), destinationFolderURL: childDestination)
                ])
        }
        await signal.wait()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }

        let finalObservedChunkCount = observedChunks.withLock { $0 }
        XCTAssertLessThan(
            finalObservedChunkCount, 20,
            "the source probe must stop promptly on cancellation, not run to completion (~88 chunks) unattended")
        XCTAssertFalse(FileManager.default.fileExists(atPath: childDestination.path))
    }

    // MARK: - Opt-in hour-scale benchmark (not run by default)

    /// Bounded harness for the host to measure time/memory/disk on a
    /// synthetic hour-scale recording without needing personal recordings.
    /// Skipped unless explicitly requested.
    func testHourScaleExportBenchmarkIsOptIn() async throws {
        guard ProcessInfo.processInfo.environment["MACPARAKEET_SPLIT_EXPORT_BENCHMARK"] != nil else {
            throw XCTSkip(
                "Set MACPARAKEET_SPLIT_EXPORT_BENCHMARK=1 to run the opt-in hour-scale synthetic export benchmark.")
        }
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let hourMs = 60 * 60 * 1_000
        try writeToneM4AStreaming(
            to: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 16_000, durationMs: hourMs)
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        let exporter = MeetingSplitAudioExporter()
        let boundaries = [0, hourMs / 4, hourMs / 2, (hourMs * 3) / 4, hourMs]
        let children = (0..<4).map { index in
            MeetingSplitAudioChildRequest(
                childId: UUID(),
                range: .init(startMs: boundaries[index], endMs: boundaries[index + 1]),
                destinationFolderURL: destination.appendingPathComponent("part-\(index)"))
        }

        let start = Date()
        let results = try await exporter.export(
            sourceFolderURL: folder,
            sourceAlignment: MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil),
            children: children)
        let elapsed = Date().timeIntervalSince(start)
        let totalOutputBytes = results.reduce(into: Int64(0)) { $0 += $1.playback.sizeBytes }
        print(
            "MeetingSplitAudioExporter hour-scale benchmark: elapsed=\(elapsed)s "
                + "parts=\(results.count) totalOutputBytes=\(totalOutputBytes)")
        XCTAssertEqual(results.count, 4)
    }

    // MARK: - Assertion helpers

    private func assertTrack(
        _ track: MeetingSplitExportedTrack?,
        offsetMs: Int,
        durationMs: Int,
        sampleRate: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let track = try XCTUnwrap(track, file: file, line: line)
        XCTAssertEqual(track.startOffsetMs, offsetMs, "startOffsetMs", file: file, line: line)
        XCTAssertEqual(track.durationMs, durationMs, accuracy: 1, "durationMs", file: file, line: line)
        XCTAssertEqual(track.sampleRate, sampleRate, "sampleRate", file: file, line: line)
        XCTAssertGreaterThan(track.sizeBytes, 0, file: file, line: line)
    }

    /// Decodes a window of the child playback file and estimates its
    /// dominant frequency via zero-crossing rate, then checks it matches the
    /// tone the *global* source timeline should contain at that point. This
    /// is the "check actual decoded content, not only container duration"
    /// verification for boundary correctness.
    private func assertPlaybackFrequency(
        fileURL: URL,
        localWindowStartMs: Int,
        windowMs: Int,
        expectedGlobalMs: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let samples = try await MeetingCleanedMicRenderer.decodeMonoFloat(url: fileURL, sampleRate: 16_000)
        let sampleRate = 16_000.0
        let startIndex = Int(Double(localWindowStartMs) / 1_000 * sampleRate)
        let endIndex = min(samples.count, startIndex + Int(Double(windowMs) / 1_000 * sampleRate))
        guard endIndex > startIndex else {
            XCTFail("window out of range", file: file, line: line)
            return
        }
        let window = Array(samples[startIndex..<endIndex])
        let estimated = Self.estimateFrequency(window, sampleRate: sampleRate)
        let expected = Self.toneFrequency(atGlobalMs: expectedGlobalMs)
        XCTAssertEqual(
            estimated, expected, accuracy: expected * 0.25,
            "decoded content at local \(localWindowStartMs)ms should match global \(expectedGlobalMs)ms's tone",
            file: file, line: line)
    }

    private static func toneFrequency(atGlobalMs globalMs: Int) -> Double {
        220.0 + 110.0 * Double(globalMs / 1_000)
    }

    private static func estimateFrequency(_ samples: [Float], sampleRate: Double) -> Double {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for index in 1..<samples.count where (samples[index - 1] < 0) != (samples[index] < 0) {
            crossings += 1
        }
        let durationSeconds = Double(samples.count) / sampleRate
        guard durationSeconds > 0 else { return 0 }
        return Double(crossings) / (2 * durationSeconds)
    }

    private func sourceHashes(in folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            result[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meeting-split-audio-exporter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Fixture generation

    private func writeToneM4A(
        to url: URL,
        sampleRate: Double,
        durationMs: Int,
        globalStartMs: Int = 0
    ) throws {
        let frameCount = max(1, Int((Double(durationMs) * sampleRate / 1_000).rounded()))
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<frameCount {
            let globalMs = globalStartMs + Int(Double(index) / sampleRate * 1_000)
            let frequency = Self.toneFrequency(atGlobalMs: globalMs)
            samples[index] = Float(0.2 * sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
        try writeAAC(buffer: buffer, format: format, sampleRate: sampleRate, channels: 1, to: url)
    }

    /// Like `writeToneM4A`, but takes an exact frame count directly instead
    /// of a millisecond duration that gets rounded on the way to a frame
    /// count — needed to construct a fixture whose true decoded duration is
    /// deliberately fractional.
    private func writeToneM4AExactFrameCount(
        to url: URL,
        sampleRate: Double,
        frameCount: Int
    ) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<frameCount {
            let globalMs = Int(Double(index) / sampleRate * 1_000)
            let frequency = Self.toneFrequency(atGlobalMs: globalMs)
            samples[index] = Float(0.2 * sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
        try writeAAC(buffer: buffer, format: format, sampleRate: sampleRate, channels: 1, to: url)
    }

    /// Chunked variant for the opt-in hour-scale benchmark: never holds more
    /// than one buffer's worth of samples in memory.
    private func writeToneM4AStreaming(
        to url: URL,
        sampleRate: Double,
        durationMs: Int
    ) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let outputFile = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false)
        let totalFrames = max(1, Int((Double(durationMs) * sampleRate / 1_000).rounded()))
        let chunkFrames = 65_536
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)))
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        var written = 0
        while written < totalFrames {
            let count = min(chunkFrames, totalFrames - written)
            for localIndex in 0..<count {
                let globalIndex = written + localIndex
                let globalMs = Int(Double(globalIndex) / sampleRate * 1_000)
                let frequency = Self.toneFrequency(atGlobalMs: globalMs)
                channel[localIndex] = Float(0.2 * sin(2 * .pi * frequency * Double(globalIndex) / sampleRate))
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try outputFile.write(from: buffer)
            written += count
        }
    }

    private func writeAAC(
        buffer: AVAudioPCMBuffer,
        format: AVAudioFormat,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        to url: URL
    ) throws {
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false)
            try file.write(from: buffer)
        } catch {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatAppleLossless,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false)
            try file.write(from: buffer)
        }
    }
}

/// Deterministic cancellation-timing seam: lets a test await "the writer has
/// produced its Nth chunk" instead of racing a timer against cancellation.
private final class ChunkSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var reachedTarget = false
    private let target: Int

    init(target: Int) {
        self.target = target
    }

    func hook(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard count >= target, !reachedTarget else { return }
        reachedTarget = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if reachedTarget {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
