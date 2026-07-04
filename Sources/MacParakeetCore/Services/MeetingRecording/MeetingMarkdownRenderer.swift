import Foundation

public struct MeetingMarkdownPromptResultFile: Sendable, Equatable {
    public var id: UUID?
    public var name: String
    public var path: String?

    public init(id: UUID? = nil, name: String, path: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
    }
}

public struct MeetingMarkdownArtifactPaths: Sendable, Equatable {
    public var artifactFolderPath: String?
    public var manifestPath: String?
    public var markdownPath: String?
    public var transcriptPath: String?
    public var notesPath: String?
    public var mixedAudioPath: String?
    public var microphoneAudioPath: String?
    public var systemAudioPath: String?
    public var cleanedMicrophoneAudioPath: String?
    public var metadataPath: String?
    public var promptResultsPath: String?
    public var promptResultsDirectoryPath: String?
    public var promptResultFiles: [MeetingMarkdownPromptResultFile]

    public init(
        artifactFolderPath: String? = nil,
        manifestPath: String? = nil,
        markdownPath: String? = nil,
        transcriptPath: String? = nil,
        notesPath: String? = nil,
        mixedAudioPath: String? = nil,
        microphoneAudioPath: String? = nil,
        systemAudioPath: String? = nil,
        cleanedMicrophoneAudioPath: String? = nil,
        metadataPath: String? = nil,
        promptResultsPath: String? = nil,
        promptResultsDirectoryPath: String? = nil,
        promptResultFiles: [MeetingMarkdownPromptResultFile] = []
    ) {
        self.artifactFolderPath = artifactFolderPath
        self.manifestPath = manifestPath
        self.markdownPath = markdownPath
        self.transcriptPath = transcriptPath
        self.notesPath = notesPath
        self.mixedAudioPath = mixedAudioPath
        self.microphoneAudioPath = microphoneAudioPath
        self.systemAudioPath = systemAudioPath
        self.cleanedMicrophoneAudioPath = cleanedMicrophoneAudioPath
        self.metadataPath = metadataPath
        self.promptResultsPath = promptResultsPath
        self.promptResultsDirectoryPath = promptResultsDirectoryPath
        self.promptResultFiles = promptResultFiles
    }

    public static func resolve(
        transcription: Transcription,
        promptResults: [PromptResult],
        fileManager: FileManager = .default
    ) -> MeetingMarkdownArtifactPaths {
        guard let folderURL = MeetingArtifactStore.sessionFolderURL(for: transcription) else {
            return MeetingMarkdownArtifactPaths(
                mixedAudioPath: transcription.filePath,
                promptResultFiles: promptResults.enumerated().map { index, result in
                    MeetingMarkdownPromptResultFile(
                        id: result.id,
                        name: result.promptName,
                        path: nil
                    )
                }
            )
        }

        let manifestURL = folderURL.appendingPathComponent(MeetingArtifactStore.manifestFileName)
        let markdownURL = folderURL.appendingPathComponent(MeetingArtifactStore.markdownFileName)
        let transcriptURL = folderURL.appendingPathComponent(MeetingArtifactStore.transcriptFileName)
        let notesURL = MeetingNotesFile.fileURL(for: folderURL)
        let promptResultsURL = folderURL.appendingPathComponent(MeetingArtifactStore.promptResultsFileName)
        let promptResultsDirectoryURL = folderURL.appendingPathComponent(
            MeetingArtifactStore.promptResultsDirectoryName,
            isDirectory: true
        )
        let microphoneURL = folderURL.appendingPathComponent("microphone.m4a")
        let systemURL = folderURL.appendingPathComponent("system.m4a")
        let cleanedMicrophoneURL = folderURL.appendingPathComponent(
            MeetingCleanedMicRenderer.cleanedMicrophoneFileName
        )
        let metadataURL = MeetingRecordingMetadataStore.metadataURL(for: folderURL)

        return MeetingMarkdownArtifactPaths(
            artifactFolderPath: folderURL.path,
            manifestPath: manifestURL.path,
            markdownPath: markdownURL.path,
            transcriptPath: transcriptURL.path,
            notesPath: normalizedNonEmptyText(transcription.userNotes) == nil ? nil : notesURL.path,
            mixedAudioPath: transcription.filePath,
            microphoneAudioPath: fileManager.fileExists(atPath: microphoneURL.path) ? microphoneURL.path : nil,
            systemAudioPath: fileManager.fileExists(atPath: systemURL.path) ? systemURL.path : nil,
            cleanedMicrophoneAudioPath: MeetingRecordingOutput.isViableCleanedMicrophoneFile(
                at: cleanedMicrophoneURL,
                fileManager: fileManager
            ) ? cleanedMicrophoneURL.path : nil,
            metadataPath: fileManager.fileExists(atPath: metadataURL.path) ? metadataURL.path : nil,
            promptResultsPath: promptResultsURL.path,
            promptResultsDirectoryPath: promptResultsDirectoryURL.path,
            promptResultFiles: promptResults.enumerated().map { index, result in
                MeetingMarkdownPromptResultFile(
                    id: result.id,
                    name: result.promptName,
                    path: promptResultsDirectoryURL
                        .appendingPathComponent(MeetingArtifactStore.promptResultMarkdownFileName(
                            index: index + 1,
                            name: result.promptName
                        ))
                        .path
                )
            }
        )
    }
}

public struct MeetingMarkdownRenderer: Sendable {
    public static let schema = "com.macparakeet.meeting-markdown"
    public static let schemaVersion = 1

    public init() {}

    public func render(
        transcription: Transcription,
        promptResults: [PromptResult],
        artifactPaths: MeetingMarkdownArtifactPaths = .init()
    ) -> String {
        let transcript = renderedTranscript(transcription)
        var sections: [String] = [
            frontmatter(
                transcription: transcription,
                artifactPaths: artifactPaths,
                speakerLabelsIncluded: transcript.speakerLabelsIncluded,
                promptResultCount: promptResults.count
            ),
            "# \(transcription.fileName)",
        ]

        if let notes = normalizedNonEmptyText(transcription.userNotes) {
            sections.append("## Notes\n\n\(notes)")
        }

        sections.append("## Transcript\n\n\(transcript.text)")

        if !promptResults.isEmpty {
            sections.append(promptResultsSection(promptResults, artifactPaths: artifactPaths))
        }

        if let artifactsSection = artifactsSection(artifactPaths) {
            sections.append(artifactsSection)
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    private func frontmatter(
        transcription: Transcription,
        artifactPaths: MeetingMarkdownArtifactPaths,
        speakerLabelsIncluded: Bool,
        promptResultCount: Int
    ) -> String {
        var lines: [String] = ["---"]
        lines.append("schema: \(Self.schema)")
        lines.append("schemaVersion: \(Self.schemaVersion)")
        lines.append("meetingID: \(yamlString(transcription.id.uuidString))")
        lines.append("title: \(yamlString(transcription.fileName))")
        lines.append("createdAt: \(yamlString(isoString(transcription.createdAt)))")
        lines.append("updatedAt: \(yamlString(isoString(transcription.updatedAt)))")
        if let durationMs = transcription.durationMs {
            lines.append("durationMs: \(durationMs)")
        }
        lines.append("status: \(yamlString(transcription.status.rawValue))")
        lines.append("sourceType: \(yamlString(transcription.sourceType.rawValue))")
        appendOptional("engine", transcription.engine, to: &lines)
        appendOptional("engineVariant", transcription.engineVariant, to: &lines)
        appendOptional("artifactFolderPath", artifactPaths.artifactFolderPath, to: &lines)
        appendOptional("manifestPath", artifactPaths.manifestPath, to: &lines)
        appendOptional("markdownPath", artifactPaths.markdownPath, to: &lines)
        appendOptional("transcriptPath", artifactPaths.transcriptPath, to: &lines)
        appendOptional("notesPath", artifactPaths.notesPath, to: &lines)
        appendOptional("mixedAudioPath", artifactPaths.mixedAudioPath, to: &lines)
        appendOptional("microphoneAudioPath", artifactPaths.microphoneAudioPath, to: &lines)
        appendOptional("systemAudioPath", artifactPaths.systemAudioPath, to: &lines)
        appendOptional("cleanedMicrophoneAudioPath", artifactPaths.cleanedMicrophoneAudioPath, to: &lines)
        appendOptional("metadataPath", artifactPaths.metadataPath, to: &lines)
        lines.append("speakerLabelsIncluded: \(speakerLabelsIncluded ? "true" : "false")")
        lines.append("promptResultCount: \(promptResultCount)")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    private func renderedTranscript(_ transcription: Transcription) -> (text: String, speakerLabelsIncluded: Bool) {
        guard transcription.hasSpeakerLabeledWords,
              !transcription.isTranscriptEdited,
              let words = transcription.wordTimestamps,
              !words.isEmpty
        else {
            return (preferredTranscriptText(transcription), false)
        }

        let cues = TranscriptCueBuilder.build(from: words)
        let paragraphs = speakerParagraphs(from: cues, speakers: transcription.speakers)
        guard !paragraphs.isEmpty else {
            return (preferredTranscriptText(transcription), false)
        }

        let text = paragraphs.map { paragraph in
            if let label = paragraph.label {
                return "**\(label)**\n\n\(paragraph.text)"
            }
            return paragraph.text
        }
        .joined(separator: "\n\n")
        return (text, true)
    }

    private struct SpeakerParagraph {
        var speakerId: String?
        var label: String?
        var text: String
    }

    private func speakerParagraphs(from cues: [TranscriptCue], speakers: [SpeakerInfo]?) -> [SpeakerParagraph] {
        var paragraphs: [SpeakerParagraph] = []
        for cue in cues {
            let label = speakerLabel(for: cue.speakerId, in: speakers)
            if let last = paragraphs.indices.last,
               paragraphs[last].speakerId == cue.speakerId {
                paragraphs[last].text += " \(cue.text)"
            } else {
                paragraphs.append(SpeakerParagraph(
                    speakerId: cue.speakerId,
                    label: label,
                    text: cue.text
                ))
            }
        }
        return paragraphs
    }

    private func speakerLabel(for speakerId: String?, in speakers: [SpeakerInfo]?) -> String? {
        guard let speakerId else { return nil }
        guard let speakers, !speakers.isEmpty else { return speakerId }
        return speakers.first(where: { $0.id == speakerId })?.label ?? speakerId
    }

    private func promptResultsSection(
        _ promptResults: [PromptResult],
        artifactPaths: MeetingMarkdownArtifactPaths
    ) -> String {
        var lines = ["## Prompt Results"]
        for (index, result) in promptResults.enumerated() {
            let path = artifactPaths.promptResultFiles.first(where: { $0.id == result.id })?.path
            let prefix = "\(index + 1). \(result.promptName)"
            if let path {
                lines.append("- \(prefix): \(path)")
            } else {
                lines.append("- \(prefix)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func artifactsSection(_ artifactPaths: MeetingMarkdownArtifactPaths) -> String? {
        let entries: [(String, String?)] = [
            ("Artifact folder", artifactPaths.artifactFolderPath),
            ("Manifest", artifactPaths.manifestPath),
            ("Markdown", artifactPaths.markdownPath),
            ("Transcript JSON", artifactPaths.transcriptPath),
            ("Notes", artifactPaths.notesPath),
            ("Mixed audio", artifactPaths.mixedAudioPath),
            ("Microphone audio", artifactPaths.microphoneAudioPath),
            ("System audio", artifactPaths.systemAudioPath),
            ("Cleaned microphone audio", artifactPaths.cleanedMicrophoneAudioPath),
            ("Metadata", artifactPaths.metadataPath),
            ("Prompt results JSON", artifactPaths.promptResultsPath),
            ("Prompt results directory", artifactPaths.promptResultsDirectoryPath),
        ]
        let lines = entries.compactMap { label, path -> String? in
            guard let path else { return nil }
            return "- \(label): \(path)"
        }
        guard !lines.isEmpty else { return nil }
        return (["## Artifacts"] + lines).joined(separator: "\n")
    }

    private func appendOptional(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value = normalizedNonEmptyText(value) else { return }
        lines.append("\(key): \(yamlString(value))")
    }

    private func preferredTranscriptText(_ transcription: Transcription) -> String {
        for candidate in [transcription.cleanTranscript, transcription.rawTranscript] {
            if let text = normalizedNonEmptyText(candidate) {
                return text
            }
        }
        return ""
    }

    private func yamlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private func normalizedNonEmptyText(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty
    else {
        return nil
    }
    return trimmed
}
