import Foundation
import OSLog

public struct MeetingAudioLevels: Sendable, Equatable {
    public var microphone: Float
    public var system: Float

    public init(microphone: Float = 0, system: Float = 0) {
        self.microphone = microphone
        self.system = system
    }
}

public enum CaptureMode: Sendable, Equatable {
    case full
    case stopped
}

public protocol MeetingRecordingServiceProtocol: Sendable {
    func startRecording() async throws
    func stopRecording() async throws -> MeetingRecordingOutput
    func cancelRecording() async
    var isRecording: Bool { get async }
    var micLevel: Float { get async }
    var systemLevel: Float { get async }
    var elapsedSeconds: Int { get async }
    var captureMode: CaptureMode { get async }
}

public actor MeetingRecordingService: MeetingRecordingServiceProtocol {
    private struct Session: Sendable {
        let id: UUID
        let displayName: String
        let startedAt: Date
        let folderURL: URL
        let microphoneAudioURL: URL
        let systemAudioURL: URL
        let mixedAudioURL: URL
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingRecordingService")
    private let audioCaptureService: MeetingAudioCaptureService
    private let audioConverter: AudioFileConverter
    private let fileManager: FileManager

    private var currentSession: Session?
    private var writer: MeetingAudioStorageWriter?
    private var processingTask: Task<Void, Never>?
    private var latestLevels = MeetingAudioLevels()

    public init(
        audioCaptureService: MeetingAudioCaptureService = MeetingAudioCaptureService(),
        audioConverter: AudioFileConverter = AudioFileConverter(),
        fileManager: FileManager = .default
    ) {
        self.audioCaptureService = audioCaptureService
        self.audioConverter = audioConverter
        self.fileManager = fileManager
    }

    public var isRecording: Bool {
        currentSession != nil
    }

    public var micLevel: Float {
        latestLevels.microphone
    }

    public var systemLevel: Float {
        latestLevels.system
    }

    public var elapsedSeconds: Int {
        guard let startedAt = currentSession?.startedAt else { return 0 }
        return max(0, Int(Date().timeIntervalSince(startedAt)))
    }

    public var captureMode: CaptureMode {
        currentSession == nil ? .stopped : .full
    }

    public func startRecording() async throws {
        guard currentSession == nil else {
            throw MeetingAudioError.alreadyRunning
        }

        let sessionID = UUID()
        let folderURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        let writer = try MeetingAudioStorageWriter(folderURL: folderURL)
        let session = Session(
            id: sessionID,
            displayName: Self.makeDisplayName(for: Date()),
            startedAt: Date(),
            folderURL: folderURL,
            microphoneAudioURL: writer.microphoneAudioURL,
            systemAudioURL: writer.systemAudioURL,
            mixedAudioURL: writer.mixedAudioURL
        )

        let events = await audioCaptureService.events
        self.latestLevels = MeetingAudioLevels()
        self.writer = writer
        self.currentSession = session

        processingTask = Task { [weak self] in
            guard let self else { return }
            for await event in events {
                await self.handleCaptureEvent(event)
            }
        }

        do {
            try await audioCaptureService.start()
            logger.info("Meeting recording started: \(sessionID.uuidString, privacy: .public)")
        } catch {
            processingTask?.cancel()
            processingTask = nil
            self.writer?.finalize()
            self.writer = nil
            self.currentSession = nil
            try? fileManager.removeItem(at: folderURL)
            throw error
        }
    }

    public func stopRecording() async throws -> MeetingRecordingOutput {
        guard let session = currentSession else {
            throw MeetingAudioError.notRunning
        }

        await audioCaptureService.stop()
        await processingTask?.value
        processingTask = nil
        writer?.finalize()
        writer = nil

        let inputURLs = try existingSourceURLs(for: session)
        guard !inputURLs.isEmpty else {
            cleanupState()
            throw MeetingAudioError.noAudioCaptured
        }

        do {
            try await audioConverter.mixToM4A(inputURLs: inputURLs, outputURL: session.mixedAudioURL)
        } catch {
            cleanupState()
            throw MeetingAudioError.mixFailed(error.localizedDescription)
        }

        let durationSeconds = max(0, Date().timeIntervalSince(session.startedAt))
        let output = MeetingRecordingOutput(
            sessionID: session.id,
            displayName: session.displayName,
            folderURL: session.folderURL,
            mixedAudioURL: session.mixedAudioURL,
            microphoneAudioURL: session.microphoneAudioURL,
            systemAudioURL: session.systemAudioURL,
            durationSeconds: durationSeconds
        )

        cleanupState()
        logger.info("Meeting recording finalized: \(session.id.uuidString, privacy: .public)")
        return output
    }

    public func cancelRecording() async {
        guard let session = currentSession else { return }

        await audioCaptureService.stop()
        processingTask?.cancel()
        await processingTask?.value
        processingTask = nil
        writer?.finalize()
        writer = nil
        cleanupState()
        try? fileManager.removeItem(at: session.folderURL)
        logger.info("Meeting recording cancelled: \(session.id.uuidString, privacy: .public)")
    }

    private func handleCaptureEvent(_ event: MeetingAudioCaptureEvent) {
        switch event {
        case .microphoneBuffer(let buffer, _):
            do {
                try writer?.write(buffer, source: .microphone)
                latestLevels.microphone = buffer.rmsLevel
            } catch {
                logger.error("Failed to write microphone audio: \(error.localizedDescription, privacy: .public)")
            }
        case .systemBuffer(let buffer, _):
            do {
                try writer?.write(buffer, source: .system)
                latestLevels.system = buffer.rmsLevel
            } catch {
                logger.error("Failed to write system audio: \(error.localizedDescription, privacy: .public)")
            }
        case .error(let error):
            logger.error("Meeting capture event error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func existingSourceURLs(for session: Session) throws -> [URL] {
        let candidates = [session.systemAudioURL, session.microphoneAudioURL]
        return try candidates.filter { url in
            guard fileManager.fileExists(atPath: url.path) else { return false }
            let size = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            return (size?.intValue ?? 0) > 0
        }
    }

    private func cleanupState() {
        currentSession = nil
        latestLevels = MeetingAudioLevels()
    }

    private static func makeDisplayName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Meeting \(formatter.string(from: date))"
    }
}
