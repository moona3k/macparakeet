import Foundation
import XCTest
@testable import MacParakeetCore

final class MeetingRecordingCaptureTests: XCTestCase {
    func testUnreadableLockReconstructionDoesNotClaimOrModifyArtifacts() throws {
        for bytes in [Data(), Data("{broken".utf8)] {
            let folder = try makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let lockURL = MeetingRecordingLockFileStore.lockFileURL(for: folder)
            try bytes.write(to: lockURL)

            let capture = try MeetingRecordingCapture.load(from: folder)

            XCTAssertEqual(capture.lock.state, .awaitingTranscription)
            XCTAssertEqual(capture.lock.pid, 0)
            XCTAssertNil(capture.lock.finalizationLeaseId)
            XCTAssertEqual(try Data(contentsOf: lockURL), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: capture.mixedAudioURL.path))
        }
    }

    func testMissingLockCannotBeReconstructed() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertThrowsError(try MeetingRecordingCapture.load(from: folder)) { error in
            XCTAssertEqual(error as? MeetingFinalizationOwnershipError, .missingLock)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: MeetingRecordingLockFileStore.lockFileURL(for: folder).path))
    }

    func testRecordingLockCannotBeReconstructedForFinalization() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let lock = MeetingRecordingLockFile(
            sessionId: UUID(), startedAt: Date(), displayName: "Active capture",
            state: .recording, folderURL: folder
        )
        try MeetingRecordingLockFileStore().write(lock, folderURL: folder)
        let lockURL = MeetingRecordingLockFileStore.lockFileURL(for: folder)
        let originalBytes = try Data(contentsOf: lockURL)

        XCTAssertThrowsError(try MeetingRecordingCapture.load(from: folder)) { error in
            guard case MeetingRecordingRecoveryError.writerFinalizationInProgress = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: lockURL), originalBytes)
    }

    func testLiveFutureSchemaLockCannotBeReconstructedOrRewritten() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pid = ProcessInfo.processInfo.processIdentifier
        let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 999, "pid": Int(pid)])
        let lockURL = MeetingRecordingLockFileStore.lockFileURL(for: folder)
        try bytes.write(to: lockURL)

        XCTAssertThrowsError(try MeetingRecordingCapture.load(from: folder)) { error in
            XCTAssertEqual(error as? MeetingFinalizationOwnershipError, .ownedByLiveProcess(pid: pid))
        }
        XCTAssertEqual(try Data(contentsOf: lockURL), bytes)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(
                sourceAlignment: MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil)
            ), folderURL: folder
        )
        return folder
    }
}
