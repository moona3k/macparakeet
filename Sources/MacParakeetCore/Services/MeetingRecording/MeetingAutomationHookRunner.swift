import Darwin
import Foundation
import OSLog

public protocol MeetingAutomationHookRunning: Sendable {
    @discardableResult
    func runCompletedMeetingHook(
        transcription: Transcription,
        artifact: MeetingArtifactSnapshot
    ) async -> MeetingAutomationHookResult
}

public struct MeetingAutomationHookConfiguration: Sendable, Equatable {
    public static let enabledKey = "meetingAutomationHookEnabled"
    public static let executablePathKey = "meetingAutomationHookExecutablePath"
    public static let timeoutSecondsKey = "meetingAutomationHookTimeoutSeconds"
    public static let defaultTimeoutSeconds: TimeInterval = 20
    public static let minimumTimeoutSeconds: TimeInterval = 1
    public static let maximumTimeoutSeconds: TimeInterval = 300

    public let enabled: Bool
    public let executablePath: String?
    public let timeoutSeconds: TimeInterval

    public init(
        enabled: Bool = false,
        executablePath: String? = nil,
        timeoutSeconds: TimeInterval = Self.defaultTimeoutSeconds
    ) {
        self.enabled = enabled
        self.executablePath = executablePath
        self.timeoutSeconds = Self.clampedTimeout(timeoutSeconds)
    }

    public static func current(defaults: UserDefaults = .standard) -> MeetingAutomationHookConfiguration {
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? false
        let path = defaults.string(forKey: executablePathKey)
            .flatMap { normalizedExecutablePath($0) }
        let timeout = defaults.object(forKey: timeoutSecondsKey) as? Double ?? defaultTimeoutSeconds
        return MeetingAutomationHookConfiguration(
            enabled: enabled,
            executablePath: path,
            timeoutSeconds: timeout
        )
    }

    public static func normalizedExecutablePath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return nil }
        let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return normalized
    }

    public static func clampedTimeout(_ value: TimeInterval) -> TimeInterval {
        min(max(value, minimumTimeoutSeconds), maximumTimeoutSeconds)
    }
}

public struct MeetingAutomationHookResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case skipped
        case success
        case failed
        case timedOut = "timed_out"
    }

    public let schema: String
    public let schemaVersion: Int
    public let generatedAt: Date
    public let status: Status
    public let meetingID: UUID
    public let executablePath: String?
    public let exitCode: Int32?
    public let durationMs: Int
    public let error: String?

    public init(
        schema: String = MeetingAutomationHookRunner.resultSchema,
        schemaVersion: Int = MeetingAutomationHookRunner.schemaVersion,
        generatedAt: Date = Date(),
        status: Status,
        meetingID: UUID,
        executablePath: String?,
        exitCode: Int32? = nil,
        durationMs: Int,
        error: String? = nil
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.status = status
        self.meetingID = meetingID
        self.executablePath = executablePath
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.error = error
    }
}

public final class MeetingAutomationHookRunner: MeetingAutomationHookRunning, @unchecked Sendable {
    public static let eventSchema = "com.macparakeet.meeting-automation-event"
    public static let resultSchema = "com.macparakeet.meeting-automation-result"
    public static let schemaVersion = 1
    public static let resultFileName = "automation-hook-result.json"
    public static let stderrFileName = "automation-hook.stderr.log"

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingAutomationHookRunner")

    public init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    @discardableResult
    public func runCompletedMeetingHook(
        transcription: Transcription,
        artifact: MeetingArtifactSnapshot
    ) async -> MeetingAutomationHookResult {
        let configuration = MeetingAutomationHookConfiguration.current(defaults: defaults)
        guard configuration.enabled else {
            return MeetingAutomationHookResult(
                status: .skipped,
                meetingID: transcription.id,
                executablePath: configuration.executablePath,
                durationMs: 0,
                error: "Meeting automation hook is disabled."
            )
        }
        guard let executablePath = configuration.executablePath else {
            return await writeResult(
                MeetingAutomationHookResult(
                    status: .skipped,
                    meetingID: transcription.id,
                    executablePath: nil,
                    durationMs: 0,
                    error: "Meeting automation hook executable is not configured."
                ),
                artifact: artifact
            )
        }
        guard fileManager.isExecutableFile(atPath: executablePath) else {
            return await writeResult(
                MeetingAutomationHookResult(
                    status: .failed,
                    meetingID: transcription.id,
                    executablePath: executablePath,
                    durationMs: 0,
                    error: "Configured hook path is not executable."
                ),
                artifact: artifact
            )
        }

        let event = MeetingAutomationHookEvent(
            transcription: transcription,
            artifact: artifact
        )

        do {
            let result = try await Self.runProcess(
                event: event,
                executablePath: executablePath,
                artifact: artifact,
                timeoutSeconds: configuration.timeoutSeconds,
                fileManager: fileManager
            )
            logger.info("meeting_automation_hook_completed id=\(transcription.id.uuidString, privacy: .public) status=\(result.status.rawValue, privacy: .public) exit_code=\(String(describing: result.exitCode), privacy: .public)")
            return await writeResult(result, artifact: artifact)
        } catch {
            logger.error("meeting_automation_hook_failed id=\(transcription.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            return await writeResult(
                MeetingAutomationHookResult(
                    status: .failed,
                    meetingID: transcription.id,
                    executablePath: executablePath,
                    durationMs: 0,
                    error: error.localizedDescription
                ),
                artifact: artifact
            )
        }
    }

    private func writeResult(
        _ result: MeetingAutomationHookResult,
        artifact: MeetingArtifactSnapshot
    ) async -> MeetingAutomationHookResult {
        do {
            let data = try Self.makeEncoder().encode(result)
            let url = URL(fileURLWithPath: artifact.folderPath, isDirectory: true)
                .appendingPathComponent(Self.resultFileName)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("meeting_automation_result_write_failed id=\(result.meetingID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
        }
        return result
    }

    private static func runProcess(
        event: MeetingAutomationHookEvent,
        executablePath: String,
        artifact: MeetingArtifactSnapshot,
        timeoutSeconds: TimeInterval,
        fileManager: FileManager
    ) async throws -> MeetingAutomationHookResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = []
        process.currentDirectoryURL = URL(fileURLWithPath: artifact.folderPath, isDirectory: true)
        var processStarted = false
        defer {
            if processStarted, process.isRunning {
                process.terminate()
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["MACPARAKEET_EVENT"] = "meeting.completed"
        environment["MACPARAKEET_MEETING_ID"] = event.meeting.id.uuidString
        environment["MACPARAKEET_ARTIFACT_DIR"] = artifact.folderPath
        environment["MACPARAKEET_ARTIFACT_MANIFEST"] = artifact.manifestPath
        process.environment = environment

        let stdin = Pipe()
        process.standardInput = stdin
        let nullOutput = FileHandle(forWritingAtPath: "/dev/null")
        if let nullOutput {
            process.standardOutput = nullOutput
        }
        defer { try? nullOutput?.close() }

        let stderrURL = URL(fileURLWithPath: artifact.folderPath, isDirectory: true)
            .appendingPathComponent(stderrFileName)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderrHandle.close() }
        process.standardError = stderrHandle

        let startedAt = Date()
        let eventData = try makeEncoder().encode(event)
        try process.run()
        processStarted = true
        try stdin.fileHandleForWriting.write(contentsOf: eventData)
        try stdin.fileHandleForWriting.close()

        let deadline = startedAt.addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            try await Task.sleep(nanoseconds: 250_000_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            while process.isRunning {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        if timedOut {
            return MeetingAutomationHookResult(
                status: .timedOut,
                meetingID: event.meeting.id,
                executablePath: executablePath,
                exitCode: process.terminationStatus,
                durationMs: durationMs,
                error: "Hook exceeded \(Int(timeoutSeconds))s timeout."
            )
        }
        return MeetingAutomationHookResult(
            status: process.terminationStatus == 0 ? .success : .failed,
            meetingID: event.meeting.id,
            executablePath: executablePath,
            exitCode: process.terminationStatus,
            durationMs: durationMs,
            error: process.terminationStatus == 0 ? nil : "Hook exited with status \(process.terminationStatus)."
        )
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private struct MeetingAutomationHookEvent: Codable {
    let schema: String
    let schemaVersion: Int
    let event: String
    let generatedAt: Date
    let meeting: MeetingAutomationMeeting
    let artifact: MeetingArtifactSnapshot

    init(transcription: Transcription, artifact: MeetingArtifactSnapshot) {
        schema = MeetingAutomationHookRunner.eventSchema
        schemaVersion = MeetingAutomationHookRunner.schemaVersion
        event = "meeting.completed"
        generatedAt = Date()
        meeting = MeetingAutomationMeeting(transcription)
        self.artifact = artifact
    }
}

private struct MeetingAutomationMeeting: Codable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let durationMs: Int?
    let status: Transcription.TranscriptionStatus

    init(_ transcription: Transcription) {
        id = transcription.id
        title = transcription.fileName
        createdAt = transcription.createdAt
        updatedAt = transcription.updatedAt
        durationMs = transcription.durationMs
        status = transcription.status
    }
}
