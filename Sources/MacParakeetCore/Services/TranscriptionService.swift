import Foundation
import OSLog

public protocol TranscriptionServiceProtocol: Sendable {
    func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription
    func transcribeMeeting(
        recording: MeetingRecordingOutput,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription
    func transcribeURL(urlString: String, onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> Transcription
}

extension TranscriptionServiceProtocol {
    public func transcribe(fileURL: URL) async throws -> Transcription {
        try await transcribe(fileURL: fileURL, source: .file, onProgress: nil)
    }

    public func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource
    ) async throws -> Transcription {
        try await transcribe(fileURL: fileURL, source: source, onProgress: nil)
    }

    public func transcribeURL(urlString: String) async throws -> Transcription {
        try await transcribeURL(urlString: urlString, onProgress: nil)
    }

    public func transcribeMeeting(recording: MeetingRecordingOutput) async throws -> Transcription {
        try await transcribeMeeting(recording: recording, onProgress: nil)
    }
}

public actor TranscriptionService: TranscriptionServiceProtocol {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "TranscriptionService")
    private let audioProcessor: AudioProcessorProtocol
    private let sttTranscriber: STTTranscribing
    private let transcriptionRepo: TranscriptionRepositoryProtocol
    private let entitlements: EntitlementsChecking?
    private let customWordRepo: CustomWordRepositoryProtocol?
    private let snippetRepo: TextSnippetRepositoryProtocol?
    private let processingMode: @Sendable () -> Dictation.ProcessingMode
    private let textRefinementService: TextRefinementService
    private let llmService: LLMServiceProtocol?
    private let shouldUseAIFormatter: @Sendable () -> Bool
    private let aiFormatterPromptTemplate: @Sendable () -> String
    private let shouldKeepDownloadedAudio: @Sendable () -> Bool
    private let shouldDiarize: @Sendable () -> Bool
    private let youtubeDownloader: YouTubeDownloading?
    private let diarizationService: DiarizationServiceProtocol?

    public init(
        audioProcessor: AudioProcessorProtocol,
        sttTranscriber: STTTranscribing,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        entitlements: EntitlementsChecking? = nil,
        customWordRepo: CustomWordRepositoryProtocol? = nil,
        snippetRepo: TextSnippetRepositoryProtocol? = nil,
        processingMode: (@Sendable () -> Dictation.ProcessingMode)? = nil,
        llmService: LLMServiceProtocol? = nil,
        shouldUseAIFormatter: (@Sendable () -> Bool)? = nil,
        aiFormatterPromptTemplate: (@Sendable () -> String)? = nil,
        shouldKeepDownloadedAudio: (@Sendable () -> Bool)? = nil,
        shouldDiarize: (@Sendable () -> Bool)? = nil,
        youtubeDownloader: YouTubeDownloading? = nil,
        diarizationService: DiarizationServiceProtocol? = nil
    ) {
        self.audioProcessor = audioProcessor
        self.sttTranscriber = sttTranscriber
        self.transcriptionRepo = transcriptionRepo
        self.entitlements = entitlements
        self.customWordRepo = customWordRepo
        self.snippetRepo = snippetRepo
        self.processingMode = processingMode ?? { .raw }
        self.textRefinementService = TextRefinementService()
        self.llmService = llmService
        self.shouldUseAIFormatter = shouldUseAIFormatter ?? { false }
        self.aiFormatterPromptTemplate = aiFormatterPromptTemplate ?? { AIFormatter.defaultPromptTemplate }
        self.shouldKeepDownloadedAudio = shouldKeepDownloadedAudio ?? { true }
        self.shouldDiarize = shouldDiarize ?? { true }
        self.youtubeDownloader = youtubeDownloader
        self.diarizationService = diarizationService
    }

    public func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource = .file,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        let sourceType: Transcription.SourceType = switch source {
        case .youtube:
            .youtube
        case .meeting:
            .meeting
        case .file, .dragDrop:
            .file
        }
        return try await transcribe(
            fileURL: fileURL,
            storedFileURL: fileURL,
            displayFileName: nil,
            source: source,
            sttJob: .fileTranscription,
            sourceType: sourceType,
            onProgress: onProgress
        )
    }

    public func transcribeMeeting(
        recording: MeetingRecordingOutput,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        if let entitlements {
            try await entitlements.assertCanTranscribe(now: Date())
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: recording.mixedAudioURL.path)[.size] as? Int)
            .flatMap { $0 }

        var transcription = Transcription(
            fileName: recording.displayName,
            filePath: recording.mixedAudioURL.path,
            fileSizeBytes: fileSize,
            status: .processing,
            sourceType: .meeting
        )
        try transcriptionRepo.save(transcription)
        Telemetry.send(.transcriptionStarted(
            source: .meeting,
            audioDurationSeconds: recording.durationSeconds
        ))

        return try await transcribeMeetingAudio(
            recording: recording,
            transcription: &transcription,
            onProgress: onProgress
        )
    }

    private func transcribe(
        fileURL: URL,
        storedFileURL: URL?,
        displayFileName: String?,
        source: TelemetryTranscriptionSource,
        sttJob: STTJobKind,
        sourceType: Transcription.SourceType,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        if let entitlements {
            try await entitlements.assertCanTranscribe(now: Date())
        }

        let fileName = displayFileName ?? storedFileURL?.lastPathComponent ?? fileURL.lastPathComponent
        let fileSize = storedFileURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int).flatMap { $0 }
        }

        var transcription = Transcription(
            fileName: fileName,
            filePath: storedFileURL?.path,
            fileSizeBytes: fileSize,
            status: .processing,
            sourceType: sourceType
        )
        try transcriptionRepo.save(transcription)
        Telemetry.send(.transcriptionStarted(source: source, audioDurationSeconds: nil))

        // Extract thumbnail from video files (non-blocking)
        if Self.isVideoFile(fileURL) {
            let transcriptionId = transcription.id
            let path = fileURL.path
            let logger = self.logger
            Task.detached(priority: .utility) {
                do {
                    _ = try await ThumbnailCacheService.shared.extractVideoFrame(from: path, for: transcriptionId)
                } catch {
                    logger.error("Thumbnail extraction failed for \(transcriptionId): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        return try await transcribeAudio(
            fileURL: fileURL,
            source: source,
            sttJob: sttJob,
            transcription: &transcription,
            tempFiles: [],
            onProgress: onProgress
        )
    }

    public func transcribeURL(urlString: String, onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil) async throws -> Transcription {
        guard let downloader = youtubeDownloader else {
            throw YouTubeDownloadError.ytDlpNotFound
        }

        if let entitlements {
            try await entitlements.assertCanTranscribe(now: Date())
        }

        let downloadResult: YouTubeDownloader.DownloadResult
        do {
            onProgress?(.downloading(percent: 0))
            downloadResult = try await downloader.download(url: urlString) { percent in
                onProgress?(.downloading(percent: percent))
            }
        } catch {
            if error is CancellationError {
                Telemetry.send(.transcriptionCancelled(
                    source: .youtube,
                    audioDurationSeconds: nil,
                    stage: .download
                ))
            } else {
                Telemetry.send(.transcriptionFailed(
                    source: .youtube,
                    stage: .download,
                    errorType: Self.errorType(for: error),
                    errorDetail: TelemetryErrorClassifier.errorDetail(error)
                ))
            }
            throw error
        }
        onProgress?(.downloading(percent: 100))
        do {
            try Task.checkCancellation()
        } catch {
            Telemetry.send(.transcriptionCancelled(
                source: .youtube,
                audioDurationSeconds: downloadResult.durationSeconds.map(Double.init),
                stage: .download
            ))
            throw error
        }
        let keepDownloadedAudio = shouldKeepDownloadedAudio()

        var transcription = Transcription(
            fileName: downloadResult.title,
            filePath: keepDownloadedAudio ? downloadResult.audioFileURL.path : nil,
            status: .processing,
            sourceURL: urlString,
            thumbnailURL: downloadResult.thumbnailURL,
            channelName: downloadResult.channelName,
            videoDescription: downloadResult.videoDescription,
            sourceType: .youtube
        )
        try transcriptionRepo.save(transcription)
        Telemetry.send(.transcriptionStarted(
            source: .youtube,
            audioDurationSeconds: downloadResult.durationSeconds.map(Double.init)
        ))

        // Cache YouTube thumbnail locally (non-blocking)
        if let thumbURL = downloadResult.thumbnailURL {
            let transcriptionId = transcription.id
            let logger = self.logger
            Task.detached(priority: .utility) {
                do {
                    _ = try await ThumbnailCacheService.shared.downloadThumbnail(from: thumbURL, for: transcriptionId)
                } catch {
                    logger.error("Thumbnail download failed for \(transcriptionId): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        onProgress?(.transcribing(percent: 0))
        return try await transcribeAudio(
            fileURL: downloadResult.audioFileURL,
            source: .youtube,
            sttJob: .fileTranscription,
            transcription: &transcription,
            tempFiles: [downloadResult.audioFileURL],
            cleanUpDownloadedFiles: !keepDownloadedAudio,
            onProgress: onProgress
        )
    }

    // MARK: - Private

    private func transcribeMeetingAudio(
        recording: MeetingRecordingOutput,
        transcription: inout Transcription,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        let processingStartedAt = Date()
        var lifecycleStage: TelemetryTranscriptionStage = .audioConversion
        let diarizationRequested = diarizationService != nil && shouldDiarize() && recording.sourceAlignment.system != nil
        var temporaryWavURLs: [URL] = []
        var sourceWavURLs: [AudioSource: URL] = [:]
        defer {
            for wavURL in temporaryWavURLs {
                try? FileManager.default.removeItem(at: wavURL)
            }
        }

        do {
            let sourceResults = try await transcribeMeetingSources(
                recording: recording,
                lifecycleStage: &lifecycleStage,
                temporaryWavURLs: &temporaryWavURLs,
                sourceWavURLs: &sourceWavURLs,
                onProgress: onProgress
            )

            let systemDiarization = try await diarizeMeetingSystemIfNeeded(
                recording: recording,
                sourceWavURLs: sourceWavURLs,
                requested: diarizationRequested,
                lifecycleStage: &lifecycleStage,
                onProgress: onProgress
            )

            let finalized = MeetingTranscriptFinalizer.finalize(
                sourceTranscripts: sourceResults,
                systemDiarization: systemDiarization
            )

            transcription.rawTranscript = finalized.rawTranscript
            transcription.wordTimestamps = finalized.words
            transcription.durationMs = max(
                Int((recording.durationSeconds * 1000).rounded()),
                finalized.durationMs ?? 0
            )
            transcription.speakers = finalized.speakers
            transcription.speakerCount = finalized.speakers.isEmpty ? nil : finalized.speakers.count
            transcription.diarizationSegments = finalized.diarizationSegments.isEmpty ? nil : finalized.diarizationSegments

            lifecycleStage = .postProcessing
            let completed = try await completeTranscription(
                source: .meeting,
                transcription: &transcription,
                rawText: finalized.rawTranscript,
                processingStartedAt: processingStartedAt,
                diarizationRequested: diarizationRequested,
                diarizationApplied: systemDiarization != nil
            )

            return completed
        } catch {
            let audioDurationSeconds = transcription.durationMs.map { Double($0) / 1000.0 } ?? recording.durationSeconds
            if error is CancellationError {
                Telemetry.send(.transcriptionCancelled(
                    source: .meeting,
                    audioDurationSeconds: audioDurationSeconds,
                    stage: lifecycleStage
                ))
            } else {
                Telemetry.send(.transcriptionFailed(
                    source: .meeting,
                    stage: lifecycleStage,
                    errorType: Self.errorType(for: error),
                    errorDetail: TelemetryErrorClassifier.errorDetail(error)
                ))
            }

            let txID = transcription.id
            if error is CancellationError {
                do {
                    try transcriptionRepo.updateStatus(
                        id: txID,
                        status: .cancelled,
                        errorMessage: nil
                    )
                } catch let dbError {
                    logger.error("failed_to_update_cancelled_status id=\(txID) dbError=\(dbError.localizedDescription, privacy: .public)")
                }
            } else {
                do {
                    try transcriptionRepo.updateStatus(
                        id: txID,
                        status: .error,
                        errorMessage: error.localizedDescription
                    )
                } catch let dbError {
                    logger.error("failed_to_update_error_status id=\(txID) dbError=\(dbError.localizedDescription, privacy: .public)")
                }
            }
            throw error
        }
    }

    private func transcribeMeetingSources(
        recording: MeetingRecordingOutput,
        lifecycleStage: inout TelemetryTranscriptionStage,
        temporaryWavURLs: inout [URL],
        sourceWavURLs: inout [AudioSource: URL],
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> [MeetingTranscriptFinalizer.SourceTranscript] {
        var outputs: [MeetingTranscriptFinalizer.SourceTranscript] = []
        let activeSources = [AudioSource.microphone, .system].filter { recording.sourceAlignment.track(for: $0) != nil }

        for (index, source) in activeSources.enumerated() {
            let fileURL = meetingAudioURL(for: source, recording: recording)
            lifecycleStage = .audioConversion
            onProgress?(.converting)
            let wavURL = try await audioProcessor.convert(fileURL: fileURL)
            temporaryWavURLs.append(wavURL)
            sourceWavURLs[source] = wavURL

            lifecycleStage = .stt
            onProgress?(.transcribing(percent: Int((Double(index) / Double(max(activeSources.count, 1))) * 100)))
            let result = try await sttTranscriber.transcribe(
                audioPath: wavURL.path,
                job: .meetingFinalize,
                onProgress: meetingSourceProgressMapper(
                    sourceIndex: index,
                    sourceCount: activeSources.count,
                    onProgress: onProgress
                )
            )

            outputs.append(
                .init(
                    source: source,
                    result: result,
                    startOffsetMs: recording.sourceAlignment.track(for: source)?.startOffsetMs ?? 0
                )
            )
        }

        return outputs
    }

    private func diarizeMeetingSystemIfNeeded(
        recording: MeetingRecordingOutput,
        sourceWavURLs: [AudioSource: URL],
        requested: Bool,
        lifecycleStage: inout TelemetryTranscriptionStage,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> MeetingTranscriptFinalizer.SystemDiarization? {
        guard requested, let diarizationService else { return nil }
        guard let systemTrack = recording.sourceAlignment.system else { return nil }
        guard let systemWavURL = sourceWavURLs[.system] else { return nil }

        lifecycleStage = .diarization
        do {
            onProgress?(.identifyingSpeakers)
            Telemetry.send(.diarizationStarted(source: .meeting))
            let diarStartedAt = Date()
            let diarResult = try await diarizationService.diarize(audioURL: systemWavURL)
            let diarDuration = Date().timeIntervalSince(diarStartedAt)
            Telemetry.send(.diarizationCompleted(
                source: .meeting,
                speakerCount: diarResult.speakerCount,
                durationSeconds: diarDuration
            ))

            guard !diarResult.segments.isEmpty else { return nil }

            let mappedSpeakers = diarResult.speakers.enumerated().map { index, speaker in
                SpeakerInfo(
                    id: "\(AudioSource.system.rawValue):\(speaker.id)",
                    label: "\(AudioSource.system.displayLabel) \(index + 1)"
                )
            }
            let speakerIDMap = Dictionary(uniqueKeysWithValues: zip(
                diarResult.speakers.map(\.id),
                mappedSpeakers.map(\.id)
            ))
            let mappedSegments = diarResult.segments.map { segment in
                SpeakerSegment(
                    speakerId: speakerIDMap[segment.speakerId] ?? "\(AudioSource.system.rawValue):\(segment.speakerId)",
                    startMs: segment.startMs + systemTrack.startOffsetMs,
                    endMs: segment.endMs + systemTrack.startOffsetMs
                )
            }

            return MeetingTranscriptFinalizer.SystemDiarization(
                speakers: mappedSpeakers,
                segments: mappedSegments
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("meeting_system_diarization_failed error=\(error.localizedDescription, privacy: .public)")
            Telemetry.send(.diarizationFailed(
                source: .meeting,
                errorType: String(describing: type(of: error)),
                errorDetail: TelemetryErrorClassifier.errorDetail(error)
            ))
            return nil
        }
    }

    private func meetingAudioURL(for source: AudioSource, recording: MeetingRecordingOutput) -> URL {
        switch source {
        case .microphone:
            return recording.microphoneAudioURL
        case .system:
            return recording.systemAudioURL
        }
    }

    private func meetingSourceProgressMapper(
        sourceIndex: Int,
        sourceCount: Int,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) -> (@Sendable (Int, Int) -> Void)? {
        guard let onProgress else { return nil }
        return { current, total in
            let phaseSpan = max(1, sourceCount)
            let sourceFraction = total > 0 ? Double(current) / Double(total) : 0
            let overall = (Double(sourceIndex) + sourceFraction) / Double(phaseSpan)
            let percent = min(Int((overall * 100).rounded()), 99)
            onProgress(.transcribing(percent: percent))
        }
    }

    private func transcribeAudio(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        sttJob: STTJobKind,
        transcription: inout Transcription,
        tempFiles: [URL],
        cleanUpDownloadedFiles: Bool = true,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        var wavURL: URL?
        let processingStartedAt = Date()
        var lifecycleStage: TelemetryTranscriptionStage = .audioConversion
        let diarizationRequested = diarizationService != nil && shouldDiarize()
        do {
            onProgress?(.converting)
            wavURL = try await audioProcessor.convert(fileURL: fileURL)

            guard let wavURL else {
                throw AudioProcessorError.conversionFailed("Failed to produce WAV output")
            }

            onProgress?(.transcribing(percent: 0))
            lifecycleStage = .stt
            let sttProgress: (@Sendable (Int, Int) -> Void)? = onProgress.map { callback in
                { @Sendable current, total in
                    let pct = total > 0 ? Int(Double(current) / Double(total) * 100) : 0
                    callback(.transcribing(percent: min(pct, 99)))
                }
            }
            let result = try await sttTranscriber.transcribe(
                audioPath: wavURL.path,
                job: sttJob,
                onProgress: sttProgress
            )

            let words = result.words.map { word in
                WordTimestamp(
                    word: word.word,
                    startMs: word.startMs,
                    endMs: word.endMs,
                    confidence: word.confidence
                )
            }

            transcription.rawTranscript = result.text
            transcription.wordTimestamps = words
            transcription.durationMs = result.words.last?.endMs

            let diarizationApplied: Bool
            if let diarizationService, shouldDiarize() {
                lifecycleStage = .diarization
                do {
                    onProgress?(.identifyingSpeakers)
                    Telemetry.send(.diarizationStarted(source: source))
                    let diarStartedAt = Date()
                    let diarResult = try await diarizationService.diarize(audioURL: wavURL)
                    let diarDuration = Date().timeIntervalSince(diarStartedAt)
                    if !diarResult.segments.isEmpty {
                        let mergedWords = SpeakerMerger.mergeWordTimestampsWithSpeakers(
                            words: words,
                            segments: diarResult.segments
                        )
                        transcription.wordTimestamps = mergedWords
                        transcription.speakerCount = diarResult.speakerCount
                        transcription.speakers = diarResult.speakers
                        transcription.diarizationSegments = diarResult.segments.map {
                            DiarizationSegmentRecord(speakerId: $0.speakerId, startMs: $0.startMs, endMs: $0.endMs)
                        }
                    }
                    diarizationApplied = !diarResult.segments.isEmpty
                    Telemetry.send(.diarizationCompleted(
                        source: source,
                        speakerCount: diarResult.speakerCount,
                        durationSeconds: diarDuration
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    diarizationApplied = false
                    logger.error("diarization_failed error=\(error.localizedDescription, privacy: .public)")
                    Telemetry.send(.diarizationFailed(
                        source: source,
                        errorType: String(describing: type(of: error)),
                        errorDetail: TelemetryErrorClassifier.errorDetail(error)
                    ))
                }
            } else {
                diarizationApplied = false
            }

            lifecycleStage = .postProcessing
            let completed = try await completeTranscription(
                source: source,
                transcription: &transcription,
                rawText: result.text,
                processingStartedAt: processingStartedAt,
                diarizationRequested: diarizationRequested,
                diarizationApplied: diarizationApplied
            )

            try? FileManager.default.removeItem(at: wavURL)
            if cleanUpDownloadedFiles {
                for tempFile in tempFiles {
                    try? FileManager.default.removeItem(at: tempFile)
                }
            }

            return completed
        } catch {
            if let wavURL { try? FileManager.default.removeItem(at: wavURL) }
            if cleanUpDownloadedFiles {
                for tempFile in tempFiles {
                    try? FileManager.default.removeItem(at: tempFile)
                }
            }

            let audioDurationSeconds = transcription.durationMs.map { Double($0) / 1000.0 }
            if error is CancellationError {
                Telemetry.send(.transcriptionCancelled(
                    source: source,
                    audioDurationSeconds: audioDurationSeconds,
                    stage: lifecycleStage
                ))
            } else {
                Telemetry.send(.transcriptionFailed(
                    source: source,
                    stage: lifecycleStage,
                    errorType: Self.errorType(for: error),
                    errorDetail: TelemetryErrorClassifier.errorDetail(error)
                ))
            }

            let txID = transcription.id
            if error is CancellationError {
                do {
                    try transcriptionRepo.updateStatus(
                        id: txID,
                        status: .cancelled,
                        errorMessage: nil
                    )
                } catch let dbError {
                    logger.error("failed_to_update_cancelled_status id=\(txID) dbError=\(dbError.localizedDescription, privacy: .public)")
                }
            } else {
                do {
                    try transcriptionRepo.updateStatus(
                        id: txID,
                        status: .error,
                        errorMessage: error.localizedDescription
                    )
                } catch let dbError {
                    logger.error("failed_to_update_error_status id=\(txID) dbError=\(dbError.localizedDescription, privacy: .public)")
                }
            }
            throw error
        }
    }

    private func completeTranscription(
        source: TelemetryTranscriptionSource,
        transcription: inout Transcription,
        rawText: String,
        processingStartedAt: Date,
        diarizationRequested: Bool,
        diarizationApplied: Bool
    ) async throws -> Transcription {
        let mode = processingMode()
        var customWords: [CustomWord] = []
        var snippets: [TextSnippet] = []
        if mode.usesDeterministicPipeline {
            do { customWords = try customWordRepo?.fetchEnabled() ?? [] }
            catch { logger.error("Failed to fetch custom words: \(error.localizedDescription, privacy: .public)") }
            do { snippets = try snippetRepo?.fetchEnabled() ?? [] }
            catch { logger.error("Failed to fetch snippets: \(error.localizedDescription, privacy: .public)") }
        }

        let refinement = await textRefinementService.refine(
            rawText: rawText,
            mode: mode,
            customWords: customWords,
            snippets: snippets
        )
        let baseText = refinement.text ?? rawText
        let formattedTranscript = try await formatTranscriptIfNeeded(baseText)
        transcription.cleanTranscript = formattedTranscript ?? refinement.text

        if !refinement.expandedSnippetIDs.isEmpty {
            try? snippetRepo?.incrementUseCount(ids: refinement.expandedSnippetIDs)
        }

        transcription.status = .completed
        transcription.updatedAt = Date()
        try transcriptionRepo.save(transcription)

        let outputText = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        let wordCount = outputText.split(whereSeparator: \.isWhitespace).count
        let audioDurationSeconds = transcription.durationMs.map { Double($0) / 1000.0 }
        let processingSeconds = Date().timeIntervalSince(processingStartedAt)
        Telemetry.send(.transcriptionCompleted(
            source: source,
            audioDurationSeconds: audioDurationSeconds,
            processingSeconds: processingSeconds,
            wordCount: wordCount,
            speakerCount: transcription.speakerCount,
            diarizationRequested: diarizationRequested,
            diarizationApplied: diarizationApplied
        ))

        return transcription
    }

    private func formatTranscriptIfNeeded(_ text: String) async throws -> String? {
        guard shouldUseAIFormatter(), let llmService else {
            return nil
        }

        let promptTemplate = aiFormatterPromptTemplate()
        // Normalize before comparing: `AIFormatter.renderPrompt` passes the
        // template through `normalizedPromptTemplate` before sending, which
        // trims whitespace and folds legacy-v1 prompts back onto the current
        // default. Raw comparison would report those cases as custom prompts
        // even though the LLM sees the shipped default.
        let defaultPromptUsed = AIFormatter.normalizedPromptTemplate(promptTemplate)
            == AIFormatter.defaultPromptTemplate
        do {
            let formatted = try await llmService.formatTranscript(
                transcript: text,
                promptTemplate: promptTemplate,
                source: .transcription,
                defaultPromptUsed: defaultPromptUsed
            )
            let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            if error is CancellationError {
                throw error
            }
            logger.warning("AI formatter failed; falling back to standard cleanup error=\(error.localizedDescription, privacy: .public)")
            let message = "\(error.localizedDescription) Used standard cleanup."
            NotificationCenter.default.post(
                name: .macParakeetAIFormatterWarning,
                object: nil,
                userInfo: [
                    "source": "transcription",
                    "message": message,
                ]
            )
            return nil
        }
    }

    private static func errorType(for error: Error) -> String {
        TelemetryErrorClassifier.classify(error)
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "wmv"]

    private static func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }
}
