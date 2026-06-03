import Foundation

public struct AIFormatterPromptResolution: Sendable, Equatable {
    public let promptTemplate: String
    public let matchKind: AIFormatterProfileMatchKind
    public let profileID: UUID?
    public let profileName: String?
    public let profileOrigin: AIFormatterProfileOrigin?

    public init(
        promptTemplate: String,
        matchKind: AIFormatterProfileMatchKind,
        profileID: UUID? = nil,
        profileName: String? = nil,
        profileOrigin: AIFormatterProfileOrigin? = nil
    ) {
        self.promptTemplate = AIFormatter.normalizedPromptTemplate(promptTemplate)
        self.matchKind = matchKind
        self.profileID = profileID
        self.profileName = profileName
        self.profileOrigin = profileOrigin
    }

    public static func global(promptTemplate: String) -> AIFormatterPromptResolution {
        AIFormatterPromptResolution(
            promptTemplate: promptTemplate,
            matchKind: .global
        )
    }
}

public enum AIFormatterProfileMatcher {
    public static func match(
        profiles: [AIFormatterProfile],
        context: AppPromptContext?
    ) -> AIFormatterProfile? {
        guard let context else { return nil }
        let ordered = profiles
            .filter(\.isEnabled)
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                if lhs.name.localizedCaseInsensitiveCompare(rhs.name) != .orderedSame {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        if let bundleIdentifier = context.bundleIdentifier,
           let exactMatch = ordered.first(where: { profile in
               profile.targetKind == .bundle
                   && profile.bundleIdentifier == bundleIdentifier
           }) {
            return exactMatch
        }

        return ordered.first { profile in
            profile.targetKind == .category
                && profile.appCategory == context.category
        }
    }

    public static func resolve(
        profiles: [AIFormatterProfile],
        context: AppPromptContext?,
        globalPromptTemplate: String
    ) -> AIFormatterPromptResolution {
        guard let profile = match(profiles: profiles, context: context) else {
            return .global(promptTemplate: globalPromptTemplate)
        }

        return AIFormatterPromptResolution(
            promptTemplate: profile.promptTemplate,
            matchKind: profile.matchKind,
            profileID: profile.id,
            profileName: profile.name,
            profileOrigin: profile.origin
        )
    }
}

