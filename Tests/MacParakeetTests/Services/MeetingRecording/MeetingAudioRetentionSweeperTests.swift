import Foundation
import XCTest

@testable import MacParakeetCore

final class MeetingAudioRetentionSweeperTests: XCTestCase {
    private var repo: TranscriptionRepository!
    private var rootURL: URL!
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = TranscriptionRepository(dbQueue: manager.dbQueue)
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-retention-sweeper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
        repo = nil
    }

    func testSweepDetachesEligibleMeetingAudioAndKeepsTranscriptRow() throws {
        let eligible = try makeMeeting(ageDays: 31, recoveredFromCrash: true)
        let lockedRecording = try makeMeeting(ageDays: 31, lockState: .recording)
        let lockedAwaiting = try makeMeeting(ageDays: 31, lockState: .awaitingTranscription)
        try repo.save(eligible.transcription)
        try repo.save(lockedRecording.transcription)
        try repo.save(lockedAwaiting.transcription)

        let result = try MeetingAudioRetentionSweeper(repository: repo)
            .sweep(retention: .deleteAfterDays(30), now: now)

        XCTAssertEqual(result.evaluatedCount, 3)
        XCTAssertEqual(result.eligibleCount, 1)
        XCTAssertEqual(result.detachedCount, 1)
        XCTAssertEqual(result.skippedLockedCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: eligible.folderURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: eligible.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: MeetingRecordingMetadataStore.metadataURL(for: eligible.folderURL).path
        ))
        let retainedOut = try XCTUnwrap(repo.fetch(id: eligible.transcription.id))
        XCTAssertNil(retainedOut.filePath)
        XCTAssertEqual(retainedOut.meetingArtifactFolderPath, eligible.folderURL.standardizedFileURL.path)
        XCTAssertNotNil(try repo.fetch(id: eligible.transcription.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockedRecording.folderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockedAwaiting.folderURL.path))
        XCTAssertEqual(try repo.fetch(id: lockedRecording.transcription.id)?.filePath, lockedRecording.audioURL.path)
        XCTAssertEqual(try repo.fetch(id: lockedAwaiting.transcription.id)?.filePath, lockedAwaiting.audioURL.path)
    }

    func testSweepSkipsUnmanagedMeetingAudioPath() throws {
        let externalPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-meeting-\(UUID().uuidString).m4a")
            .path
        let external = Transcription(
            createdAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            fileName: "external",
            filePath: externalPath,
            status: .completed,
            sourceType: .meeting,
            updatedAt: now.addingTimeInterval(-31 * 24 * 60 * 60)
        )
        try repo.save(external)

        let result = try MeetingAudioRetentionSweeper(repository: repo)
            .sweep(retention: .deleteAfterDays(30), now: now)

        XCTAssertEqual(result.eligibleCount, 1)
        XCTAssertEqual(result.detachedCount, 0)
        XCTAssertEqual(result.skippedUnmanagedCount, 1)
        XCTAssertEqual(try repo.fetch(id: external.id)?.filePath, externalPath)
    }

    func testSweepSkipsAnyRecordingLockFileEvenWhenUnreadable() throws {
        let zeroByte = try makeMeeting(ageDays: 31, rawLockData: Data())
        let corrupt = try makeMeeting(ageDays: 31, rawLockData: Data("{not-json".utf8))
        let futureSchema = try makeMeeting(ageDays: 31, rawLockData: Data("""
        {
          "schemaVersion": 999,
          "sessionId": "\(UUID().uuidString)",
          "startedAt": "2026-06-19T12:00:00Z",
          "pid": -1,
          "displayName": "Future Session",
          "state": "awaitingTranscription"
        }
        """.utf8))
        let eligible = try makeMeeting(ageDays: 31)
        for meeting in [zeroByte, corrupt, futureSchema, eligible] {
            try repo.save(meeting.transcription)
        }

        let result = try MeetingAudioRetentionSweeper(repository: repo)
            .sweep(retention: .deleteAfterDays(30), now: now)

        XCTAssertEqual(result.evaluatedCount, 4)
        XCTAssertEqual(result.skippedLockedCount, 3)
        XCTAssertEqual(result.eligibleCount, 1)
        XCTAssertEqual(result.detachedCount, 1)
        for locked in [zeroByte, corrupt, futureSchema] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: locked.folderURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: locked.audioURL.path))
            XCTAssertEqual(try repo.fetch(id: locked.transcription.id)?.filePath, locked.audioURL.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: eligible.folderURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: eligible.audioURL.path))
        XCTAssertNil(try repo.fetch(id: eligible.transcription.id)?.filePath)
    }

    private func makeMeeting(
        ageDays: Int,
        recoveredFromCrash: Bool = false,
        lockState: MeetingRecordingLockState? = nil,
        rawLockData: Data? = nil
    ) throws -> (transcription: Transcription, folderURL: URL, audioURL: URL) {
        let folderURL = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let audioURL = folderURL.appendingPathComponent("meeting.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: MeetingRecordingMetadataStore.metadataURL(for: folderURL).path,
            contents: Data("{}".utf8)
        ))

        if let lockState {
            try MeetingRecordingLockFileStore().write(
                MeetingRecordingLockFile(
                    sessionId: UUID(),
                    startedAt: now.addingTimeInterval(-TimeInterval(ageDays * 24 * 60 * 60)),
                    pid: -1,
                    displayName: "Locked",
                    state: lockState
                ),
                folderURL: folderURL
            )
        }
        if let rawLockData {
            try rawLockData.write(to: MeetingRecordingLockFileStore.lockFileURL(for: folderURL))
        }

        return (
            Transcription(
                createdAt: now.addingTimeInterval(-TimeInterval(ageDays * 24 * 60 * 60)),
                fileName: "Meeting",
                filePath: audioURL.path,
                rawTranscript: "",
                status: .completed,
                sourceType: .meeting,
                recoveredFromCrash: recoveredFromCrash,
                updatedAt: now.addingTimeInterval(-TimeInterval(ageDays * 24 * 60 * 60))
            ),
            folderURL,
            audioURL
        )
    }
}
