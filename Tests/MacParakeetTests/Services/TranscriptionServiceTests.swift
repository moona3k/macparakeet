import XCTest
@testable import MacParakeetCore
import os

private actor MockYouTubeDownloader: YouTubeDownloading {
    var downloadCallCount = 0
    var lastURL: String?
    private let result: YouTubeDownloader.DownloadResult
    private let progressUpdates: [Int]

    init(result: YouTubeDownloader.DownloadResult, progressUpdates: [Int] = []) {
        self.result = result
        self.progressUpdates = progressUpdates
    }

    func download(url: String, onProgress: (@Sendable (Int) -> Void)?) async throws -> YouTubeDownloader.DownloadResult {
        downloadCallCount += 1
        lastURL = url
        for pct in progressUpdates {
            onProgress?(pct)
        }
        return result
    }
}

private final class TelemetrySpy: TelemetryServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TelemetryEventSpec] = []

    func send(_ event: TelemetryEventSpec) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func flush() async {}

    func flushForTermination() {}

    func snapshot() -> [TelemetryEventSpec] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private actor FailingYouTubeDownloader: YouTubeDownloading {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func download(url: String, onProgress: (@Sendable (Int) -> Void)?) async throws -> YouTubeDownloader.DownloadResult {
        throw error
    }
}

final class TranscriptionServiceTests: XCTestCase {
    var service: TranscriptionService!
    var mockAudio: MockAudioProcessor!
    var mockSTT: MockSTTClient!
    var transcriptionRepo: TranscriptionRepository!

    override func setUp() async throws {
        let dbManager = try DatabaseManager()
        mockAudio = MockAudioProcessor()
        mockSTT = MockSTTClient()
        transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
        Telemetry.configure(NoOpTelemetryService())

        service = TranscriptionService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            transcriptionRepo: transcriptionRepo
        )
    }

    func testTranscribeFileSucceeds() async throws {
        let expectedResult = STTResult(
            text: "This is a transcription",
            words: [
                TimestampedWord(word: "This", startMs: 0, endMs: 200, confidence: 0.99),
                TimestampedWord(word: "is", startMs: 210, endMs: 350, confidence: 0.98),
                TimestampedWord(word: "a", startMs: 360, endMs: 400, confidence: 0.97),
                TimestampedWord(word: "transcription", startMs: 410, endMs: 1000, confidence: 0.96),
            ]
        )
        await mockSTT.configure(result: expectedResult)

        let fileURL = URL(fileURLWithPath: "/tmp/test.mp3")
        let result = try await service.transcribe(fileURL: fileURL)

        XCTAssertEqual(result.fileName, "test.mp3")
        XCTAssertEqual(result.rawTranscript, "This is a transcription")
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.wordTimestamps?.count, 4)
        XCTAssertEqual(result.durationMs, 1000)

        // Verify saved to DB
        let fetched = try transcriptionRepo.fetch(id: result.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.status, .completed)
    }

    func testTranscribeFileError() async throws {
        await mockSTT.configure(error: STTError.transcriptionFailed("Model error"))

        let fileURL = URL(fileURLWithPath: "/tmp/test.mp3")

        do {
            _ = try await service.transcribe(fileURL: fileURL)
            XCTFail("Should have thrown")
        } catch let error as STTError {
            if case .transcriptionFailed(let reason) = error {
                XCTAssertEqual(reason, "Model error")
            } else {
                XCTFail("Expected transcriptionFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Verify error saved to DB
        let all = try transcriptionRepo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].status, .error)
    }

    func testTranscribeFileCancellationMarksRecordCancelled() async throws {
        await mockSTT.configure(error: CancellationError())

        let fileURL = URL(fileURLWithPath: "/tmp/test.mp3")

        do {
            _ = try await service.transcribe(fileURL: fileURL)
            XCTFail("Should have thrown")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        let all = try transcriptionRepo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].status, .cancelled)
        XCTAssertNil(all[0].errorMessage)
    }

    func testTranscribeURLWithoutDownloaderThrows() async throws {
        // Service without youtubeDownloader should throw
        do {
            _ = try await service.transcribeURL(urlString: "https://youtu.be/dQw4w9WgXcQ")
            XCTFail("Should have thrown")
        } catch let error as YouTubeDownloadError {
            if case .ytDlpNotFound = error {
                // Expected — no YouTubeDownloader configured
            } else {
                XCTFail("Expected ytDlpNotFound, got \(error)")
            }
        }
    }

    func testConvertCalledBeforeSTT() async throws {
        let expectedResult = STTResult(text: "Hello")
        await mockSTT.configure(result: expectedResult)

        let fileURL = URL(fileURLWithPath: "/tmp/test.mp3")
        _ = try await service.transcribe(fileURL: fileURL)

        let convertCount = await mockAudio.convertCallCount
        XCTAssertEqual(convertCount, 1)

        let lastURL = await mockAudio.lastConvertURL
        XCTAssertEqual(lastURL?.path, "/tmp/test.mp3")
    }

    func testTranscribeAppliesAIFormatterAsFinalStep() async throws {
        await mockSTT.configure(result: STTResult(text: "hello world"))
        let mockLLMService = MockLLMService()
        mockLLMService.formatTranscriptResult = "Hello, world."

        let service = TranscriptionService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            transcriptionRepo: transcriptionRepo,
            llmService: mockLLMService,
            shouldUseAIFormatter: { true },
            aiFormatterPromptTemplate: { AIFormatter.defaultPromptTemplate }
        )

        let result = try await service.transcribe(fileURL: URL(fileURLWithPath: "/tmp/test.mp3"))

        XCTAssertEqual(result.rawTranscript, "hello world")
        XCTAssertEqual(result.cleanTranscript, "Hello, world.")
        XCTAssertEqual(mockLLMService.formatTranscriptCallCount, 1)
        XCTAssertEqual(mockLLMService.lastFormattedTranscript, "hello world")
    }

    func testTranscribeFallsBackWhenAIFormatterFailsAndPostsWarning() async throws {
        await mockSTT.configure(result: STTResult(text: "hello world"))
        let mockLLMService = MockLLMService()
        mockLLMService.errorToThrow = LLMError.formatterTruncated

        let warningPosted = expectation(description: "AI formatter warning posted")
        var warningMessage: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .macParakeetAIFormatterWarning,
            object: nil,
            queue: nil
        ) { notification in
            guard let source = notification.userInfo?["source"] as? String, source == "transcription" else { return }
            warningMessage = notification.userInfo?["message"] as? String
            warningPosted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let service = TranscriptionService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            transcriptionRepo: transcriptionRepo,
            llmService: mockLLMService,
            shouldUseAIFormatter: { true },
            aiFormatterPromptTemplate: { AIFormatter.defaultPromptTemplate }
        )

        let result = try await service.transcribe(fileURL: URL(fileURLWithPath: "/tmp/test.mp3"))

        XCTAssertEqual(result.rawTranscript, "hello world")
        XCTAssertNil(result.cleanTranscript)
        XCTAssertEqual(mockLLMService.formatTranscriptCallCount, 1)
        await fulfillment(of: [warningPosted], timeout: 1.0)
        XCTAssertEqual(warningMessage, "AI formatter output was incomplete. Used standard cleanup.")
    }

    func testTranscribePostsAuthenticationWarningWhenAIFormatterAuthFails() async throws {
        await mockSTT.configure(result: STTResult(text: "hello world"))
        let mockLLMService = MockLLMService()
        mockLLMService.errorToThrow = LLMError.authenticationFailed(nil)

        let warningPosted = expectation(description: "AI formatter auth warning posted")
        var warningMessage: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .macParakeetAIFormatterWarning,
            object: nil,
            queue: nil
        ) { notification in
            guard let source = notification.userInfo?["source"] as? String, source == "transcription" else { return }
            warningMessage = notification.userInfo?["message"] as? String
            warningPosted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let service = TranscriptionService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            transcriptionRepo: transcriptionRepo,
            llmService: mockLLMService,
            shouldUseAIFormatter: { true },
            aiFormatterPromptTemplate: { AIFormatter.defaultPromptTemplate }
        )

        _ = try await service.transcribe(fileURL: URL(fileURLWithPath: "/tmp/test.mp3"))

        await fulfillment(of: [warningPosted], timeout: 1.0)
        XCTAssertEqual(warningMessage, "Authentication failed. Check your API key. Used standard cleanup.")
    }

    func testTranscribeURLKeepsDownloadedAudioByDefault() async throws {
        let downloadedURL = try makeTempDownloadedAudio()
        defer { try? FileManager.default.removeItem(at: downloadedURL) }

        let downloader = MockYouTubeDownloader(result: YouTubeDownloader.DownloadResult(
            audioFileURL: downloadedURL,
            title: "Video",
            durationSeconds: 120
        ))

        let expectedResult = STTResult(text: "Downloaded transcript")
        await mockSTT.configure(result: expectedResult)

        let service = TranscriptionService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            transcriptionRepo: transcriptionRepo,
            youtubeDownloader: downloader
        )

        let result = try await service.transcribeURL(urlString: "https://youtu.be/dQw4w9WgXcQ")

        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadedURL.path))
        XCTAssertEqual(result.filePath, downloadedURL.path)
    }

    func testTranscribeURLDeletesDownloadedAudioWhenDisabled() async throws {
        let downloadedURL = try makeTempDownloadedAudio()
        defer { try? FileManager.default.removeItem(at: downloadedURL) }

        let downloader = MockYouTubeDownloader(result: YouTubeDownloader.DownloadResult(
            audioFileURL: downloadedURL,
            title: "Video",
            durationSeconds: 120
        ))

        let expectedResult = STTResult(text: "Downloaded transcript")
        await mockSTT.configure(result: expectedResult)

        let service = TranscriptionService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            transcriptionRepo: transcriptionRepo,
            shouldKeepDownloadedAudio: { false },
            youtubeDownloader: downloader
        )

        let result = try await service.transcribeURL(urlString: "https://youtu.be/dQw4w9WgXcQ")

        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedURL.path))
        XCTAssertNil(result.filePath)
    }

    func testTranscribeURLForwardsDownloadProgressToPhaseCallback() async throws {
        let downloadedURL = try makeTempDownloadedAudio()
        defer { try? FileManager.default.removeItem(at: downloadedURL) }

        let downloader = MockYouTubeDownloader(
            result: YouTubeDownloader.DownloadResult(
                audioFileURL: downloadedURL,
                title: "Video",
                durationSeconds: 120
            ),
            progressUpdates: [7, 42, 100]
        )

        await mockSTT.configure(result: STTResult(text: "Downloaded transcript"))

        let service = TranscriptionService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            transcriptionRepo: transcriptionRepo,
            youtubeDownloader: downloader
        )

        let phasesLock = OSAllocatedUnfairLock(initialState: [TranscriptionProgress]())
        _ = try await service.transcribeURL(urlString: "https://youtu.be/dQw4w9WgXcQ") { progress in
            phasesLock.withLock { $0.append(progress) }
        }
        let phases = phasesLock.withLock { $0 }

        XCTAssertTrue(phases.contains { if case .downloading(0) = $0 { true } else { false } })
        XCTAssertTrue(phases.contains { if case .downloading(7) = $0 { true } else { false } })
        XCTAssertTrue(phases.contains { if case .downloading(42) = $0 { true } else { false } })
        XCTAssertTrue(phases.contains { if case .downloading(100) = $0 { true } else { false } })
        XCTAssertTrue(phases.contains { if case .transcribing = $0 { true } else { false } })
    }

    func testTranscribeMeetingUsesFinalizeLaneAndMergesFreshSourceTranscriptsByAlignment() async throws {
        let telemetry = TelemetrySpy()
        Telemetry.configure(telemetry)
        let recordingFolder = URL(fileURLWithPath: AppPaths.tempDir)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recordingFolder) }

        let mixedURL = recordingFolder.appendingPathComponent("meeting.m4a")
        let microphoneURL = recordingFolder.appendingPathComponent("microphone.m4a")
        let systemURL = recordingFolder.appendingPathComponent("system.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mixed".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: microphoneURL.path, contents: Data("microphone".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: systemURL.path, contents: Data("system".utf8)))

        await mockSTT.configureSequence(results: [
            STTResult(
                text: "Hello there",
                words: [
                    TimestampedWord(word: "Hello", startMs: 50, endMs: 260, confidence: 0.9),
                    TimestampedWord(word: "there", startMs: 300, endMs: 540, confidence: 0.9),
                ]
            ),
            STTResult(
                text: "Sounds good",
                words: [
                    TimestampedWord(word: "Sounds", startMs: 20, endMs: 280, confidence: 0.9),
                    TimestampedWord(word: "good", startMs: 320, endMs: 560, confidence: 0.9),
                ]
            ),
        ])

        let recording = MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Meeting Demo",
            folderURL: recordingFolder,
            mixedAudioURL: mixedURL,
            microphoneAudioURL: microphoneURL,
            systemAudioURL: systemURL,
            durationSeconds: 1.5,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: nil,
                microphone: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 24_000, sampleRate: 48_000),
                system: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 900, writtenFrameCount: 24_000, sampleRate: 48_000)
            )
        )

        let result = try await service.transcribeMeeting(recording: recording)
        let sttCallCount = await mockSTT.transcribeCallCount
        let jobs = await mockSTT.jobs
        let convertCallCount = await mockAudio.convertCallCount
        let convertURLs = await mockAudio.convertURLs

        XCTAssertEqual(result.fileName, "Meeting Demo")
        XCTAssertEqual(result.filePath, mixedURL.path)
        XCTAssertEqual(result.rawTranscript, "Hello there Sounds good")
        XCTAssertEqual(result.speakerCount, 2)
        XCTAssertEqual(result.speakers, [
            SpeakerInfo(id: "microphone", label: "Me"),
            SpeakerInfo(id: "system", label: "Others"),
        ])
        XCTAssertEqual(result.diarizationSegments, [
            DiarizationSegmentRecord(speakerId: "microphone", startMs: 50, endMs: 540),
            DiarizationSegmentRecord(speakerId: "system", startMs: 920, endMs: 1460),
        ])
        XCTAssertEqual(result.wordTimestamps?.map(\.speakerId), ["microphone", "microphone", "system", "system"])
        XCTAssertEqual(result.wordTimestamps?.map(\.startMs), [50, 300, 920, 1220])
        XCTAssertEqual(sttCallCount, 2)
        XCTAssertEqual(jobs, [.meetingFinalize, .meetingFinalize])
        XCTAssertEqual(convertCallCount, 2)
        XCTAssertEqual(convertURLs, [microphoneURL, systemURL])

        let events = telemetry.snapshot()
        guard case .transcriptionCompleted(
            let source,
            _,
            _,
            _,
            let speakerCount,
            let diarizationRequested,
            let diarizationApplied
        ) = try XCTUnwrap(events.last) else {
            return XCTFail("Expected transcription_completed telemetry")
        }
        XCTAssertEqual(source, .meeting)
        XCTAssertEqual(speakerCount, 2)
        XCTAssertFalse(diarizationRequested)
        XCTAssertFalse(diarizationApplied)
    }

    func testTranscribeMeetingAppliesOptionalSystemDiarizationAdditively() async throws {
        let recordingFolder = URL(fileURLWithPath: AppPaths.tempDir)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recordingFolder) }

        let mixedURL = recordingFolder.appendingPathComponent("meeting.m4a")
        let microphoneURL = recordingFolder.appendingPathComponent("microphone.m4a")
        let systemURL = recordingFolder.appendingPathComponent("system.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mixed".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: microphoneURL.path, contents: Data("microphone".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: systemURL.path, contents: Data("system".utf8)))

        await mockSTT.configureSequence(results: [
            STTResult(
                text: "Hello",
                words: [
                    TimestampedWord(word: "Hello", startMs: 0, endMs: 240, confidence: 0.9),
                ]
            ),
            STTResult(
                text: "Sounds good",
                words: [
                    TimestampedWord(word: "Sounds", startMs: 0, endMs: 240, confidence: 0.9),
                    TimestampedWord(word: "good", startMs: 260, endMs: 520, confidence: 0.9),
                ]
            ),
        ])

        let diarization = MockDiarizationService()
        await diarization.configure(result: MacParakeetDiarizationResult(
            segments: [
                SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 240),
                SpeakerSegment(speakerId: "S2", startMs: 260, endMs: 520),
            ],
            speakerCount: 2,
            speakers: [
                SpeakerInfo(id: "S1", label: "Speaker 1"),
                SpeakerInfo(id: "S2", label: "Speaker 2"),
            ]
        ))

        let service = TranscriptionService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            transcriptionRepo: transcriptionRepo,
            shouldDiarize: { true },
            diarizationService: diarization
        )

        let recording = MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Meeting Demo",
            folderURL: recordingFolder,
            mixedAudioURL: mixedURL,
            microphoneAudioURL: microphoneURL,
            systemAudioURL: systemURL,
            durationSeconds: 1.5,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: nil,
                microphone: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 24_000, sampleRate: 48_000),
                system: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 900, writtenFrameCount: 24_000, sampleRate: 48_000)
            )
        )

        let result = try await service.transcribeMeeting(recording: recording)
        let diarizeCalled = await diarization.diarizeCalled

        XCTAssertTrue(diarizeCalled)
        XCTAssertEqual(result.speakerCount, 3)
        XCTAssertEqual(result.speakers, [
            SpeakerInfo(id: "microphone", label: "Me"),
            SpeakerInfo(id: "system:S1", label: "Others 1"),
            SpeakerInfo(id: "system:S2", label: "Others 2"),
        ])
        XCTAssertEqual(result.wordTimestamps?.map(\.speakerId), ["microphone", "system:S1", "system:S2"])
        XCTAssertEqual(result.diarizationSegments, [
            DiarizationSegmentRecord(speakerId: "microphone", startMs: 0, endMs: 240),
            DiarizationSegmentRecord(speakerId: "system:S1", startMs: 900, endMs: 1140),
            DiarizationSegmentRecord(speakerId: "system:S2", startMs: 1160, endMs: 1420),
        ])
    }

    func testTranscribeMeetingPreservesOverlappingMicrophoneAndSystemSpeech() async throws {
        let recordingFolder = URL(fileURLWithPath: AppPaths.tempDir)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recordingFolder) }

        let mixedURL = recordingFolder.appendingPathComponent("meeting.m4a")
        let microphoneURL = recordingFolder.appendingPathComponent("microphone.m4a")
        let systemURL = recordingFolder.appendingPathComponent("system.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mixed".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: microphoneURL.path, contents: Data("microphone".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: systemURL.path, contents: Data("system".utf8)))

        await mockSTT.configureSequence(results: [
            STTResult(
                text: "Can you hear me",
                words: [
                    TimestampedWord(word: "Can", startMs: 120, endMs: 220, confidence: 0.9),
                    TimestampedWord(word: "you", startMs: 240, endMs: 320, confidence: 0.9),
                    TimestampedWord(word: "hear", startMs: 340, endMs: 450, confidence: 0.9),
                    TimestampedWord(word: "me", startMs: 470, endMs: 540, confidence: 0.9),
                ]
            ),
            STTResult(
                text: "Can you hear me",
                words: [
                    TimestampedWord(word: "Can", startMs: 0, endMs: 100, confidence: 0.9),
                    TimestampedWord(word: "you", startMs: 120, endMs: 200, confidence: 0.9),
                    TimestampedWord(word: "hear", startMs: 220, endMs: 330, confidence: 0.9),
                    TimestampedWord(word: "me", startMs: 350, endMs: 420, confidence: 0.9),
                ]
            ),
        ])

        let recording = MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Meeting Demo",
            folderURL: recordingFolder,
            mixedAudioURL: mixedURL,
            microphoneAudioURL: microphoneURL,
            systemAudioURL: systemURL,
            durationSeconds: 1.5,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: nil,
                microphone: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 24_000, sampleRate: 48_000),
                system: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 24_000, sampleRate: 48_000)
            )
        )

        let result = try await service.transcribeMeeting(recording: recording)

        XCTAssertEqual(result.rawTranscript, "Can Can you hear you hear me me")
        XCTAssertEqual(result.wordTimestamps?.map(\.speakerId), [
            "system", "microphone", "system", "system", "microphone", "microphone", "system", "microphone",
        ])
        XCTAssertEqual(result.speakers, [
            SpeakerInfo(id: "microphone", label: "Me"),
            SpeakerInfo(id: "system", label: "Others"),
        ])
    }

    func testTranscribeMeetingKeepsFallbackSystemSpeakerWhenDiarizationDoesNotCoverEveryWord() async throws {
        let recordingFolder = URL(fileURLWithPath: AppPaths.tempDir)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recordingFolder) }

        let mixedURL = recordingFolder.appendingPathComponent("meeting.m4a")
        let systemURL = recordingFolder.appendingPathComponent("system.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mixed".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: systemURL.path, contents: Data("system".utf8)))

        await mockSTT.configureSequence(results: [
            STTResult(
                text: "Hello there",
                words: [
                    TimestampedWord(word: "Hello", startMs: 0, endMs: 180, confidence: 0.9),
                    TimestampedWord(word: "there", startMs: 200, endMs: 360, confidence: 0.9),
                ]
            ),
        ])

        let diarization = MockDiarizationService()
        await diarization.configure(result: MacParakeetDiarizationResult(
            segments: [
                SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 180),
            ],
            speakerCount: 1,
            speakers: [
                SpeakerInfo(id: "S1", label: "Speaker 1"),
            ]
        ))

        let service = TranscriptionService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            transcriptionRepo: transcriptionRepo,
            shouldDiarize: { true },
            diarizationService: diarization
        )

        let recording = MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Meeting Demo",
            folderURL: recordingFolder,
            mixedAudioURL: mixedURL,
            microphoneAudioURL: recordingFolder.appendingPathComponent("microphone.m4a"),
            systemAudioURL: systemURL,
            durationSeconds: 1.0,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: nil,
                microphone: nil,
                system: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 24_000, sampleRate: 48_000)
            )
        )

        let result = try await service.transcribeMeeting(recording: recording)

        XCTAssertEqual(result.wordTimestamps?.map(\.speakerId), ["system:S1", "system"])
        XCTAssertEqual(result.speakers, [
            SpeakerInfo(id: "system", label: "Others"),
            SpeakerInfo(id: "system:S1", label: "Others 1"),
        ])
    }

    func testTranscribeMeetingPreservesSingleSourceModelText() async throws {
        let recordingFolder = URL(fileURLWithPath: AppPaths.tempDir)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recordingFolder) }

        let mixedURL = recordingFolder.appendingPathComponent("meeting.m4a")
        let microphoneURL = recordingFolder.appendingPathComponent("microphone.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mixed".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: microphoneURL.path, contents: Data("microphone".utf8)))

        await mockSTT.configureSequence(results: [
            STTResult(
                text: "Hello, there.",
                words: [
                    TimestampedWord(word: "Hello", startMs: 0, endMs: 180, confidence: 0.9),
                    TimestampedWord(word: "there", startMs: 220, endMs: 420, confidence: 0.9),
                ]
            ),
        ])

        let recording = MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Meeting Demo",
            folderURL: recordingFolder,
            mixedAudioURL: mixedURL,
            microphoneAudioURL: microphoneURL,
            systemAudioURL: recordingFolder.appendingPathComponent("system.m4a"),
            durationSeconds: 1.0,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: nil,
                microphone: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 24_000, sampleRate: 48_000),
                system: nil
            )
        )

        let result = try await service.transcribeMeeting(recording: recording)

        XCTAssertEqual(result.rawTranscript, "Hello, there.")
        XCTAssertEqual(result.wordTimestamps?.map(\.speakerId), ["microphone", "microphone"])
    }

    func testTranscribeMeetingPreservesSingleSourceModelTextWithoutWordTimestamps() async throws {
        let recordingFolder = URL(fileURLWithPath: AppPaths.tempDir)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recordingFolder) }

        let mixedURL = recordingFolder.appendingPathComponent("meeting.m4a")
        let microphoneURL = recordingFolder.appendingPathComponent("microphone.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mixed".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: microphoneURL.path, contents: Data("microphone".utf8)))

        await mockSTT.configureSequence(results: [
            STTResult(
                text: "Hello, there.",
                words: []
            ),
        ])

        let recording = MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Meeting Demo",
            folderURL: recordingFolder,
            mixedAudioURL: mixedURL,
            microphoneAudioURL: microphoneURL,
            systemAudioURL: recordingFolder.appendingPathComponent("system.m4a"),
            durationSeconds: 1.0,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: nil,
                microphone: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 24_000, sampleRate: 48_000),
                system: nil
            )
        )

        let result = try await service.transcribeMeeting(recording: recording)

        XCTAssertEqual(result.rawTranscript, "Hello, there.")
        XCTAssertEqual(result.wordTimestamps, [])
    }

    func testTranscribeMeetingPreservesContiguousDualSourceModelText() async throws {
        let recordingFolder = URL(fileURLWithPath: AppPaths.tempDir)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recordingFolder) }

        let mixedURL = recordingFolder.appendingPathComponent("meeting.m4a")
        let microphoneURL = recordingFolder.appendingPathComponent("microphone.m4a")
        let systemURL = recordingFolder.appendingPathComponent("system.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mixed".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: microphoneURL.path, contents: Data("microphone".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: systemURL.path, contents: Data("system".utf8)))

        await mockSTT.configureSequence(results: [
            STTResult(
                text: "Hello, there.",
                words: [
                    TimestampedWord(word: "hello", startMs: 0, endMs: 180, confidence: 0.9),
                    TimestampedWord(word: "there", startMs: 220, endMs: 420, confidence: 0.9),
                ]
            ),
            STTResult(
                text: "Sounds good.",
                words: [
                    TimestampedWord(word: "sounds", startMs: 20, endMs: 280, confidence: 0.9),
                    TimestampedWord(word: "good", startMs: 320, endMs: 560, confidence: 0.9),
                ]
            ),
        ])

        let recording = MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Meeting Demo",
            folderURL: recordingFolder,
            mixedAudioURL: mixedURL,
            microphoneAudioURL: microphoneURL,
            systemAudioURL: systemURL,
            durationSeconds: 1.5,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: nil,
                microphone: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 24_000, sampleRate: 48_000),
                system: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 900, writtenFrameCount: 24_000, sampleRate: 48_000)
            )
        )

        let result = try await service.transcribeMeeting(recording: recording)

        XCTAssertEqual(result.rawTranscript, "Hello, there. Sounds good.")
    }

    func testTranscribeMeetingPreservesContiguousSourceTextWhenOneSourceHasNoWordTimestamps() async throws {
        let recordingFolder = URL(fileURLWithPath: AppPaths.tempDir)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recordingFolder) }

        let mixedURL = recordingFolder.appendingPathComponent("meeting.m4a")
        let microphoneURL = recordingFolder.appendingPathComponent("microphone.m4a")
        let systemURL = recordingFolder.appendingPathComponent("system.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mixed".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: microphoneURL.path, contents: Data("microphone".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: systemURL.path, contents: Data("system".utf8)))

        await mockSTT.configureSequence(results: [
            STTResult(
                text: "Hello, there.",
                words: []
            ),
            STTResult(
                text: "Sounds good.",
                words: [
                    TimestampedWord(word: "sounds", startMs: 20, endMs: 280, confidence: 0.9),
                    TimestampedWord(word: "good", startMs: 320, endMs: 560, confidence: 0.9),
                ]
            ),
        ])

        let recording = MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Meeting Demo",
            folderURL: recordingFolder,
            mixedAudioURL: mixedURL,
            microphoneAudioURL: microphoneURL,
            systemAudioURL: systemURL,
            durationSeconds: 1.5,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: nil,
                microphone: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 24_000, sampleRate: 48_000),
                system: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 900, writtenFrameCount: 24_000, sampleRate: 48_000)
            )
        )

        let result = try await service.transcribeMeeting(recording: recording)

        XCTAssertEqual(result.rawTranscript, "Hello, there. Sounds good.")
        XCTAssertEqual(result.wordTimestamps?.map(\.speakerId), ["system", "system"])
    }

    func testTranscribeMeetingSttFailureEmitsSttStageTelemetry() async throws {
        let telemetry = TelemetrySpy()
        Telemetry.configure(telemetry)

        let recordingFolder = URL(fileURLWithPath: AppPaths.tempDir)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recordingFolder) }

        let mixedURL = recordingFolder.appendingPathComponent("meeting.m4a")
        let microphoneURL = recordingFolder.appendingPathComponent("microphone.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mixed".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: microphoneURL.path, contents: Data("microphone".utf8)))

        await mockSTT.configure(error: STTError.transcriptionFailed("Model error"))

        let recording = MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Meeting Demo",
            folderURL: recordingFolder,
            mixedAudioURL: mixedURL,
            microphoneAudioURL: microphoneURL,
            systemAudioURL: recordingFolder.appendingPathComponent("system.m4a"),
            durationSeconds: 1.0,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: nil,
                microphone: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 24_000, sampleRate: 48_000),
                system: nil
            )
        )

        do {
            _ = try await service.transcribeMeeting(recording: recording)
            XCTFail("Should have thrown")
        } catch let error as STTError {
            guard case .transcriptionFailed = error else {
                return XCTFail("Unexpected STT error: \(error)")
            }
        }

        let events = telemetry.snapshot()
        guard case .transcriptionFailed(let source, let stage, let errorType, _) = try XCTUnwrap(events.last) else {
            return XCTFail("Expected transcription_failed telemetry")
        }
        XCTAssertEqual(source, .meeting)
        XCTAssertEqual(stage, .stt)
        XCTAssertEqual(errorType, "STTError.transcriptionFailed")
    }

    func testMeetingSourceRetranscribeUsesBatchLane() async throws {
        let expectedResult = STTResult(text: "Meeting archive retranscribe")
        await mockSTT.configure(result: expectedResult)

        let fileURL = URL(fileURLWithPath: "/tmp/meeting-archive.m4a")
        _ = try await service.transcribe(fileURL: fileURL, source: .meeting)

        let lastJob = await mockSTT.lastJob
        XCTAssertEqual(lastJob, .fileTranscription)
    }

    func testTranscribeURLDownloadFailureEmitsDownloadStageTelemetry() async throws {
        let telemetry = TelemetrySpy()
        Telemetry.configure(telemetry)
        let downloader = FailingYouTubeDownloader(
            error: YouTubeDownloadError.downloadFailed("yt-dlp failed")
        )

        let service = TranscriptionService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            transcriptionRepo: transcriptionRepo,
            youtubeDownloader: downloader
        )

        do {
            _ = try await service.transcribeURL(urlString: "https://youtu.be/dQw4w9WgXcQ")
            XCTFail("Should have thrown")
        } catch let error as YouTubeDownloadError {
            guard case .downloadFailed = error else {
                return XCTFail("Unexpected download error: \(error)")
            }
        }

        let events = telemetry.snapshot()
        guard case .transcriptionFailed(let source, let stage, let errorType, _) = try XCTUnwrap(events.last) else {
            return XCTFail("Expected transcription_failed telemetry")
        }
        XCTAssertEqual(source, .youtube)
        XCTAssertEqual(stage, .download)
        XCTAssertEqual(errorType, "YouTubeDownloadError.downloadFailed")
    }

    private func makeTempDownloadedAudio() throws -> URL {
        try AppPaths.ensureDirectories()
        let url = URL(fileURLWithPath: AppPaths.tempDir)
            .appendingPathComponent("downloaded-\(UUID().uuidString).m4a")
        let created = FileManager.default.createFile(atPath: url.path, contents: Data("audio".utf8))
        XCTAssertTrue(created)
        return url
    }
}
