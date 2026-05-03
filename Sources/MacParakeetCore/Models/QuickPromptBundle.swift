import Foundation

/// Portable, versioned representation of a user's Ask-tab quick prompts.
///
/// Designed for backup, sharing, version-controlling in git, and programmatic
/// use by agents (OpenClaw, Hermes, …) reading/writing pills via the CLI.
/// Mirrors `VocabularyBundle`'s envelope shape so the two export formats stay
/// visually similar.
///
/// ## Schema versions
///
/// - **v1** (2026-05-02): each prompt carries `kind: "starter" | "follow_up"`.
///   Shipped briefly with the original Ask quick-prompts feature.
/// - **v2** (current): each prompt carries `isPinned: Bool`. Pin replaces
///   the starter/follow-up distinction entirely. v1 files still decode —
///   `kind == "follow_up"` maps to `isPinned: true`.
///
/// ## Schema policy (CLI semver contract)
///
/// `schema` and `version` are stable within a CLI MAJOR. Adding new optional
/// fields to `ExportedQuickPrompt` is a MINOR change; renaming or removing
/// fields, changing semantics of existing fields, or restructuring the
/// top-level shape requires a MAJOR bump (and a new `version` value).
///
/// Decoders **must ignore unknown fields** (forward-compat). This is enforced
/// for free by `Codable`'s default behavior and exercised in
/// `QuickPromptBundleTests.testForwardCompatIgnoresUnknownFields`.
public struct QuickPromptBundle: Codable, Sendable, Equatable {
    public static let schemaIdentifier = "macparakeet.quick_prompts"
    public static let currentVersion = 2

    public let schema: String
    public let version: Int
    public let exportedAt: Date
    public let appVersion: String?
    public let prompts: [ExportedQuickPrompt]

    public init(
        exportedAt: Date,
        appVersion: String?,
        prompts: [ExportedQuickPrompt]
    ) {
        self.schema = Self.schemaIdentifier
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.prompts = prompts
    }

    public struct ExportedQuickPrompt: Codable, Sendable, Equatable {
        public let id: UUID
        public let label: String
        public let prompt: String
        public let groupLabel: String?
        public let sortOrder: Int
        public let isVisible: Bool
        public let isPinned: Bool
        public let isBuiltIn: Bool

        public init(
            id: UUID,
            label: String,
            prompt: String,
            groupLabel: String?,
            sortOrder: Int,
            isVisible: Bool,
            isPinned: Bool,
            isBuiltIn: Bool
        ) {
            self.id = id
            self.label = label
            self.prompt = prompt
            self.groupLabel = groupLabel
            self.sortOrder = sortOrder
            self.isVisible = isVisible
            self.isPinned = isPinned
            self.isBuiltIn = isBuiltIn
        }

        // MARK: v1 → v2 fallback decoding

        private enum CodingKeys: String, CodingKey {
            case id, label, prompt, groupLabel, sortOrder, isVisible, isPinned, isBuiltIn, kind
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(UUID.self, forKey: .id)
            self.label = try container.decode(String.self, forKey: .label)
            self.prompt = try container.decode(String.self, forKey: .prompt)
            self.groupLabel = try container.decodeIfPresent(String.self, forKey: .groupLabel)
            self.sortOrder = try container.decode(Int.self, forKey: .sortOrder)
            self.isVisible = try container.decode(Bool.self, forKey: .isVisible)
            self.isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
            // v2: read isPinned directly. v1 fallback: derive from kind.
            if let pinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) {
                self.isPinned = pinned
            } else if let legacyKind = try container.decodeIfPresent(String.self, forKey: .kind) {
                self.isPinned = legacyKind == "follow_up"
            } else {
                self.isPinned = false
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(label, forKey: .label)
            try container.encode(prompt, forKey: .prompt)
            try container.encodeIfPresent(groupLabel, forKey: .groupLabel)
            try container.encode(sortOrder, forKey: .sortOrder)
            try container.encode(isVisible, forKey: .isVisible)
            try container.encode(isPinned, forKey: .isPinned)
            try container.encode(isBuiltIn, forKey: .isBuiltIn)
            // Note: v2 omits the legacy `kind` field. v1 readers that require
            // `kind` will fail; v1 readers that don't (the previous codebase)
            // will continue working since they tolerated unknown fields.
        }
    }
}

// MARK: - Schema validation

public enum QuickPromptBundleError: Error, LocalizedError, Equatable {
    case wrongSchema(found: String)
    case unsupportedVersion(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .wrongSchema(let found):
            return "Not a MacParakeet quick-prompts file (schema='\(found)', expected '\(QuickPromptBundle.schemaIdentifier)')."
        case .unsupportedVersion(let found, let supported):
            return "Unsupported quick-prompts schema version \(found); this build supports up to \(supported)."
        }
    }
}

extension QuickPromptBundle {
    /// Conversion from domain model → wire format.
    public init(
        from prompts: [QuickPrompt],
        exportedAt: Date = Date(),
        appVersion: String? = nil
    ) {
        self.init(
            exportedAt: exportedAt,
            appVersion: appVersion,
            prompts: prompts.map(ExportedQuickPrompt.init)
        )
    }

    /// Validate envelope fields. Throws on schema or version mismatch.
    /// Unknown fields and additive optional fields are tolerated by `Codable`.
    public func validate() throws {
        guard schema == Self.schemaIdentifier else {
            throw QuickPromptBundleError.wrongSchema(found: schema)
        }
        guard version <= Self.currentVersion else {
            throw QuickPromptBundleError.unsupportedVersion(
                found: version,
                supported: Self.currentVersion
            )
        }
    }

    /// Conversion from wire entry → domain model. Coerces `isBuiltIn` to `false`
    /// unless the id matches a known seed, defending against forged "built-in"
    /// markers in import files. Pin state remains ordinary user data, even for
    /// built-ins; repository write normalization only clears it when a row is
    /// hidden, because hidden+pinned is not a valid state.
    public static func materialize(
        _ entry: ExportedQuickPrompt,
        now: Date = Date()
    ) -> QuickPrompt {
        let canonical = QuickPrompt.builtInPrompt(id: entry.id, now: now)
        let trustedBuiltIn = entry.isBuiltIn && canonical != nil
        return QuickPrompt(
            id: entry.id,
            label: entry.label,
            prompt: entry.prompt,
            groupLabel: entry.groupLabel,
            sortOrder: entry.sortOrder,
            isVisible: entry.isVisible,
            isPinned: entry.isPinned,
            isBuiltIn: trustedBuiltIn,
            createdAt: now,
            updatedAt: now
        )
    }
}

extension QuickPromptBundle.ExportedQuickPrompt {
    init(_ p: QuickPrompt) {
        self.init(
            id: p.id,
            label: p.label,
            prompt: p.prompt,
            groupLabel: p.groupLabel,
            sortOrder: p.sortOrder,
            isVisible: p.isVisible,
            isPinned: p.isPinned,
            isBuiltIn: p.isBuiltIn
        )
    }
}
