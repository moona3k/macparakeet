import Foundation

/// Portable, versioned representation of a user's Ask-tab quick prompts.
///
/// Designed for backup, sharing, version-controlling in git, and programmatic
/// use by agents (OpenClaw, Hermes, …) reading/writing pills via the CLI.
/// Mirrors `VocabularyBundle`'s envelope shape so the two export formats stay
/// visually similar.
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
    public static let currentVersion = 1

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
        public let kind: QuickPrompt.Kind
        public let label: String
        public let prompt: String
        public let groupLabel: String?
        public let sortOrder: Int
        public let isVisible: Bool
        public let isBuiltIn: Bool

        public init(
            id: UUID,
            kind: QuickPrompt.Kind,
            label: String,
            prompt: String,
            groupLabel: String?,
            sortOrder: Int,
            isVisible: Bool,
            isBuiltIn: Bool
        ) {
            self.id = id
            self.kind = kind
            self.label = label
            self.prompt = prompt
            self.groupLabel = groupLabel
            self.sortOrder = sortOrder
            self.isVisible = isVisible
            self.isBuiltIn = isBuiltIn
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
    /// markers in import files.
    public static func materialize(
        _ entry: ExportedQuickPrompt,
        now: Date = Date()
    ) -> QuickPrompt {
        let canonicalBuiltIn = QuickPrompt.builtInPrompt(id: entry.id, now: now)
        let resolvedKind = canonicalBuiltIn?.kind ?? entry.kind
        let trustedBuiltIn = entry.isBuiltIn && canonicalBuiltIn != nil
        return QuickPrompt(
            id: entry.id,
            kind: resolvedKind,
            label: entry.label,
            prompt: entry.prompt,
            groupLabel: resolvedKind == .starter ? entry.groupLabel : nil,
            sortOrder: entry.sortOrder,
            isVisible: entry.isVisible,
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
            kind: p.kind,
            label: p.label,
            prompt: p.prompt,
            groupLabel: p.groupLabel,
            sortOrder: p.sortOrder,
            isVisible: p.isVisible,
            isBuiltIn: p.isBuiltIn
        )
    }
}
