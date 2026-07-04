import Foundation
import XCTest
@testable import MacParakeetCore

final class MeetingRecordingSettlementTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecordingSettlementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testRefusesWhenTranscriptionRowIsMissing() async throws {
        let repo = MockTranscriptionRepository()
        let lockStore = SettlementLockFileStore()
        let settlement = MeetingRecordingSettlement(lockFileStore: lockStore, transcriptionRepo: repo)

        do {
            try await settlement.settleCompletedTranscription(
                folderURL: makeFolderURL(),
                transcriptionID: UUID(),
                sessionID: UUID()
            )
            XCTFail("Expected settlement to refuse a missing transcription row")
        } catch {
            XCTAssertTrue(error is MeetingRecordingSettlementError)
            XCTAssertTrue(lockStore.deletes.isEmpty)
        }
    }

    func testRefusesWhenTranscriptionRowIsNotCompleted() async throws {
        for status in [
            Transcription.TranscriptionStatus.processing,
            .error,
            .cancelled,
        ] {
            let repo = MockTranscriptionRepository()
            let lockStore = SettlementLockFileStore()
            let settlement = MeetingRecordingSettlement(lockFileStore: lockStore, transcriptionRepo: repo)
            let folderURL = makeFolderURL()
            let transcription = makeTranscription(status: status, folderURL: folderURL)
            try repo.save(transcription)

            do {
                try await settlement.settleCompletedTranscription(
                    folderURL: folderURL,
                    transcriptionID: transcription.id,
                    sessionID: UUID()
                )
                XCTFail("Expected settlement to refuse \(status.rawValue) transcription row")
            } catch {
                XCTAssertTrue(error is MeetingRecordingSettlementError)
                XCTAssertTrue(lockStore.deletes.isEmpty)
            }
        }
    }

    func testDeletesLockWhenTranscriptionRowIsCompleted() async throws {
        let repo = MockTranscriptionRepository()
        let lockStore = SettlementLockFileStore()
        let settlement = MeetingRecordingSettlement(lockFileStore: lockStore, transcriptionRepo: repo)
        let folderURL = makeFolderURL()
        let transcription = makeTranscription(status: .completed, folderURL: folderURL)
        try repo.save(transcription)

        try await settlement.settleCompletedTranscription(
            folderURL: folderURL,
            transcriptionID: transcription.id,
            sessionID: UUID()
        )

        XCTAssertEqual(lockStore.deletes, [folderURL])
    }

    func testLockDeleteErrorIsLogOnly() async throws {
        let repo = MockTranscriptionRepository()
        let lockStore = SettlementLockFileStore(errorToThrow: SettlementTestError.deleteFailed)
        let settlement = MeetingRecordingSettlement(lockFileStore: lockStore, transcriptionRepo: repo)
        let folderURL = makeFolderURL()
        let transcription = makeTranscription(status: .completed, folderURL: folderURL)
        try repo.save(transcription)

        try await settlement.settleCompletedTranscription(
            folderURL: folderURL,
            transcriptionID: transcription.id,
            sessionID: UUID()
        )

        XCTAssertEqual(lockStore.deletes, [folderURL])
    }

    private func makeFolderURL() -> URL {
        tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeTranscription(
        status: Transcription.TranscriptionStatus,
        folderURL: URL
    ) -> Transcription {
        Transcription(
            fileName: "Recovered Team Sync",
            filePath: folderURL.appendingPathComponent("meeting.m4a").path,
            meetingArtifactFolderPath: folderURL.path,
            status: status,
            sourceType: .meeting
        )
    }
}

private enum SettlementTestError: Error {
    case deleteFailed
}

private final class SettlementLockFileStore: MeetingRecordingLockFileStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let errorToThrow: Error?
    private(set) var deletes: [URL] = []

    init(errorToThrow: Error? = nil) {
        self.errorToThrow = errorToThrow
    }

    func write(_ file: MeetingRecordingLockFile, folderURL: URL) throws {}

    func read(folderURL: URL) throws -> MeetingRecordingLockFile? { nil }

    func delete(folderURL: URL) throws {
        lock.withLock {
            deletes.append(folderURL)
        }
        if let errorToThrow {
            throw errorToThrow
        }
    }

    func discoverOrphans(meetingsRoot: URL) throws -> [MeetingRecordingLockFile] { [] }
}
