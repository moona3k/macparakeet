import ArgumentParser
import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import CLI
@testable import MacParakeetCore

/// Focused coverage for `meetings split`. Only the read-only `preview` and
/// `status`/`discard` paths are exercised end-to-end here: `create`/`resume`
/// build a real `TranscriptionService`/`STTClient`, which would attempt real
/// speech-to-text model loading — out of scope for this unit (see
/// `MeetingSplitServiceTests` for the mocked-STT end-to-end coverage of the
/// same Core service).
final class MeetingSplitCommandTests: XCTestCase {
    /// Matches `cliJSONEncoder`'s `.iso8601` date strategy.
    private static let cliJSONDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Argument parsing / validation

    func testCreateRequiresMatchingTitleCount() {
        XCTAssertThrowsError(
            try MeetingsCommand.SplitSubcommand.CreateSubcommand.parse([
                "some-meeting", "--cut", "1000", "--title", "Only one title",
            ])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("--title must be supplied"), String(describing: error))
        }
    }

    func testCreateDryRunAllowsOmittedTitles() throws {
        let command = try MeetingsCommand.SplitSubcommand.CreateSubcommand.parse([
            "some-meeting", "--cut", "1000", "--dry-run",
        ])
        XCTAssertTrue(command.dryRun)
        XCTAssertEqual(command.cut, [1000])
    }

    func testCreateRejectsJSONAndEnvelopeTogether() {
        XCTAssertThrowsError(
            try MeetingsCommand.SplitSubcommand.CreateSubcommand.parse([
                "some-meeting", "--cut", "1000", "--title", "A", "--title", "B", "--json", "--envelope",
            ])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("mutually exclusive"))
        }
    }

    func testStatusRequiresExactlyOneOfOperationIdOrSource() {
        XCTAssertThrowsError(try MeetingsCommand.SplitSubcommand.StatusSubcommand.parse([])) { error in
            XCTAssertTrue(String(describing: error).contains("Pass exactly one"), String(describing: error))
        }
        XCTAssertThrowsError(
            try MeetingsCommand.SplitSubcommand.StatusSubcommand.parse([
                "00000000-0000-0000-0000-000000000001", "--source", "some-meeting",
            ])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Pass exactly one"), String(describing: error))
        }
    }

    func testStatusBySourceParsesWithoutAnOperationIdArgument() throws {
        let command = try MeetingsCommand.SplitSubcommand.StatusSubcommand.parse(["--source", "some-meeting"])
        XCTAssertNil(command.operationId)
        XCTAssertEqual(command.source, "some-meeting")
    }

    func testResumeRejectsNonUUIDOperationId() {
        XCTAssertThrowsError(try MeetingsCommand.SplitSubcommand.ResumeSubcommand.parse(["not-a-uuid"])) { error in
            XCTAssertTrue(String(describing: error).contains("must be a UUID"), String(describing: error))
        }
    }

    func testDiscardRejectsNonUUIDOperationId() {
        XCTAssertThrowsError(try MeetingsCommand.SplitSubcommand.DiscardSubcommand.parse(["not-a-uuid"])) { error in
            XCTAssertTrue(String(describing: error).contains("must be a UUID"), String(describing: error))
        }
    }

    // MARK: - Default idempotency key: structured, not delimiter-joined

    func testDefaultIdempotencyKeyIsStableAcrossEquivalentCallsAndDiffersForDifferentTitleSplits() {
        XCTAssertEqual(
            MeetingsCommand.SplitSubcommand.CreateSubcommand.defaultIdempotencyKey(
                sourceId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                cuts: [1500], titles: ["Planning", "Review"]),
            "cli-split:aafb59286128b3a8833e6e698682e9519574a85c0bcf0a0cc9a7c89b9bac5514",
            "Canonical JSON ordering must make the retry key stable between processes"
        )
        let sourceId = UUID()
        let keyA = MeetingsCommand.SplitSubcommand.CreateSubcommand.defaultIdempotencyKey(
            sourceId: sourceId, cuts: [1_000], titles: ["Part 1", "Part 2"])
        let keyASecondCall = MeetingsCommand.SplitSubcommand.CreateSubcommand.defaultIdempotencyKey(
            sourceId: sourceId, cuts: [1_000], titles: ["Part 1", "Part 2"])
        XCTAssertEqual(keyA, keyASecondCall, "the same arguments must always derive the same key")

        // A delimiter-joined key would collide here: "Part 1|Part 2" split at
        // one point vs. two differently-arranged titles that happen to
        // concatenate the same way. The structured JSON payload keeps them
        // distinct because the array boundaries themselves are encoded.
        let keyWithDifferentTitleSplit = MeetingsCommand.SplitSubcommand.CreateSubcommand.defaultIdempotencyKey(
            sourceId: sourceId, cuts: [1_000], titles: ["Part 1|Part", " 2"])
        XCTAssertNotEqual(keyA, keyWithDifferentTitleSplit)
    }

    // MARK: - Preview end-to-end (read-only; no STT)

    func testPreviewPrintsJSONRangesForARealCanonicalOnlySource() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let folderURL = try makeSourceFolder(durationMs: 6_000)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let source = Transcription(
            fileName: "Standup recording",
            meetingArtifactFolderPath: folderURL.path,
            durationMs: 6_000,
            status: .completed,
            sourceType: .meeting
        )
        try harness.transcriptions.save(source)

        let command = try MeetingsCommand.SplitSubcommand.PreviewSubcommand.parse([
            source.id.uuidString, "--cut", "3000", "--json", "--database", harness.dbURL.path,
        ])
        let output = try await captureStandardOutput { try await command.run() }

        let preview = try Self.cliJSONDecoder.decode(MeetingSplitPreview.self, from: Data(output.utf8))
        XCTAssertEqual(preview.sourceId, source.id)
        XCTAssertEqual(preview.ranges.count, 2)
        XCTAssertEqual(preview.totalDurationMs, 6_000, accuracy: 1)
        XCTAssertFalse(preview.hasRawMicrophone)
    }

    func testPreviewNeverCreatesAnOperationOrWritesToTheSourceFolder() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let folderURL = try makeSourceFolder(durationMs: 4_000)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let source = Transcription(
            fileName: "Standup recording",
            meetingArtifactFolderPath: folderURL.path,
            durationMs: 4_000,
            status: .completed,
            sourceType: .meeting
        )
        try harness.transcriptions.save(source)
        let contentsBefore = try FileManager.default.contentsOfDirectory(atPath: folderURL.path).sorted()

        let command = try MeetingsCommand.SplitSubcommand.PreviewSubcommand.parse([
            source.id.uuidString, "--cut", "2000", "--json", "--database", harness.dbURL.path,
        ])
        _ = try await captureStandardOutput { try await command.run() }

        let contentsAfter = try FileManager.default.contentsOfDirectory(atPath: folderURL.path).sorted()
        XCTAssertEqual(contentsBefore, contentsAfter, "preview must not write into the source folder")

        let splitRepo = MeetingSplitRepository(dbQueue: harness.manager.dbQueue)
        XCTAssertEqual(try splitRepo.operations(sourceId: source.id).count, 0)
    }

    // MARK: - create --dry-run never writes/migrates/locks

    /// A read-only-opened database file proves `--dry-run` never even
    /// attempts a write: `makeMutatingSplitDatabaseManager` (which migrates
    /// and can create a lock file) would fail outright against a
    /// permission-denied file, while the readonly entry point succeeds.
    func testCreateDryRunSucceedsEvenWhenTheDatabaseFileIsReadOnlyOnDisk() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let folderURL = try makeSourceFolder(durationMs: 6_000)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let source = Transcription(
            fileName: "Standup recording",
            meetingArtifactFolderPath: folderURL.path,
            durationMs: 6_000,
            status: .completed,
            sourceType: .meeting
        )
        try harness.transcriptions.save(source)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: harness.dbURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: harness.dbURL.path) }

        let command = try MeetingsCommand.SplitSubcommand.CreateSubcommand.parse([
            source.id.uuidString, "--cut", "3000", "--dry-run", "--json", "--database", harness.dbURL.path,
        ])
        let output = try await captureStandardOutput { try await command.run() }

        let preview = try Self.cliJSONDecoder.decode(MeetingSplitPreview.self, from: Data(output.utf8))
        XCTAssertEqual(preview.sourceId, source.id)
        XCTAssertEqual(preview.ranges.count, 2)
    }

    func testCreateDryRunNeverPersistsAnOperation() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let folderURL = try makeSourceFolder(durationMs: 4_000)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let source = Transcription(
            fileName: "Standup recording",
            meetingArtifactFolderPath: folderURL.path,
            durationMs: 4_000,
            status: .completed,
            sourceType: .meeting
        )
        try harness.transcriptions.save(source)

        let command = try MeetingsCommand.SplitSubcommand.CreateSubcommand.parse([
            source.id.uuidString, "--cut", "2000", "--dry-run", "--json", "--database", harness.dbURL.path,
        ])
        _ = try await captureStandardOutput { try await command.run() }

        let splitRepo = MeetingSplitRepository(dbQueue: harness.manager.dbQueue)
        XCTAssertEqual(try splitRepo.operations(sourceId: source.id).count, 0, "dry-run must never persist a receipt")
    }

    // MARK: - Exact source UUID accepted without requiring findMeeting to succeed

    /// `create` must forward an exact source UUID straight to the Core
    /// service even when no row exists for it, instead of failing inside the
    /// CLI's own `findMeeting` lookup — the whole point of accepting a
    /// historical id for a committed-retry after deletion.
    func testCreateWithNonexistentExactUUIDReachesTheCoreServiceNotAnEarlyCLILookupFailure() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let missingSourceId = UUID()

        let command = try MeetingsCommand.SplitSubcommand.CreateSubcommand.parse([
            missingSourceId.uuidString, "--cut", "1000", "--title", "A", "--title", "B",
            "--database", harness.dbURL.path,
        ])
        do {
            try await command.run()
            XCTFail("expected the Core service to reject a truly nonexistent source")
        } catch MeetingSplitServiceError.sourceNotFound {
            // expected: reached the Core service, not `CLILookupError.notFound`
            // from `findMeeting` (which would throw before ever calling the
            // service, and for a different reason).
        }
    }

    func testStatusBySourceAcceptsExactUUIDAfterTheSourceRowIsDeleted() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let splitRepo = MeetingSplitRepository(dbQueue: harness.manager.dbQueue)
        let source = Transcription(fileName: "Standup recording", status: .completed, sourceType: .meeting)
        try harness.transcriptions.save(source)
        _ = try splitRepo.begin(
            idempotencyKey: "key-a",
            request: MeetingSplitRequest(
                sourceId: source.id, expectedSourceIdentity: "a",
                children: [MeetingSplitChildRequest(title: "Part 1", startMs: 0, endMs: 1_000)]
            )
        )
        _ = try harness.transcriptions.delete(id: source.id)

        let command = try MeetingsCommand.SplitSubcommand.StatusSubcommand.parse([
            "--source", source.id.uuidString, "--json", "--database", harness.dbURL.path,
        ])
        let output = try await captureStandardOutput { try await command.run() }
        let decoded = try Self.cliJSONDecoder.decode([MeetingSplitOperation].self, from: Data(output.utf8))
        XCTAssertEqual(decoded.count, 1, "discovery by exact historical source UUID must work after deletion")
    }

    // MARK: - Status / discard end-to-end (no STT: repository-only)

    func testStatusPrintsAPreparingOperationAndDiscardMarksItDiscarded() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let splitRepo = MeetingSplitRepository(dbQueue: harness.manager.dbQueue)
        let sourceId = UUID()
        let operation = try splitRepo.begin(
            idempotencyKey: "cli-test-key",
            request: MeetingSplitRequest(
                sourceId: sourceId,
                expectedSourceIdentity: "test",
                children: [MeetingSplitChildRequest(title: "Part 1", startMs: 0, endMs: 1_000)]
            )
        )

        let statusCommand = try MeetingsCommand.SplitSubcommand.StatusSubcommand.parse([
            operation.id.uuidString, "--json", "--database", harness.dbURL.path,
        ])
        let statusOutput = try await captureStandardOutput { try await statusCommand.run() }
        let decoded = try Self.cliJSONDecoder.decode(MeetingSplitOperation.self, from: Data(statusOutput.utf8))
        XCTAssertEqual(decoded.id, operation.id)
        XCTAssertEqual(decoded.status, .preparing)

        let discardCommand = try MeetingsCommand.SplitSubcommand.DiscardSubcommand.parse([
            operation.id.uuidString, "--json", "--database", harness.dbURL.path,
        ])
        let discardOutput = try await captureStandardOutput { try await discardCommand.run() }
        let discarded = try Self.cliJSONDecoder.decode(MeetingSplitOperation.self, from: Data(discardOutput.utf8))
        XCTAssertEqual(discarded.status, .discarded)
    }

    func testStatusBySourceListsEveryOperationForThatMeeting() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let splitRepo = MeetingSplitRepository(dbQueue: harness.manager.dbQueue)
        let source = Transcription(
            fileName: "Standup recording", status: .completed, sourceType: .meeting
        )
        try harness.transcriptions.save(source)
        _ = try splitRepo.begin(
            idempotencyKey: "key-a",
            request: MeetingSplitRequest(
                sourceId: source.id, expectedSourceIdentity: "a",
                children: [MeetingSplitChildRequest(title: "Part 1", startMs: 0, endMs: 1_000)]
            )
        )
        _ = try splitRepo.begin(
            idempotencyKey: "key-b",
            request: MeetingSplitRequest(
                sourceId: source.id, expectedSourceIdentity: "b",
                children: [MeetingSplitChildRequest(title: "Part 1", startMs: 0, endMs: 2_000)]
            )
        )

        let command = try MeetingsCommand.SplitSubcommand.StatusSubcommand.parse([
            "--source", source.id.uuidString, "--json", "--database", harness.dbURL.path,
        ])
        let output = try await captureStandardOutput { try await command.run() }
        let decoded = try Self.cliJSONDecoder.decode([MeetingSplitOperation].self, from: Data(output.utf8))
        XCTAssertEqual(decoded.count, 2)
    }

    // MARK: - Meeting-recordings root honors the CLI's own resolved defaults domain

    /// The CLI factory must resolve the split destination root from *its
    /// own* resolved preferences domain (`AppPaths.appDefaults()`), not
    /// `.standard` — otherwise a non-default `meetingArtifactsFolder`
    /// preference set in the app's shared suite is silently ignored by a
    /// standalone CLI process. Uses an isolated `UserDefaults` suite, never
    /// the real app preferences domain.
    func testSplitMeetingRecordingsRootURLHonorsACustomAppDefaultsFolderPreference() throws {
        let suiteName = "meeting-split-root-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let customFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-meeting-recordings-\(UUID().uuidString)").path
        defaults.set(customFolder, forKey: AppPaths.meetingArtifactsFolderKey)

        let rootURL = splitMeetingRecordingsRootURL(defaults: defaults)

        XCTAssertEqual(rootURL.path, customFolder)
    }

    /// With no folder preference set on this isolated suite, the CLI's root
    /// must still delegate to the exact same resolution
    /// `AppPaths.configuredMeetingRecordingsDir(defaults:)` performs (which
    /// itself owns the default-path/DEBUG-override fallback), never a
    /// separately reimplemented default.
    func testSplitMeetingRecordingsRootURLFallsBackToTheSharedDefaultResolution() throws {
        let suiteName = "meeting-split-root-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rootURL = splitMeetingRecordingsRootURL(defaults: defaults)

        XCTAssertEqual(rootURL.path, AppPaths.configuredMeetingRecordingsDir(defaults: defaults))
    }

    // MARK: - Retry guidance messages

    func testRetryGuidanceErrorMessagesNameTheActionableNextCommand() {
        let key = "cli-split:deadbeef"
        let operationId = UUID()

        XCTAssertTrue(
            MeetingSplitRetryGuidanceError.discardedKeyIsATombstone(idempotencyKey: key)
                .errorDescription!.contains("fresh --key")
        )
        XCTAssertTrue(
            MeetingSplitRetryGuidanceError.discardedOperationCannotResume(operationId: operationId)
                .errorDescription!.contains("meetings split create")
        )
        XCTAssertTrue(
            MeetingSplitRetryGuidanceError.stillPreparingRerunCreate(operationId: operationId)
                .errorDescription!.contains("meetings split create")
        )
    }

    // MARK: - Cooperative SIGINT / stdout-redirect composition (no STT)

    /// `create`/`resume` compose `withSIGINTCooperativeCancellation` around
    /// `withStandardOutputRedirectedToStandardError` in that exact nesting
    /// order; this exercises that same composition directly with a
    /// lightweight synthetic operation instead of a real STT call, proving
    /// stdout stays clean while the composed wrapper is active and the
    /// wrapped value still flows through normally.
    func testStandardOutputStaysRedirectedWhileTheSIGINTWrapperIsActive() async throws {
        var sawInnerValue = false
        let output = try await captureStandardOutput {
            let value = try await withSIGINTCooperativeCancellation {
                try await withStandardOutputRedirectedToStandardError {
                    print("a native model runtime writing straight to stdout must never reach the CLI payload")
                    return 42
                }
            }
            sawInnerValue = value == 42
        }
        XCTAssertTrue(sawInnerValue)
        XCTAssertTrue(output.isEmpty, "stdout must stay clean for the whole duration of the composed wrapper")
    }

    func testSIGINTWrapperPropagatesTheWrappedOperationsOwnThrownError() async {
        struct SentinelError: Error, Equatable {}
        do {
            let _: Int = try await withSIGINTCooperativeCancellation {
                throw SentinelError()
            }
            XCTFail("expected the wrapped operation's own error to propagate")
        } catch {
            XCTAssertEqual(error as? SentinelError, SentinelError())
        }
    }

    // MARK: - Real SIGINT delivery (opt-in; isolated child xctest process)

    private static let sigintChildStartedMarkerEnvironmentKey = "MACPARAKEET_SPLIT_SIGINT_CHILD_MARKER"

    /// Heavy, environment-sensitive end-to-end check: spawns a *separate*
    /// child `xctest` process running only
    /// `testSIGINTHelperChildProcessCancelsCooperativelyAndExits130` below,
    /// waits for it to signal it has installed the SIGINT handler, sends it
    /// a real `SIGINT`, and asserts *that child process* — never this test
    /// runner, the host, or any unrelated process — exits `130` rather than
    /// being abruptly terminated by the default disposition. Opt-in, mirroring
    /// `MeetingRecordingCrashRecoveryTests`'s own kill-9 integration test. Run
    /// with: MACPARAKEET_SPLIT_SIGINT_TESTS=1 swift test
    func testSIGINTCooperativelyCancelsAndExits130InAnIsolatedChildProcess() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPARAKEET_SPLIT_SIGINT_TESTS"] == "1",
            "Set MACPARAKEET_SPLIT_SIGINT_TESTS=1 to run the real-SIGINT integration test."
        )

        let markerPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-sigint-started-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: markerPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "CLITests.MeetingSplitCommandTests/testSIGINTHelperChildProcessCancelsCooperativelyAndExits130",
            Bundle(for: Self.self).bundleURL.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            Self.sigintChildStartedMarkerEnvironmentKey: markerPath,
        ]) { _, new in new }

        try process.run()
        try await waitForFile(atPath: markerPath)
        // A short buffer after the marker appears: the child writes it
        // immediately before installing the SIGINT handler, so this only
        // guards against the sub-millisecond gap between those two
        // statements, never a real wait for slow work.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(kill(process.processIdentifier, SIGINT), 0)
        process.waitUntilExit()

        XCTAssertEqual(
            process.terminationStatus, 130,
            "SIGINT must cooperatively cancel and exit 130, never the default abrupt termination"
        )
    }

    /// Inert (returns immediately) unless invoked as the targeted child
    /// process above with its marker-path environment variable set. Installs
    /// the real SIGINT handler via `withSIGINTCooperativeCancellation`
    /// around a long cooperative loop, mirroring `create`/`resume`'s own
    /// `catch is CancellationError { throw ExitCode(130) }` — but calls
    /// `Darwin.exit` directly since this child process is not itself driven
    /// through the CLI's `main()`/`ArgumentParser` dispatch.
    func testSIGINTHelperChildProcessCancelsCooperativelyAndExits130() async throws {
        guard let markerPath = ProcessInfo.processInfo.environment[Self.sigintChildStartedMarkerEnvironmentKey] else {
            return
        }
        FileManager.default.createFile(atPath: markerPath, contents: Data())
        do {
            _ = try await withSIGINTCooperativeCancellation { () async throws -> Int in
                // Even a callee that returns normally after cancellation
                // drains must not turn Ctrl-C into a successful CLI exit.
                try? await Task.sleep(for: .seconds(30))
                return 0
            }
        } catch is CancellationError {
            Darwin.exit(130)
        }
        Darwin.exit(1)
    }

    private struct SIGINTChildTimeoutError: Error {}

    private func waitForFile(atPath path: String, timeoutSeconds: Double = 10) async throws {
        let startedAt = ContinuousClock.now
        while !FileManager.default.fileExists(atPath: path) {
            if startedAt.duration(to: .now) > .seconds(timeoutSeconds) {
                throw SIGINTChildTimeoutError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Helpers

    private func makeHarness() throws -> Harness {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-split-\(UUID().uuidString).db")
        let manager = try DatabaseManager(path: dbURL.path)
        return Harness(dbURL: dbURL, manager: manager, transcriptions: TranscriptionRepository(dbQueue: manager.dbQueue))
    }

    private struct Harness {
        let dbURL: URL
        let manager: DatabaseManager
        let transcriptions: TranscriptionRepository

        func cleanup() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbURL.path)
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(atPath: dbURL.path + ".migration.lock")
        }
    }

    private func makeSourceFolder(durationMs: Int) throws -> URL {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-split-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try writeToneM4A(
            to: folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000, durationMs: durationMs
        )
        return folderURL
    }

    private func writeToneM4A(to url: URL, sampleRate: Double, durationMs: Int) throws {
        let frameCount = max(1, Int((Double(durationMs) * sampleRate / 1_000).rounded()))
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<frameCount {
            samples[index] = Float(0.2 * sin(2 * .pi * 440 * Double(index) / sampleRate))
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}
