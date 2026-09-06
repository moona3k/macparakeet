import CoreAudio
import Darwin
import XCTest
@testable import MacParakeetCore

final class AudioCaptureDiagnosticsTests: XCTestCase {
    func testAppendUsesTemporaryLogUnderXCTest() async throws {
        let logURL = AudioCaptureDiagnostics.diagnosticLogURL()
        let marker = "unit_test_diagnostic_marker_\(UUID().uuidString)"

        AudioCaptureDiagnostics.append(marker)
        await AudioCaptureDiagnostics.flushPendingAppends()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(logURL.path.contains("MacParakeetTests/Logs"))
        XCTAssertFalse(logURL.path.hasPrefix(AppPaths.logsDir))
        XCTAssertTrue(contents.contains(marker))
    }

    func testDeviceLabelDoesNotExposeRawDeviceID() {
        let label = AudioCaptureDiagnostics.deviceLabel(AudioDeviceID(12345))

        XCTAssertEqual(label, "present")
        XCTAssertFalse(label.contains("12345"))
    }

    func testDiagnosticMessageSanitizerStripsPathsAndURLs() {
        let message = "failed path=/Users/alex/Secret/file.wav\nurl=https://example.com/watch?v=abc"

        let sanitized = AudioCaptureDiagnostics.sanitizedMessage(message)

        XCTAssertFalse(sanitized.contains("/Users/alex"))
        XCTAssertFalse(sanitized.contains("https://example.com"))
        XCTAssertTrue(sanitized.contains("<path>"))
        XCTAssertTrue(sanitized.contains("<url>"))
    }

    func testDiagnosticMessageSanitizerKeepsSingleLogLine() {
        let message = "first line\nsecond line\r\nthird line"

        let sanitized = AudioCaptureDiagnostics.sanitizedMessage(message)

        XCTAssertFalse(sanitized.contains("\n"))
        XCTAssertFalse(sanitized.contains("\r"))
        XCTAssertEqual(sanitized, "first line second line third line")
    }

    func testErrorFieldsRetainBridgedCodeWithoutArbitraryContent() {
        let error = NSError(
            domain: NSOSStatusErrorDomain,
            code: -10875,
            userInfo: [NSLocalizedDescriptionKey: "private spoken words api_key=do-not-share"]
        )

        let fields = AudioCaptureDiagnostics.errorFields(error)

        XCTAssertTrue(fields.contains("error_type=NSOSStatusErrorDomain.-10875"))
        XCTAssertTrue(fields.contains("bridged_error_code=-10875"))
        XCTAssertFalse(fields.contains("private spoken words"))
        XCTAssertFalse(fields.contains("api_key"))
        XCTAssertFalse(fields.contains("error_detail"))
    }

    func testWrappedCoreAudioErrorKeepsStatusDistinctFromItsBridgeCode() {
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -10868)
        let wrapped = SharedMicrophoneStream.SubscribeError.engineStartFailed(underlying.localizedDescription)

        let fields = AudioCaptureDiagnostics.errorFields(wrapped).split(separator: " ")

        XCTAssertTrue(fields.contains("error_type=SubscribeError.engineStartFailed.NSOSStatusErrorDomain.-10868"))
        XCTAssertTrue(fields.contains("bridged_error_code=0"))
        XCTAssertFalse(fields.contains { $0.hasPrefix("error_code=") })
    }

    func testRetainedLogSuffixKeepsNewestCompleteLines() throws {
        let original = try XCTUnwrap(
            "first line\nmiddle line\nlatest one\nlatest two\n".data(using: .utf8)
        )

        let retained = AudioCaptureDiagnostics.retainedLogSuffix(original, maxBytes: 25)

        XCTAssertEqual(String(data: retained, encoding: .utf8), "latest one\nlatest two\n")
    }

    func testRetainedLogSuffixDropsAnOversizedIncompleteLine() throws {
        let original = try XCTUnwrap(String(repeating: "é", count: 32).data(using: .utf8))

        let retained = AudioCaptureDiagnostics.retainedLogSuffix(original, maxBytes: 17)

        XCTAssertTrue(retained.isEmpty)
    }

    func testRetainedLogSuffixPreservesLineExactlyAtByteBoundary() {
        let original = Data("old\nnewest\n".utf8)

        let retained = AudioCaptureDiagnostics.retainedLogSuffix(original, maxBytes: 7)

        XCTAssertEqual(String(decoding: retained, as: UTF8.self), "newest\n")
    }

    func testRetainedLogSuffixDoesNotSplitMultibyteText() {
        let original = Data("old\nééé\nlatest\n".utf8)

        let retained = AudioCaptureDiagnostics.retainedLogSuffix(original, maxBytes: 10)

        XCTAssertEqual(String(decoding: retained, as: UTF8.self), "latest\n")
    }

    func testEncodedLinePreservesEventTimeAndAddsProcessCorrelation() throws {
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let data = AudioCaptureDiagnostics.encodedLogLine(
            "dictation_capture_first_buffer frames=480",
            timestamp: timestamp,
            uptimeNanoseconds: 123_456_789
        )
        let line = String(decoding: data, as: UTF8.self)
        let fields = line.split(whereSeparator: \.isWhitespace)

        XCTAssertEqual(fields[0], "2026-05-28T20:26:40.000Z")
        XCTAssertEqual(fields[1], "dictation_capture_first_buffer")
        XCTAssertTrue(fields.contains("frames=480"))
        XCTAssertTrue(fields.contains("process_id=\(ProcessInfo.processInfo.processIdentifier)"))
        XCTAssertTrue(fields.contains("uptime_ns=123456789"))
        let sessionField = try XCTUnwrap(fields.first { $0.hasPrefix("process_session=") })
        let sessionID = String(sessionField.dropFirst("process_session=".count))
        XCTAssertNotNil(UUID(uuidString: sessionID))

        let second = String(
            decoding: AudioCaptureDiagnostics.encodedLogLine(
                "dictation_capture_stop",
                timestamp: timestamp,
                uptimeNanoseconds: 987_654_321
            ),
            as: UTF8.self
        )
        XCTAssertTrue(second.contains(String(sessionField)), "One process must retain the same correlation ID")
        XCTAssertTrue(line.hasSuffix("\n"))
    }

    func testWritePreservesExistingHistoryWhenLogCannotBeOpenedForAppend() throws {
        let logURL = try temporaryLogURL()
        let original = Data("existing diagnostic history\n".utf8)
        try original.write(to: logURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: logURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        }
        // Running as root bypasses mode bits, so this failure cannot be induced.
        guard !FileManager.default.isWritableFile(atPath: logURL.path) else {
            throw XCTSkip("The process can write read-only files")
        }

        XCTAssertThrowsError(try AudioCaptureDiagnostics.writeLogLine(Data("new event\n".utf8), to: logURL))

        XCTAssertEqual(try Data(contentsOf: logURL), original)
    }

    func testWriteCreatesAndAppendsWithoutLosingHistory() throws {
        let logURL = try temporaryLogURL()

        try AudioCaptureDiagnostics.writeLogLine(Data("first\n".utf8), to: logURL)
        try AudioCaptureDiagnostics.writeLogLine(Data("second\n".utf8), to: logURL)

        XCTAssertEqual(try String(contentsOf: logURL, encoding: .utf8), "first\nsecond\n")
    }

    func testWriteCompactsHistoryAtDiskCapAndKeepsNewestEntry() throws {
        let logURL = try temporaryLogURL()
        try AudioCaptureDiagnostics.writeLogLine(Data("initial event\n".utf8), to: logURL)
        let lockURL = logURL.appendingPathExtension("lock")
        let originalLockInode =
            try FileManager.default.attributesOfItem(atPath: lockURL.path)[.systemFileNumber] as? NSNumber
        let original = Data(String(repeating: "older event\n", count: 450_000).utf8)
        try original.write(to: logURL)
        let newest = Data("newest event\n".utf8)

        try AudioCaptureDiagnostics.writeLogLine(newest, to: logURL)

        let result = try Data(contentsOf: logURL)
        XCTAssertLessThanOrEqual(result.count, Int(AudioCaptureDiagnostics.diagnosticLogMaxBytes))
        XCTAssertTrue(result.starts(with: Data("older event\n".utf8)))
        XCTAssertTrue(result.suffix(newest.count).elementsEqual(newest))
        XCTAssertLessThan(result.count, original.count)
        let lockInode = try FileManager.default.attributesOfItem(atPath: lockURL.path)[.systemFileNumber] as? NSNumber
        XCTAssertNotNil(originalLockInode)
        XCTAssertEqual(lockInode, originalLockInode, "Rotation must preserve the shared lock inode")
    }

    func testSiblingLockExcludesAnotherHandleAndReleasesAfterFailure() throws {
        let logURL = try temporaryLogURL()
        let lockURL = logURL.appendingPathExtension("lock")
        let competingDescriptor = Darwin.open(lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(competingDescriptor, 0)
        guard competingDescriptor >= 0 else { return }
        defer { _ = Darwin.close(competingDescriptor) }
        enum TestFailure: Error { case expected }

        XCTAssertThrowsError(
            try AudioCaptureDiagnostics.withLogFileLock(at: logURL) {
                let attempt = flock(competingDescriptor, LOCK_EX | LOCK_NB)
                let code = errno
                XCTAssertEqual(attempt, -1)
                XCTAssertEqual(code, EWOULDBLOCK)
                throw TestFailure.expected
            })

        XCTAssertEqual(flock(competingDescriptor, LOCK_EX | LOCK_NB), 0, "Throwing must release the lock")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path), "The stable lock file must remain")
    }

    func testConcurrentWriterHandlesPreserveEntriesAcrossRotation() async throws {
        let logURL = try temporaryLogURL()
        let oldData = Data(String(repeating: "older event\n", count: 450_000).utf8)
        try oldData.write(to: logURL)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<2 {
                group.addTask {
                    for sequence in 0..<100 {
                        let data = Data("writer=\(writer) sequence=\(sequence)\n".utf8)
                        try AudioCaptureDiagnostics.writeLogLine(data, to: logURL)
                    }
                }
            }
            try await group.waitForAll()
        }

        let result = try String(contentsOf: logURL, encoding: .utf8)
        let actual = result.split(separator: "\n").filter { $0.hasPrefix("writer=") }.map(String.init)
        let expected = (0..<2).flatMap { writer in
            (0..<100).map { "writer=\(writer) sequence=\($0)" }
        }
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertEqual(Set(actual), Set(expected))
        XCTAssertLessThanOrEqual(result.utf8.count, Int(AudioCaptureDiagnostics.diagnosticLogMaxBytes))
    }

    func testMainThreadContentionDefersTheOriginalRecordUntilLockRelease() async throws {
        let logURL = try temporaryLogURL()
        let lockURL = logURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return XCTFail("Cannot open test lock") }
        defer { _ = Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        defer { _ = flock(descriptor, LOCK_UN) }
        let original = AudioCaptureDiagnostics.encodedLogLine(
            "capture_stop frames=480", timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            uptimeNanoseconds: 123_456_789
        )

        // This call must return while the other descriptor still owns the lock.
        await MainActor.run {
            AudioCaptureDiagnostics.appendEncodedLogLine(original, to: logURL)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        await AudioCaptureDiagnostics.flushPendingAppends()

        XCTAssertEqual(try Data(contentsOf: logURL), original)
    }

    func testMainThreadRotationDefersTheOriginalRecordWithoutRewritingHistoryInline() async throws {
        let logURL = try temporaryLogURL()
        let history = Data(String(repeating: "older event\n", count: 450_000).utf8)
        try history.write(to: logURL)
        let original = AudioCaptureDiagnostics.encodedLogLine(
            "capture_stop frames=480", timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            uptimeNanoseconds: 123_456_789
        )

        XCTAssertThrowsError(try AudioCaptureDiagnostics.writeLogLine(
            original, to: logURL, waitForLock: false, allowRotation: false
        ))
        XCTAssertEqual(try Data(contentsOf: logURL), history)

        await MainActor.run {
            AudioCaptureDiagnostics.appendEncodedLogLine(original, to: logURL)
        }
        await AudioCaptureDiagnostics.flushPendingAppends()

        let persisted = try Data(contentsOf: logURL)
        XCTAssertLessThanOrEqual(persisted.count, Int(AudioCaptureDiagnostics.diagnosticLogMaxBytes))
        XCTAssertTrue(persisted.starts(with: Data("older event\n".utf8)))
        XCTAssertTrue(persisted.suffix(original.count).elementsEqual(original))
    }

    private func temporaryLogURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioCaptureDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("dictation-audio.log")
    }
}
