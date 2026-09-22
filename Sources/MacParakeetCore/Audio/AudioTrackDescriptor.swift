import Foundation

/// One audio stream embedded in a local media file.
///
/// `ordinal` is zero-based among audio streams only and is the value used by
/// FFmpeg's `0:a:N` selector. `streamIndex` is the container-wide stream index
/// shown by FFmpeg and is informational; callers must not use it for mapping.
public struct AudioTrackDescriptor: Identifiable, Sendable, Equatable {
    public let ordinal: Int
    public let streamIndex: Int
    public let languageCode: String?
    public let isDefault: Bool

    public var id: Int { ordinal }

    public init(
        ordinal: Int,
        streamIndex: Int,
        languageCode: String? = nil,
        isDefault: Bool = false
    ) {
        self.ordinal = ordinal
        self.streamIndex = streamIndex
        self.languageCode = languageCode
        self.isDefault = isDefault
    }

    public var displayName: String {
        var label = "Track \(ordinal + 1)"
        if let languageName {
            label += " — \(languageName)"
        }
        if isDefault {
            label += " (Default)"
        }
        return label
    }

    private var languageName: String? {
        guard let code = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
            !code.isEmpty
        else {
            return nil
        }
        return Locale(identifier: "en").localizedString(forLanguageCode: code)
            ?? code.uppercased()
    }
}
