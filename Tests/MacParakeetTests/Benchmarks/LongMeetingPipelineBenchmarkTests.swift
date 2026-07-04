import AVFoundation
import Darwin
import XCTest
@testable import MacParakeetCore

/// Env-gated full post-stop meeting pipeline benchmark.
///
/// Default `swift test` skips this test immediately. Run with a retained
/// metadata-backed dual-track meeting session folder:
///
///   MACPARAKEET_LONG_MEETING_PIPELINE_BENCH=1 \
///   MACPARAKEET_LONG_MEETING_SESSION="/Users/dmoon/Library/Application Support/MacParakeet/meeting-recordings/<session-id>" \
///   MACPARAKEET_TEST_LOCALVQE_LIBRARY=/path/to/liblocalvqe.dylib \
///   MACPARAKEET_TEST_LOCALVQE_MODEL=/path/to/localvqe-v1.4-aec-200K-f32.gguf \
///   MACPARAKEET_LONG_MEETING_RESULTS_FILE=.codex/long-meeting-pipeline-bench/results.md \
///   swift test --filter LongMeetingPipelineBenchmarkTests
///
/// The harness copies the source session into `MACPARAKEET_LONG_MEETING_WORK_DIR`
/// or `.codex/long-meeting-pipeline-bench/runs/<uuid>` before writing any derived
/// artifacts. It appends a pasteable markdown table to the results file.
///
/// If no retained fixture is available, an explicit synthetic smoke fixture can
/// be generated instead:
///
///   MACPARAKEET_LONG_MEETING_PIPELINE_BENCH=1 \
///   MACPARAKEET_LONG_MEETING_SYNTHETIC_SECONDS=30 \
///   MACPARAKEET_TEST_LOCALVQE_LIBRARY=/path/to/liblocalvqe.dylib \
///   MACPARAKEET_TEST_LOCALVQE_MODEL=/path/to/localvqe-v1.4-aec-200K-f32.gguf \
///   swift test --filter LongMeetingPipelineBenchmarkTests
final class LongMeetingPipelineBenchmarkTests: XCTestCase {
    private static let enabledKey = "MACPARAKEET_LONG_MEETING_PIPELINE_BENCH"
    private static let sessionKey = "MACPARAKEET_LONG_MEETING_SESSION"
    private static let syntheticSecondsKey = "MACPARAKEET_LONG_MEETING_SYNTHETIC_SECONDS"
    private static let workDirKey = "MACPARAKEET_LONG_MEETING_WORK_DIR"
    private static let resultsFileKey = "MACPARAKEET_LONG_MEETING_RESULTS_FILE"
    private static let parakeetVariantKey = "MACPARAKEET_LONG_MEETING_PARAKEET_VARIANT"
    private static let localVQELibraryKey = "MACPARAKEET_TEST_LOCALVQE_LIBRARY"
    private static let localVQEModelKey = "MACPARAKEET_TEST_LOCALVQE_MODEL"
    private static let localVQEModelSHAKey = "MACPARAKEET_TEST_LOCALVQE_MODEL_SHA256"

    func testDefaultDualTrackMeetingPostStopPipelineBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env[Self.enabledKey] == "1",
            "Set \(Self.enabledKey)=1 to run the long-meeting full-pipeline benchmark."
        )

        let runID = ISO8601DateFormatter().string(from: Date())
        let fixture = try await makeFixture(env: env, runID: runID)
        let recording = try await loadRecording(from: fixture.folderURL)
        try preflightModelsAndAssets(recording: recording, env: env)

        let collector = StageMetricsCollector(recordingDurationSeconds: recording.durationSeconds)
        let cleanedRecording = try await renderCleanedMicrophone(
            recording: recording,
            env: env,
            collector: collector
        )

        let repository = BenchmarkTranscriptionRepository()
        let service = makeBenchmarkService(
            recording: cleanedRecording,
            env: env,
            repository: repository,
            collector: collector
        )
        let queued = try await service.prepareMeetingTranscription(recording: cleanedRecording)
        _ = try await service.finalizeMeetingTranscription(
            recording: cleanedRecording,
            updating: queued.id,
            onProgress: nil
        )

        let rows = collector.rows()
        XCTAssertFalse(rows.isEmpty)
        let table = renderMarkdownTable(
            runID: runID,
            fixture: fixture,
            recording: cleanedRecording,
            rows: rows
        )
        print("\n\(table)\n")
        try append(table: table, env: env)
    }

    private func makeBenchmarkService(
        recording: MeetingRecordingOutput,
        env: [String: String],
        repository: BenchmarkTranscriptionRepository,
        collector: StageMetricsCollector
    ) -> TranscriptionService {
        let parakeetVariant = Self.parakeetVariant(from: env)
        let sttClient = STTClient(
            parakeetModelVariant: parakeetVariant,
            speechEngine: recording.speechEngine.engine,
            nemotronModelVariant: SpeechEnginePreference.nemotronModelVariant(),
            whisperModelVariant: SpeechEnginePreference.whisperModelVariant()
        )
        let observer = MeetingFinalizationBenchmarkObserver(
            onStageStart: { stage in
                collector.begin(stage.markdownName)
            },
            onStageEnd: { stage in
                collector.end(stage.markdownName)
            }
        )

        return TranscriptionService(
            audioProcessor: AudioProcessor(),
            sttTranscriber: sttClient,
            transcriptionRepo: repository,
            processingMode: { .raw },
            shouldUseAIFormatter: { false },
            shouldAutoGenerateMeetingTitles: { false },
            shouldDiarize: { true },
            diarizationService: DiarizationService(),
            meetingArtifactStore: nil,
            meetingAutomationHookRunner: nil,
            meetingCleanedMicrophoneReadinessPolicy: .production,
            meetingFinalizationBenchmarkObserver: observer
        )
    }

    private func renderCleanedMicrophone(
        recording: MeetingRecordingOutput,
        env: [String: String],
        collector: StageMetricsCollector
    ) async throws -> MeetingRecordingOutput {
        let outputURL = recording.folderURL.appendingPathComponent(
            MeetingCleanedMicRenderer.cleanedMicrophoneFileName)
        let readiness = try await collector.measure(stage: "decode+aec_render") {
            let readiness = MeetingCleanedMicrophoneRenderScheduler.schedule(
                outputURL: outputURL,
                microphoneURL: recording.microphoneAudioURL,
                systemURL: recording.systemAudioURL,
                sourceAlignment: recording.sourceAlignment,
                sessionID: recording.sessionID,
                conditionerFactory: { Self.makeLocalVQEConditioner(env: env) },
                fileManager: .default,
                eventName: "long_meeting_pipeline_bench_cleaned_mic"
            )
            _ = try await readiness.awaitCompletion(
                timeoutSeconds: max(60, recording.durationSeconds * 2)
            )
            return readiness
        }

        return MeetingRecordingOutput(
            sessionID: recording.sessionID,
            displayName: recording.displayName,
            folderURL: recording.folderURL,
            mixedAudioURL: recording.mixedAudioURL,
            microphoneAudioURL: recording.microphoneAudioURL,
            systemAudioURL: recording.systemAudioURL,
            cleanedMicrophoneAudioURL: readiness.outputURL,
            cleanedMicrophoneReadiness: nil,
            durationSeconds: recording.durationSeconds,
            sourceAlignment: recording.sourceAlignment,
            speechEngine: recording.speechEngine,
            speechEngineWasCaptured: recording.speechEngineWasCaptured,
            userNotes: recording.userNotes
        )
    }

    private func makeFixture(env: [String: String], runID: String) async throws -> BenchmarkFixture {
        let workRoot = URL(fileURLWithPath: env[Self.workDirKey] ?? ".codex/long-meeting-pipeline-bench/runs")
            .standardizedFileURL
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        let runFolder = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)

        if let sessionPath = nonEmpty(env[Self.sessionKey]) {
            let source = URL(fileURLWithPath: sessionPath, isDirectory: true).standardizedFileURL
            let destination = runFolder.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            try copySessionFolder(from: source, to: destination)
            return BenchmarkFixture(
                name: source.lastPathComponent,
                folderURL: destination,
                sourceDescription: source.path,
                synthetic: false
            )
        }

        guard let secondsText = nonEmpty(env[Self.syntheticSecondsKey]),
            let seconds = Double(secondsText),
            seconds > 0
        else {
            throw XCTSkip(
                "Set \(Self.sessionKey) to a retained meeting session folder, or set \(Self.syntheticSecondsKey) for an explicit synthetic smoke fixture."
            )
        }

        let folder = runFolder.appendingPathComponent("synthetic-\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await makeSyntheticFixture(durationSeconds: seconds, folderURL: folder)
        return BenchmarkFixture(
            name: "synthetic-\(String(format: "%.0f", seconds))s",
            folderURL: folder,
            sourceDescription: "generated synthetic dual-track fixture",
            synthetic: true
        )
    }

    private func copySessionFolder(from source: URL, to destination: URL) throws {
        try validateSourceSessionFolder(source)
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.removeItemIfExists(
            at: destination.appendingPathComponent(MeetingCleanedMicRenderer.cleanedMicrophoneFileName)
        )
    }

    private func validateSourceSessionFolder(_ source: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw BenchmarkError.missingRequiredPath(source.path)
        }

        let requiredURLs = [
            source.appendingPathComponent("microphone.m4a"),
            source.appendingPathComponent("system.m4a"),
            MeetingRecordingMetadataStore.metadataURL(for: source)
        ]
        for url in requiredURLs where !FileManager.default.fileExists(atPath: url.path) {
            throw BenchmarkError.missingRequiredPath(url.path)
        }
    }

    private func loadRecording(from folderURL: URL) async throws -> MeetingRecordingOutput {
        let microphoneURL = folderURL.appendingPathComponent("microphone.m4a")
        let systemURL = folderURL.appendingPathComponent("system.m4a")
        let mixedURL = existingMixedAudioURL(in: folderURL) ?? microphoneURL

        guard FileManager.default.fileExists(atPath: microphoneURL.path) else {
            throw BenchmarkError.missingRequiredPath(microphoneURL.path)
        }
        guard FileManager.default.fileExists(atPath: systemURL.path) else {
            throw BenchmarkError.missingRequiredPath(systemURL.path)
        }
        let metadataURL = MeetingRecordingMetadataStore.metadataURL(for: folderURL)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw BenchmarkError.missingRequiredPath(metadataURL.path)
        }

        let duration = try await audioDuration(microphoneURL)
        guard duration > 0 else {
            throw BenchmarkError.invalidFixture("Microphone source has zero duration: \(microphoneURL.path)")
        }
        let recording = try MeetingRecordingOutput.loadArchived(
            displayName: folderURL.lastPathComponent,
            mixedAudioURL: mixedURL,
            durationSeconds: duration
        )
        guard recording.sourceAlignment.microphone != nil, recording.sourceAlignment.system != nil else {
            throw BenchmarkError.invalidFixture(
                "Fixture metadata must include both microphone and system source alignment tracks: \(folderURL.path)"
            )
        }
        return recording
    }

    private func existingMixedAudioURL(in folderURL: URL) -> URL? {
        let candidates = ["meeting.m4a", "mixed.m4a"].map { folderURL.appendingPathComponent($0) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func preflightModelsAndAssets(recording: MeetingRecordingOutput, env: [String: String]) throws {
        _ = try requiredFile(env[Self.localVQELibraryKey], name: Self.localVQELibraryKey)
        let modelURL = try requiredFile(env[Self.localVQEModelKey], name: Self.localVQEModelKey)
        if let expectedSHA = nonEmpty(env[Self.localVQEModelSHAKey])?.lowercased() {
            let actualSHA = try MeetingEchoSuppressionFactory.sha256Hex(for: modelURL)
            guard actualSHA == expectedSHA else {
                throw BenchmarkError.invalidFixture(
                    "\(Self.localVQEModelSHAKey) mismatch for \(modelURL.path): expected \(expectedSHA), got \(actualSHA)"
                )
            }
        }
        switch recording.speechEngine.engine {
        case .parakeet:
            let variant = Self.parakeetVariant(from: env)
            if variant.usesUnifiedEngine {
                guard ParakeetUnifiedEngine.isModelCached() else {
                    throw BenchmarkError.missingModel("Parakeet Unified is not downloaded.")
                }
            } else if let version = variant.asrModelVersion {
                guard STTClient.isModelCached(version: version) else {
                    throw BenchmarkError.missingModel("Parakeet \(variant.rawValue) is not downloaded.")
                }
            }
        case .nemotron:
            guard
                STTClient.isNemotronModelCached(
                    modelVariant: SpeechEnginePreference.nemotronModelVariant(),
                    language: recording.speechEngine.language
                )
            else {
                throw BenchmarkError.missingModel("Nemotron is not downloaded.")
            }
        case .whisper:
            let variant = SpeechEnginePreference.whisperModelVariant()
            guard WhisperEngine.isModelDownloaded(model: variant) else {
                throw BenchmarkError.missingModel("Whisper \(variant) is not downloaded.")
            }
        case .cohere:
            guard CohereTranscribeEngine.isModelCached() else {
                throw BenchmarkError.missingModel("Cohere Transcribe is not downloaded.")
            }
        }

        guard DiarizationService.isModelCached() else {
            throw BenchmarkError.missingModel("Diarization models are not downloaded.")
        }
    }

    private func requiredFile(_ rawPath: String?, name: String) throws -> URL {
        guard let path = nonEmpty(rawPath) else {
            throw BenchmarkError.missingRequiredPath("Missing \(name)")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BenchmarkError.missingRequiredPath(url.path)
        }
        return url
    }

    private static func makeLocalVQEConditioner(env: [String: String]) -> any MicConditioning {
        MeetingEchoSuppressionFactory.makeConditioner(
            configuration: MeetingEchoSuppressionConfiguration(
                mode: .dynamicLibrary,
                libraryURL: env[localVQELibraryKey].map(URL.init(fileURLWithPath:)),
                modelURL: env[localVQEModelKey].map(URL.init(fileURLWithPath:)),
                modelSHA256: env[localVQEModelSHAKey],
                sampleRate: MeetingCleanedMicRenderer.renderSampleRate,
                frameSize: MeetingEchoSuppressionConfiguration.defaultFrameSize,
                adaptiveReferenceDelay: true
            ),
            bundle: Bundle(for: LongMeetingPipelineBenchmarkTests.self)
        )
    }

    private static func parakeetVariant(from env: [String: String]) -> ParakeetModelVariant {
        nonEmpty(env[parakeetVariantKey]).flatMap(ParakeetModelVariant.init(rawValue:))
            ?? SpeechEnginePreference.parakeetModelVariant()
    }

    private func makeSyntheticFixture(durationSeconds: Double, folderURL: URL) async throws {
        let sampleRate = MeetingCleanedMicRenderer.renderSampleRate
        let sampleCount = max(sampleRate, Int(durationSeconds * Double(sampleRate)))
        let echoDelay = 120
        var farEnd = [Float](repeating: 0, count: sampleCount)
        var microphone = [Float](repeating: 0, count: sampleCount)

        for index in 0..<sampleCount {
            let t = Double(index) / Double(sampleRate)
            let system = Float(sin(2 * Double.pi * 440 * t) * 0.18)
            let near = Float(sin(2 * Double.pi * 220 * t) * 0.14)
            farEnd[index] = system
            let echo = index >= echoDelay ? farEnd[index - echoDelay] * 0.45 : 0
            microphone[index] = near + echo
        }

        let microphoneURL = folderURL.appendingPathComponent("microphone.m4a")
        let systemURL = folderURL.appendingPathComponent("system.m4a")
        try await MeetingCleanedMicRenderer.encodeMonoFloat(
            microphone,
            sampleRate: sampleRate,
            to: microphoneURL,
            fileManager: .default
        )
        try await MeetingCleanedMicRenderer.encodeMonoFloat(
            farEnd,
            sampleRate: sampleRate,
            to: systemURL,
            fileManager: .default
        )
        try FileManager.default.copyItem(at: microphoneURL, to: folderURL.appendingPathComponent("meeting.m4a"))

        let track = MeetingSourceAlignment.Track(
            firstHostTime: nil,
            lastHostTime: nil,
            startOffsetMs: 0,
            writtenFrameCount: Int64(sampleCount),
            sampleRate: Double(sampleRate)
        )
        let metadata = MeetingRecordingMetadata(
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: nil,
                microphone: track,
                system: track
            ),
            speechEngine: SpeechEngineSelection(engine: .parakeet)
        )
        try MeetingRecordingMetadataStore.save(metadata, folderURL: folderURL)
    }

    private func renderMarkdownTable(
        runID: String,
        fixture: BenchmarkFixture,
        recording: MeetingRecordingOutput,
        rows: [StageMetricsCollector.Row]
    ) -> String {
        var lines = [
            "### Long Meeting Full Pipeline Benchmark - \(runID)",
            "",
            "- Fixture: \(fixture.name)",
            "- Source: \(fixture.sourceDescription)",
            "- Working copy: \(fixture.folderURL.path)",
            "- Recording duration: \(String(format: "%.3f", recording.durationSeconds)) s",
            "- Synthetic fixture: \(fixture.synthetic ? "yes" : "no")",
            "",
            "| Run | Fixture | Stage | Recording duration (s) | Elapsed (s) | Realtime factor | Peak RSS delta (MB) |",
            "|---|---|---|---:|---:|---:|---:|",
        ]
        lines += rows.map { row in
            "| \(runID) | \(fixture.name) | \(row.stage) | \(String(format: "%.3f", recording.durationSeconds)) | \(String(format: "%.4f", row.elapsedSeconds)) | \(String(format: "%.2fx", row.realtimeFactor)) | \(String(format: "%.1f", row.peakRSSDeltaMB)) |"
        }
        return lines.joined(separator: "\n")
    }

    private func append(table: String, env: [String: String]) throws {
        let outputURL = URL(
            fileURLWithPath: env[Self.resultsFileKey] ?? ".codex/long-meeting-pipeline-bench/results.md"
        )
        .standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = "\n\n\(table)\n"
        if FileManager.default.fileExists(atPath: outputURL.path) {
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(payload.utf8))
        } else {
            try Data(payload.utf8).write(to: outputURL)
        }
        print("Long meeting pipeline benchmark results appended to \(outputURL.path)")
    }

    private func audioDuration(_ url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw BenchmarkError.invalidFixture("No audio track in \(url.path)")
        }
        return try await asset.load(.duration).seconds
    }

    private func nonEmpty(_ value: String?) -> String? {
        Self.nonEmpty(value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private extension MeetingFinalizationBenchmarkObserver.Stage {
    var markdownName: String { rawValue }
}

private struct BenchmarkFixture {
    let name: String
    let folderURL: URL
    let sourceDescription: String
    let synthetic: Bool
}

private enum BenchmarkError: Error, LocalizedError {
    case missingRequiredPath(String)
    case missingModel(String)
    case invalidFixture(String)

    var errorDescription: String? {
        switch self {
        case .missingRequiredPath(let path):
            "Required benchmark path is missing: \(path)"
        case .missingModel(let message), .invalidFixture(let message):
            message
        }
    }
}

private final class StageMetricsCollector: @unchecked Sendable {
    struct Row: Equatable {
        let stage: String
        let elapsedSeconds: Double
        let realtimeFactor: Double
        let peakRSSDeltaMB: Double
    }

    private final class RunningStage {
        let stage: String
        let startedAt: TimeInterval
        let baselineRSS: UInt64
        var peakRSS: UInt64
        var timer: DispatchSourceTimer?

        init(stage: String, startedAt: TimeInterval, baselineRSS: UInt64) {
            self.stage = stage
            self.startedAt = startedAt
            self.baselineRSS = baselineRSS
            self.peakRSS = baselineRSS
        }

        deinit {
            timer?.cancel()
        }
    }

    private let recordingDurationSeconds: Double
    private let lock = NSLock()
    private var running: [String: RunningStage] = [:]
    private var completedRows: [Row] = []

    init(recordingDurationSeconds: Double) {
        self.recordingDurationSeconds = recordingDurationSeconds
    }

    func begin(_ stage: String) {
        let baselineRSS = Self.currentResidentRSS()
        let run = RunningStage(
            stage: stage,
            startedAt: ProcessInfo.processInfo.systemUptime,
            baselineRSS: baselineRSS
        )
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.macparakeet.long-meeting-bench.\(stage)")
        )
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.sample(stage)
        }
        run.timer = timer
        lock.withLock {
            running[stage] = run
        }
        timer.resume()
    }

    func end(_ stage: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let rss = Self.currentResidentRSS()
        let run = lock.withLock { () -> RunningStage? in
            guard let run = running.removeValue(forKey: stage) else { return nil }
            run.peakRSS = max(run.peakRSS, rss)
            return run
        }
        guard let run else { return }
        run.timer?.cancel()
        let elapsed = max(0, now - run.startedAt)
        let peakDelta = run.peakRSS > run.baselineRSS ? run.peakRSS - run.baselineRSS : 0
        let row = Row(
            stage: run.stage,
            elapsedSeconds: elapsed,
            realtimeFactor: elapsed > 0 ? recordingDurationSeconds / elapsed : 0,
            peakRSSDeltaMB: Double(peakDelta) / 1_048_576.0
        )
        lock.withLock {
            completedRows.append(row)
        }
    }

    func measure<T>(stage: String, operation: () async throws -> T) async throws -> T {
        begin(stage)
        do {
            let value = try await operation()
            end(stage)
            return value
        } catch {
            end(stage)
            throw error
        }
    }

    func rows() -> [Row] {
        lock.withLock { completedRows }
    }

    private func sample(_ stage: String) {
        let rss = Self.currentResidentRSS()
        lock.withLock {
            guard let run = running[stage] else { return }
            run.peakRSS = max(run.peakRSS, rss)
        }
    }

    private static func currentResidentRSS() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}

private final class BenchmarkTranscriptionRepository: TranscriptionRepositoryProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: Transcription] = [:]

    func save(_ transcription: Transcription) throws {
        lock.withLock {
            records[transcription.id] = transcription
        }
    }

    func fetch(id: UUID) throws -> Transcription? {
        lock.withLock { records[id] }
    }

    func fetchAll(limit: Int?) throws -> [Transcription] {
        let all = lock.withLock { Array(records.values) }
        guard let limit else { return all }
        return Array(all.prefix(limit))
    }

    func delete(id: UUID) throws -> Bool {
        lock.withLock { records.removeValue(forKey: id) != nil }
    }

    func deleteAll() throws {
        lock.withLock { records.removeAll() }
    }

    func updateStatus(id: UUID, status: Transcription.TranscriptionStatus, errorMessage: String?) throws {
        lock.withLock {
            guard var record = records[id] else { return }
            record.status = status
            record.errorMessage = errorMessage
            records[id] = record
        }
    }
}

private extension FileManager {
    func removeItemIfExists(at url: URL) throws {
        guard fileExists(atPath: url.path) else { return }
        try removeItem(at: url)
    }
}
