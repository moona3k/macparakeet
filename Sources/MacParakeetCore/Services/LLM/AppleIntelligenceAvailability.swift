import Foundation

/// Runtime eligibility for Apple's on-device Foundation Models.
///
/// Distinct from "the user selected this provider." A saved config can exist
/// while the OS later reports not-enabled or model-not-ready; callers re-check
/// this on every request.
public enum AppleIntelligenceAvailability: String, Sendable, Equatable {
    /// Compiled without FoundationModels, or running below macOS 26.
    case unsupported
    /// Apple reports the Mac cannot run Apple Intelligence.
    case deviceNotEligible
    /// User has not enabled Apple Intelligence in System Settings.
    case appleIntelligenceNotEnabled
    /// The OS model is still downloading or preparing.
    case modelNotReady
    /// Ready to generate, including for this Mac's current language.
    case available
    /// Apple Intelligence is on, but the current app locale is outside the
    /// on-device language set. English prompts can still run.
    case localeLimited

    public var canGenerate: Bool {
        switch self {
        case .available, .localeLimited:
            return true
        case .unsupported, .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady:
            return false
        }
    }

    public var isUserSelectable: Bool {
        switch self {
        case .unsupported, .deviceNotEligible:
            return false
        case .appleIntelligenceNotEnabled, .modelNotReady, .available, .localeLimited:
            return true
        }
    }

    public var userMessage: String {
        switch self {
        case .unsupported:
            return "Apple Intelligence requires macOS 26 or later."
        case .deviceNotEligible:
            return "Apple Intelligence is not available on this Mac."
        case .appleIntelligenceNotEnabled:
            return "Turn it on in System Settings to use it on this Mac."
        case .modelNotReady:
            return "Apple Intelligence is downloading. Check again in a few minutes."
        case .available:
            return "Ready on this Mac."
        case .localeLimited:
            return
                "Apple Intelligence is on. English prompts can run; this Mac's language is outside the on-device set, so other languages may be declined."
        }
    }

    public var settingsURL: URL? {
        switch self {
        case .appleIntelligenceNotEnabled:
            return URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
        default:
            return nil
        }
    }

    public static func current() -> AppleIntelligenceAvailability {
        AppleIntelligenceRuntime.currentAvailability()
    }
}

enum AppleIntelligenceRuntime {
    static func makeGenerator() -> any AppleIntelligenceGenerating {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return FoundationModelsAppleIntelligenceGenerator()
        }
        #endif
        return UnavailableAppleIntelligenceGenerator()
    }

    static func currentAvailability() -> AppleIntelligenceAvailability {
        makeGenerator().currentAvailability()
    }
}
