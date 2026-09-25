import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
import XCTest
@testable import MacParakeetCore

/// Opt-in model-backed finalization smoke. Fixtures must contain intelligible
/// microphone speech and at least two system speakers. They are copied/encoded
/// into a temporary meeting; the source files and the user's database are untouched.
///
/// MACPARAKEET_NEMOTRON_E2E_SYSTEM=/path/to/public-meeting.wav \
/// MACPARAKEET_NEMOTRON_E2E_MIC=/path/to/local-speaker.wav \
/// MACPARAKEET_NEMOTRON_E2E_MODELS=/path/to/diarization-model-base \
/// MACPARAKEET_NEMOTRON_E2E_RESULTS=/tmp/nemotron-e2e.json \
/// swift test --filter NemotronDiarizationE2ETests
///
/// Both diarizers and Parakeet v3 models must already be cached. The normal
/// suite skips before creating any fixture, model service, or database.
final class NemotronDiarizationE2ETests: XCTestCase {
    func testRealMeetingFinalizationFileTranscriptionAndDiarizerReuse() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let systemPath = environment["MACPARAKEET_NEMOTRON_E2E_SYSTEM"], !systemPath.isEmpty,
            let microphonePath = environment["MACPARAKEET_NEMOTRON_E2E_MIC"], !microphonePath.isEmpty,
            let modelPath = environment["MACPARAKEET_NEMOTRON_E2E_MODELS"], !modelPath.isEmpty,
            let resultsPath = environment["MACPARAKEET_NEMOTRON_E2E_RESULTS"], !resultsPath.isEmpty
        else {
            throw XCTSkip("Set MACPARAKEET_NEMOTRON_E2E_{SYSTEM,MIC,MODELS,RESULTS} for real-audio verification.")
        }
        let modelBase = URL(fileURLWithPath: modelPath, isDirectory: true)
        guard STTClient.isModelCached(version: .v3),
            NemotronDiarizationModelStore.isCached(base: modelBase, preset: .fast128),
            DiarizationService.isModelCached(directory: modelBase)
        else {
            XCTFail(
                "Explicit E2E run requires existing Parakeet v3, Nemotron fast128, and Community-1 caches; prepare them first."
            )
            return
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("nemotron-e2e-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let recording = try makeRecording(
            root: root, system: URL(fileURLWithPath: systemPath), microphone: URL(fileURLWithPath: microphonePath)
        )
        let databasePath = root.appendingPathComponent("verification.sqlite").path
        let database = try DatabaseManager(path: databasePath)
        let repository = TranscriptionRepository(dbQueue: database.dbQueue)
        let defaultsName = "com.macparakeet.tests.nemotron-e2e.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let stt = STTClient(parakeetModelVariant: .v3, defaults: defaults)
        do {
            try await verifyPipeline(
                recording: recording, root: root, databasePath: databasePath, repository: repository,
                stt: stt, modelBase: modelBase, resultsURL: URL(fileURLWithPath: resultsPath),
                fixturePaths: ["system": systemPath, "microphone": microphonePath]
            )
        } catch {
            await stt.shutdown()
            throw error
        }
        await stt.shutdown()
    }

    private func verifyPipeline(
        recording: MeetingRecordingOutput,
        root: URL,
        databasePath: String,
        repository: TranscriptionRepository,
        stt: STTClient,
        modelBase: URL,
        resultsURL: URL,
        fixturePaths: [String: String]
    ) async throws {
        let native = NemotronDiarizationService(preset: .fast128, modelsDirectory: modelBase)
        let diarizer = RecordingDiarizer(base: native)
        let audio = RecordingAudioProcessor()
        let service = TranscriptionService(
            audioProcessor: audio,
            sttTranscriber: stt,
            transcriptionRepo: repository,
            processingMode: { .raw },
            spokenPunctuationEnabled: { false },
            removeUmFiller: { false },
            shouldUseAIFormatter: { false },
            shouldAutoGenerateMeetingTitles: { false },
            shouldDiarize: { true },
            shouldDiarizeMeetings: { true },
            fileSpeechEngineSelection: { SpeechEngineSelection(engine: .parakeet) },
            diarizationService: diarizer,
            meetingArtifactStore: MeetingArtifactStore(),
            meetingAutomationHookRunner: nil
        )

        let start = Date()
        let queued = try await service.prepareMeetingTranscription(recording: recording)
        XCTAssertEqual(queued.status, .processing)
        XCTAssertNil(queued.rawTranscript)
        let meeting = try await service.finalizeMeetingTranscription(recording: recording, updating: queued.id)
        let meetingSeconds = Date().timeIntervalSince(start)

        XCTAssertEqual(meeting.id, queued.id)
        XCTAssertEqual(meeting.status, .completed)
        XCTAssertEqual(meeting.sourceType, .meeting)
        XCTAssertEqual(meeting.engine, SpeechEnginePreference.parakeet.rawValue)
        XCTAssertFalse(try XCTUnwrap(meeting.rawTranscript).isEmpty)
        let meetingWords = try XCTUnwrap(meeting.wordTimestamps)
        let microphoneWords = meetingWords.filter { $0.speakerId == "microphone" }
        let systemWords = meetingWords.filter {
            $0.speakerId == "system" || $0.speakerId?.hasPrefix("system:S") == true
        }
        let unattributedSystemWords = systemWords.filter { $0.speakerId == "system" }
        XCTAssertFalse(microphoneWords.isEmpty, "The real microphone transcript must survive finalization as Me.")
        XCTAssertTrue(
            systemWords.contains { $0.speakerId?.hasPrefix("system:S") == true },
            "System words must have native speaker attribution.")
        // Words outside acoustic activity retain the source-level Others label;
        // they must not be silently reassigned to the microphone or dropped.
        XCTAssertTrue(
            meetingWords.allSatisfy {
                $0.speakerId == "microphone" || $0.speakerId == "system" || $0.speakerId?.hasPrefix("system:S") == true
            })
        XCTAssertTrue(meetingWords.allSatisfy { $0.startMs >= 0 && $0.endMs >= $0.startMs })
        XCTAssertTrue(zip(meetingWords, meetingWords.dropFirst()).allSatisfy { $0.startMs <= $1.startMs })
        XCTAssertTrue(systemWords.allSatisfy { $0.startMs >= Self.systemOffsetMs })
        let meetingSpeakers = try XCTUnwrap(meeting.speakers)
        XCTAssertEqual(meetingSpeakers.first { $0.id == "microphone" }?.label, "Me")
        XCTAssertGreaterThanOrEqual(meetingSpeakers.filter { $0.id.hasPrefix("system:S") }.count, 2)
        XCTAssertEqual(Set(meetingSpeakers.map(\.id)), Set(meetingWords.compactMap(\.speakerId)))
        XCTAssertFalse(try XCTUnwrap(meeting.diarizationSegments).isEmpty)
        XCTAssertEqual(meeting.durationMs, recording.playableDurationMs)

        let meetingCalls = await diarizer.calls
        let conversions = await audio.conversions
        let systemWAV = try XCTUnwrap(conversions.first { $0.source == recording.systemAudioURL }?.converted)
        let microphoneWAV = try XCTUnwrap(conversions.first { $0.source == recording.microphoneAudioURL }?.converted)
        XCTAssertEqual(meetingCalls.map(\.url), [systemWAV], "Only the isolated system WAV may be diarized.")
        XCTAssertFalse(meetingCalls.contains { $0.url == microphoneWAV })
        XCTAssertTrue(meetingCalls.allSatisfy { $0.embeddingCount == 0 })

        // A separately opened connection verifies durable persistence rather
        // than merely inspecting the value returned by finalization.
        let reopened = try DatabaseManager(readOnlyPath: databasePath)
        let readRepository = TranscriptionRepository(dbQueue: reopened.dbQueue)
        try assertPersisted(meeting, in: readRepository)
        XCTAssertEqual(try readRepository.count(), 1)
        let transcriptArtifact = try Data(
            contentsOf: recording.folderURL.appendingPathComponent(MeetingArtifactStore.transcriptFileName))
        let artifact = try XCTUnwrap(JSONSerialization.jsonObject(with: transcriptArtifact) as? [String: Any])
        XCTAssertEqual(artifact["transcript"] as? String, meeting.rawTranscript)
        let markdown = try String(
            contentsOf: recording.folderURL.appendingPathComponent(MeetingArtifactStore.markdownFileName),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("Me"))
        let metadata = try MeetingRecordingMetadataStore.load(from: recording.folderURL)
        XCTAssertEqual(metadata.sourceAlignment, recording.sourceAlignment)
        XCTAssertEqual(recording.validatedMicrophoneTranscriptionURL(), recording.microphoneAudioURL)

        // Reuse the same loaded native model after a multi-speaker recording:
        // silence must not inherit its roster or speaker-cache activity.
        let silenceURL = root.appendingPathComponent("silence.wav")
        try writeAudio([Float](repeating: 0, count: 80_000), to: silenceURL, compressed: false)
        let silence = try await native.diarize(audioURL: silenceURL)
        XCTAssertEqual(silence.speakerCount, 0)
        XCTAssertTrue(silence.segments.isEmpty)
        XCTAssertTrue(silence.speakers.isEmpty)

        let fileStart = Date()
        let file = try await service.transcribe(fileURL: recording.systemAudioURL)
        let fileSeconds = Date().timeIntervalSince(fileStart)
        XCTAssertEqual(file.status, .completed)
        XCTAssertEqual(file.sourceType, .file)
        XCTAssertFalse(try XCTUnwrap(file.rawTranscript).isEmpty)
        XCTAssertFalse(try XCTUnwrap(file.wordTimestamps).isEmpty)
        let fileSpeakers = try XCTUnwrap(file.speakers)
        XCTAssertGreaterThanOrEqual(fileSpeakers.count, 2)
        XCTAssertTrue(fileSpeakers.allSatisfy { $0.id.hasPrefix("S") && !$0.id.contains(":") })
        XCTAssertFalse(try XCTUnwrap(file.diarizationSegments).isEmpty)
        try assertPersisted(file, in: readRepository)
        XCTAssertEqual(try readRepository.count(), 2)
        let allCalls = await diarizer.calls
        XCTAssertEqual(allCalls.count, 2)

        // Freeze ASR words/timings and the converted WAV, varying only acoustic
        // diarization. This baseline runs on 0.17.4, not the old SDK runtime.
        let candidateCall = try XCTUnwrap(allCalls.last)
        let comparisonWAV = try await audio.convert(fileURL: recording.systemAudioURL)
        defer { try? FileManager.default.removeItem(at: comparisonWAV) }
        XCTAssertEqual(try Self.audioSHA256(comparisonWAV), candidateCall.audioSHA256)
        let baseline = try await DiarizationService(modelsDirectory: modelBase).diarize(audioURL: comparisonWAV)
        let fixedWords = try XCTUnwrap(file.wordTimestamps).map { word in
            var copy = word
            copy.speakerId = nil
            return copy
        }
        let projections = [
            wordProjection(
                backend: "fluidaudio-0.17.4-community-1", words: fixedWords,
                segments: baseline.segments.map {
                    .init(speakerId: $0.speakerId, startMs: $0.startMs, endMs: $0.endMs)
                }
            ),
            wordProjection(
                backend: "fluidaudio-0.17.4-nemotron-fast128", words: fixedWords, segments: candidateCall.segments),
        ]

        let report = Report(
            fixturePaths: fixturePaths, modelRevision: NemotronDiarizationModelStore.revision,
            systemOffsetMs: Self.systemOffsetMs, meetingRuntimeSeconds: meetingSeconds,
            fileRuntimeSeconds: fileSeconds, microphoneWordCount: microphoneWords.count,
            systemWordCount: systemWords.count, unattributedSystemWordCount: unattributedSystemWords.count,
            silenceSpeakerCountAfterMeeting: silence.speakerCount,
            diarizedSources: ["meeting:system", "file:system-fixture"],
            meeting: meeting, file: file, nativeCalls: allCalls, fixedASRWordProjections: projections
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: resultsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: resultsURL, options: .atomic)
        print("Nemotron real-audio pipeline report: \(resultsURL.path)")
    }

    private static let systemOffsetMs = 500

    private static func audioSHA256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func wordProjection(
        backend: String, words: [WordTimestamp], segments: [DiarizationSegmentRecord]
    ) -> WordProjection {
        let intervals = segments.sorted { $0.startMs < $1.startMs }
        let projected = SpeakerMerger.mergeWordTimestampsWithSpeakers(
            words: words,
            segments: intervals.map {
                SpeakerSegment(speakerId: $0.speakerId, startMs: $0.startMs, endMs: $0.endMs)
            }
        )
        XCTAssertEqual(
            projected.map { word in
                var copy = word
                copy.speakerId = nil
                return copy
            }, words, "Speaker projection must not rewrite, drop, or retime fixed ASR words.")
        // Independent brute-force maximum overlap exposes smoothing separately.
        // Earlier intervals win ties, matching the public merger contract.
        let unsmoothed: [String?] = words.map { word in
            var best: String?
            var longest = 0
            for interval in intervals {
                let overlap = min(word.endMs, interval.endMs) - max(word.startMs, interval.startMs)
                if overlap > longest {
                    longest = overlap
                    best = interval.speakerId
                }
            }
            return best
        }
        let changedSingletons = words.indices.filter { index in
            index > 0 && index + 1 < words.count && unsmoothed[index] != nil
                && unsmoothed[index - 1] == unsmoothed[index + 1]
                && unsmoothed[index - 1] != unsmoothed[index]
                && projected[index].speakerId != unsmoothed[index]
        }
        return WordProjection(
            backend: backend, rawIntervals: intervals, unsmoothedSpeakerIDs: unsmoothed,
            projectedWords: projected, unassignedBeforeSmoothing: unsmoothed.filter { $0 == nil }.count,
            unassignedAfterSmoothing: projected.filter { $0.speakerId == nil }.count,
            nonNilSingletonsChangedBySmoothing: changedSingletons
        )
    }

    private func makeRecording(root: URL, system: URL, microphone: URL) throws -> MeetingRecordingOutput {
        let systemSamples = try AudioConverter().resampleAudioFile(path: system.path)
        let microphoneSamples = try AudioConverter().resampleAudioFile(path: microphone.path)
        XCTAssertFalse(systemSamples.isEmpty)
        XCTAssertFalse(microphoneSamples.isEmpty)
        let folder = root.appendingPathComponent("meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let systemURL = folder.appendingPathComponent(MeetingArtifactAudioFileNames.rawSystem)
        let microphoneURL = folder.appendingPathComponent(MeetingArtifactAudioFileNames.rawMicrophone)
        let playbackURL = folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback)
        try writeAudio(systemSamples, to: systemURL, compressed: true)
        try writeAudio(microphoneSamples, to: microphoneURL, compressed: true)
        let systemOffsetSamples = Self.systemOffsetMs * 16
        var mix = [Float](repeating: 0, count: max(microphoneSamples.count, systemSamples.count + systemOffsetSamples))
        for (index, sample) in microphoneSamples.enumerated() { mix[index] += sample * 0.5 }
        for (index, sample) in systemSamples.enumerated() { mix[index + systemOffsetSamples] += sample * 0.5 }
        try writeAudio(mix, to: playbackURL, compressed: true)
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: nil,
            microphone: .init(
                firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0,
                writtenFrameCount: Int64(microphoneSamples.count), sampleRate: 16_000
            ),
            system: .init(
                firstHostTime: nil, lastHostTime: nil, startOffsetMs: Self.systemOffsetMs,
                writtenFrameCount: Int64(systemSamples.count), sampleRate: 16_000
            )
        )
        try MeetingRecordingMetadataStore.save(.init(sourceAlignment: alignment), folderURL: folder)
        return MeetingRecordingOutput(
            sessionID: UUID(), displayName: "Nemotron public-fixture E2E", folderURL: folder,
            mixedAudioURL: playbackURL, microphoneAudioURL: microphoneURL, systemAudioURL: systemURL,
            durationSeconds: Double(mix.count) / 16_000, sourceAlignment: alignment,
            speechEngine: SpeechEngineSelection(engine: .parakeet)
        )
    }

    private func writeAudio(_ samples: [Float], to url: URL, compressed: Bool) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let settings: [String: Any] =
            compressed
            ? [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
            : format.settings
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: source.count) }
        }
        try file.write(from: buffer)
    }

    private func assertPersisted(_ expected: Transcription, in repository: TranscriptionRepository) throws {
        let actual = try XCTUnwrap(repository.fetch(id: expected.id))
        XCTAssertEqual(actual.status, .completed)
        XCTAssertEqual(actual.rawTranscript, expected.rawTranscript)
        XCTAssertEqual(actual.wordTimestamps, expected.wordTimestamps)
        XCTAssertEqual(actual.speakers, expected.speakers)
        XCTAssertEqual(actual.diarizationSegments, expected.diarizationSegments)
        XCTAssertEqual(actual.durationMs, expected.durationMs)
        XCTAssertEqual(actual.engine, expected.engine)
    }

    private struct Report: Encodable {
        let fixturePaths: [String: String]
        let modelRevision: String
        let systemOffsetMs: Int
        let meetingRuntimeSeconds: TimeInterval
        let fileRuntimeSeconds: TimeInterval
        let microphoneWordCount: Int
        let systemWordCount: Int
        let unattributedSystemWordCount: Int
        let silenceSpeakerCountAfterMeeting: Int
        let diarizedSources: [String]
        let meeting: Transcription
        let file: Transcription
        let nativeCalls: [RecordingDiarizer.Call]
        let fixedASRWordProjections: [WordProjection]
    }

    private struct WordProjection: Encodable {
        let backend: String
        let rawIntervals: [DiarizationSegmentRecord]
        let unsmoothedSpeakerIDs: [String?]
        let projectedWords: [WordTimestamp]
        let unassignedBeforeSmoothing: Int
        let unassignedAfterSmoothing: Int
        let nonNilSingletonsChangedBySmoothing: [Int]
    }

    private actor RecordingDiarizer: DiarizationServiceProtocol {
        struct Call: Sendable, Encodable {
            let url: URL
            let audioSHA256: String
            let speakers: [SpeakerInfo]
            let segments: [DiarizationSegmentRecord]
            let embeddingCount: Int
        }
        private let base: NemotronDiarizationService
        private(set) var calls: [Call] = []

        init(base: NemotronDiarizationService) { self.base = base }

        func diarize(audioURL: URL, speakerConstraint: SpeakerDiarizationConstraint?) async throws
            -> MacParakeetDiarizationResult
        {
            let digest = try NemotronDiarizationE2ETests.audioSHA256(audioURL)
            let result = try await base.diarize(audioURL: audioURL, speakerConstraint: speakerConstraint)
            calls.append(
                Call(
                    url: audioURL, audioSHA256: digest, speakers: result.speakers,
                    segments: result.segments.map {
                        .init(speakerId: $0.speakerId, startMs: $0.startMs, endMs: $0.endMs)
                    },
                    embeddingCount: result.speakerEmbeddings.count
                ))
            return result
        }

        func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws {
            try await base.prepareModels(onProgress: onProgress)
        }
        func isReady() async -> Bool { await base.isReady() }
        func hasCachedModels() async -> Bool { await base.hasCachedModels() }
    }

    private actor RecordingAudioProcessor: AudioProcessorProtocol {
        struct Conversion: Sendable {
            let source: URL
            let converted: URL
        }
        private let base = AudioProcessor()
        private(set) var conversions: [Conversion] = []
        var audioLevel: Float { 0 }
        var isRecording: Bool { false }
        var recordingDeviceInfo: RecordingDeviceInfo? { nil }

        func convert(fileURL: URL) async throws -> URL {
            let converted = try await base.convert(fileURL: fileURL)
            conversions.append(Conversion(source: fileURL, converted: converted))
            return converted
        }

        func startCapture() async throws {
            throw AudioProcessorError.recordingFailed("E2E fixture never captures hardware audio")
        }
        func stopCapture() async throws -> URL {
            throw AudioProcessorError.recordingFailed("E2E fixture never captures hardware audio")
        }
    }
}
