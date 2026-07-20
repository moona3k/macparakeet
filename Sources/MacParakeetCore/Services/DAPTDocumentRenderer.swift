import Foundation

/// Renders the transcript facts MacParakeet actually has into a W3C DAPT
/// original-transcript document. Missing timing and diarization remain absent;
/// the renderer never manufactures either to make the document look richer.
enum DAPTDocumentRenderer {
    private struct Character {
        let speakerID: String
        let xmlID: String
        let label: String
    }

    static func render(transcription: Transcription) -> String {
        let language = documentLanguage(transcription.language)
        let cues = alignedCues(for: transcription)
        let characters = referencedCharacters(cues: cues, speakers: transcription.speakers)
        let characterIDBySpeakerID = Dictionary(
            uniqueKeysWithValues: characters.map { ($0.speakerID, $0.xmlID) }
        )

        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<tt xmlns=\"http://www.w3.org/ns/ttml\"",
            "    xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\"",
            "    xmlns:ttp=\"http://www.w3.org/ns/ttml#parameter\"",
            "    xmlns:daptm=\"http://www.w3.org/ns/ttml/profile/dapt#metadata\"",
            "    ttp:contentProfiles=\"http://www.w3.org/ns/ttml/profile/dapt1.0/content\"",
            "    xml:lang=\"\(escapeAttribute(language))\"",
        ]
        if language != "und" {
            lines.append("    daptm:langSrc=\"\(escapeAttribute(language))\"")
        }
        lines.append(contentsOf: [
            "    daptm:scriptRepresents=\"audio.dialogue\"",
            "    daptm:scriptType=\"originalTranscript\">",
            "  <head>",
            "    <metadata>",
            "      <ttm:title>\(escapeText(transcription.effectiveDisplayTitle))</ttm:title>",
        ])

        for character in characters {
            lines.append("      <ttm:agent type=\"character\" xml:id=\"\(character.xmlID)\">")
            lines.append("        <ttm:name type=\"alias\">\(escapeText(character.label))</ttm:name>")
            lines.append("      </ttm:agent>")
        }

        lines.append(contentsOf: [
            "    </metadata>",
            "  </head>",
            "  <body>",
        ])

        if cues.isEmpty {
            let text = preferredText(transcription)
            if !text.isEmpty {
                appendEvent(
                    id: 1,
                    text: text,
                    timing: nil,
                    characterID: nil,
                    to: &lines
                )
            }
        } else {
            for (index, cue) in cues.enumerated() {
                appendEvent(
                    id: index + 1,
                    text: cue.text,
                    timing: (cue.startMs, cue.endMs),
                    characterID: cue.speakerId.flatMap { characterIDBySpeakerID[$0] },
                    to: &lines
                )
            }
        }

        lines.append(contentsOf: [
            "  </body>",
            "</tt>",
            "",
        ])
        return lines.joined(separator: "\n")
    }

    private static func alignedCues(for transcription: Transcription) -> [TranscriptCue] {
        guard !transcription.isTranscriptEdited,
            let words = transcription.wordTimestamps,
            !words.isEmpty
        else {
            return []
        }
        return TranscriptCueBuilder.build(from: words)
    }

    private static func preferredText(_ transcription: Transcription) -> String {
        (transcription.cleanTranscript ?? transcription.rawTranscript ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func referencedCharacters(
        cues: [TranscriptCue],
        speakers: [SpeakerInfo]?
    ) -> [Character] {
        let labelsByID = Dictionary(
            (speakers ?? []).map { ($0.id, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        var characters: [Character] = []

        for cue in cues {
            guard let speakerID = cue.speakerId,
                seen.insert(speakerID).inserted
            else {
                continue
            }
            let label = labelsByID[speakerID]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedLabel = label.flatMap { $0.isEmpty ? nil : $0 } ?? speakerID
            characters.append(
                Character(
                    speakerID: speakerID,
                    xmlID: "character_\(characters.count + 1)",
                    label: resolvedLabel
                ))
        }
        return characters
    }

    private static func appendEvent(
        id: Int,
        text: String,
        timing: (startMs: Int, endMs: Int)?,
        characterID: String?,
        to lines: inout [String]
    ) {
        var attributes = ["xml:id=\"event_\(id)\""]
        if let timing {
            let startMs = max(0, timing.startMs)
            attributes.append("begin=\"\(clockTime(milliseconds: startMs))\"")
            attributes.append("end=\"\(clockTime(milliseconds: max(startMs, timing.endMs)))\"")
        }
        if let characterID {
            attributes.append("ttm:agent=\"\(characterID)\"")
        }
        attributes.append("daptm:represents=\"audio.dialogue\"")

        lines.append("    <div \(attributes.joined(separator: " "))>")
        lines.append("      <p>\(escapeText(text))</p>")
        lines.append("    </div>")
    }

    private static func documentLanguage(_ language: String?) -> String {
        SpeechEnginePreference.normalizeNemotronLanguage(language)
            ?? SpeechEnginePreference.normalizeKnownLanguage(language)
            ?? "und"
    }

    private static func clockTime(milliseconds: Int) -> String {
        let milliseconds = max(0, milliseconds)
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let seconds = (milliseconds % 60_000) / 1_000
        let millis = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
    }

    private static func escapeText(_ value: String) -> String {
        sanitizeXML10(value)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeText(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func sanitizeXML10(_ value: String) -> String {
        String(
            value.unicodeScalars.filter { scalar in
                switch scalar.value {
                case 0x9, 0xA, 0xD,
                    0x20...0xD7FF,
                    0xE000...0xFFFD,
                    0x10000...0x10FFFF:
                    true
                default:
                    false
                }
            })
    }
}
