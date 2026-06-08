import Foundation
import GRDB

public struct Dictation: Codable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var durationMs: Int
    public var rawTranscript: String
    public var cleanTranscript: String?
    public var audioPath: String?
    public var pastedToApp: String?
    public var processingMode: ProcessingMode
    public var status: DictationStatus
    public var errorMessage: String?
    public var updatedAt: Date
    public var hidden: Bool
    public var wordCount: Int
    /// STT engine that produced this dictation (`"parakeet"` / `"nemotron"` /
    /// `"whisper"`).
    /// `nil` for rows created before the v0.8 engine-attribution migration.
    public var engine: String?
    /// Engine-specific model variant id (e.g. `v3`, `multilingual-1120ms`,
    /// or the Whisper model id). `nil` for legacy rows.
    public var engineVariant: String?
    /// Normalized detected STT language code (for example `"en"`, `"ko"`,
    /// `"ja"`, or `"zh"`). `nil` when unknown or for legacy rows.
    public var language: String?
    /// "Undo AI edit" toggle. When `true`, surfaces (`displayText`, history
    /// copy, recent-paste menu, export) show `rawTranscript` even when a
    /// `cleanTranscript` exists. Reversible — flipping back to `false`
    /// restores the AI-edited text without recomputing it. Defaults to
    /// `false` for new rows and for legacy rows backfilled by the
    /// `v0.12-dictation-display-raw` migration.
    public var displayRawTranscript: Bool
    /// Local-only provenance for the AI Formatter routing decision used on
    /// this dictation. Global formatter runs store `.global` with no profile
    /// id/name; nil means the row predates routing metadata or AI Formatter
    /// was off.
    public var aiFormatterProfileID: UUID?
    public var aiFormatterProfileName: String?
    public var aiFormatterProfileMatchKind: AIFormatterProfileMatchKind?

    public enum ProcessingMode: String, Codable, Sendable {
        case raw
        case clean

        /// Override default RawRepresentable init to handle deprecated mode values.
        /// Without this, `ProcessingMode(rawValue: "formal")` returns nil and callers
        /// fall back to `.raw`, silently disabling processing for upgraded users.
        public init?(rawValue: String) {
            switch rawValue {
            case "raw": self = .raw
            case "clean", "formal", "email", "code": self = .clean
            default: return nil
            }
        }

        public init(from decoder: Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: rawValue) ?? .raw
        }
    }

    public enum DictationStatus: String, Codable, Sendable {
        case recording
        case processing
        case completed
        case error
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        durationMs: Int,
        rawTranscript: String,
        cleanTranscript: String? = nil,
        audioPath: String? = nil,
        pastedToApp: String? = nil,
        processingMode: ProcessingMode = .raw,
        status: DictationStatus = .completed,
        errorMessage: String? = nil,
        updatedAt: Date = Date(),
        hidden: Bool = false,
        wordCount: Int = 0,
        engine: String? = nil,
        engineVariant: String? = nil,
        language: String? = nil,
        displayRawTranscript: Bool = false,
        aiFormatterProfileID: UUID? = nil,
        aiFormatterProfileName: String? = nil,
        aiFormatterProfileMatchKind: AIFormatterProfileMatchKind? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.rawTranscript = rawTranscript
        self.cleanTranscript = cleanTranscript
        self.audioPath = audioPath
        self.pastedToApp = pastedToApp
        self.processingMode = processingMode
        self.status = status
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
        self.hidden = hidden
        self.wordCount = wordCount
        self.engine = engine
        self.engineVariant = engineVariant
        self.language = language
        self.displayRawTranscript = displayRawTranscript
        self.aiFormatterProfileID = aiFormatterProfileID
        self.aiFormatterProfileName = aiFormatterProfileName
        self.aiFormatterProfileMatchKind = aiFormatterProfileMatchKind
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, durationMs, rawTranscript, cleanTranscript
        case audioPath, pastedToApp, processingMode, status, errorMessage
        case updatedAt, hidden, wordCount, engine, engineVariant, language
        case displayRawTranscript
        case aiFormatterProfileID, aiFormatterProfileName, aiFormatterProfileMatchKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        durationMs = try container.decode(Int.self, forKey: .durationMs)
        rawTranscript = try container.decode(String.self, forKey: .rawTranscript)
        cleanTranscript = try container.decodeIfPresent(String.self, forKey: .cleanTranscript)
        audioPath = try container.decodeIfPresent(String.self, forKey: .audioPath)
        pastedToApp = try container.decodeIfPresent(String.self, forKey: .pastedToApp)
        processingMode = try container.decode(ProcessingMode.self, forKey: .processingMode)
        status = try container.decode(DictationStatus.self, forKey: .status)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        hidden = try container.decode(Bool.self, forKey: .hidden)
        wordCount = try container.decode(Int.self, forKey: .wordCount)
        engine = try container.decodeIfPresent(String.self, forKey: .engine)
        engineVariant = try container.decodeIfPresent(String.self, forKey: .engineVariant)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        // Decode-if-present so legacy serialized snapshots (in-flight Codable
        // payloads, tests) round-trip without explicitly setting the field.
        displayRawTranscript = try container.decodeIfPresent(Bool.self, forKey: .displayRawTranscript) ?? false
        aiFormatterProfileID = try container.decodeIfPresent(UUID.self, forKey: .aiFormatterProfileID)
        aiFormatterProfileName = try container.decodeIfPresent(String.self, forKey: .aiFormatterProfileName)
        if let rawMatchKind = try container.decodeIfPresent(String.self, forKey: .aiFormatterProfileMatchKind) {
            aiFormatterProfileMatchKind = AIFormatterProfileMatchKind(rawValue: rawMatchKind)
        } else {
            aiFormatterProfileMatchKind = nil
        }
    }
}

// MARK: - Display helpers

public extension Dictation {
    /// Text shown in history, copied to the clipboard from history, pasted by
    /// the menu-bar "recent dictations" submenu, and exported. Honors the
    /// `displayRawTranscript` override added by the "Undo AI edit" feature.
    ///
    /// When `displayRawTranscript == true`, callers see `rawTranscript` even
    /// if a `cleanTranscript` exists — the cleaned version is preserved on the
    /// row so the override is reversible.
    var displayText: String {
        if displayRawTranscript {
            return rawTranscript
        }
        return cleanTranscript ?? rawTranscript
    }

    /// True when the dictation has an AI-edited / deterministically-cleaned
    /// version that differs from the raw STT output. Drives whether the
    /// "Undo AI edit" affordance is offered on a row.
    ///
    /// `processingMode` isn't checked here — what matters is "is there a
    /// distinct cleaned version we could revert from?" not "what mode was
    /// selected at capture time."
    var hasAIEdit: Bool {
        guard let clean = cleanTranscript else { return false }
        return clean != rawTranscript
    }
}

public extension Dictation.ProcessingMode {
    var usesDeterministicPipeline: Bool {
        self != .raw
    }

    var displayName: String {
        switch self {
        case .raw:
            return "Raw"
        case .clean:
            return "Clean"
        }
    }

}

extension Dictation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dictations"

    public enum Columns: String, ColumnExpression {
        case id, createdAt, durationMs, rawTranscript, cleanTranscript
        case audioPath, pastedToApp, processingMode, status, errorMessage, updatedAt
        case hidden, wordCount, engine, engineVariant, language
        case displayRawTranscript
        case aiFormatterProfileID, aiFormatterProfileName, aiFormatterProfileMatchKind
    }
}
