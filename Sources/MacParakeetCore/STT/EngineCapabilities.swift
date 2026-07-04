import Foundation

public enum EngineVariantKey: Hashable, Sendable, CustomStringConvertible {
    case parakeet(ParakeetModelVariant)
    case nemotron(NemotronModelVariant)
    case whisper(WhisperModelVariant)
    case cohere

    public static var allCases: [EngineVariantKey] {
        ParakeetModelVariant.allCases.map(EngineVariantKey.parakeet)
            + NemotronModelVariant.allCases.map(EngineVariantKey.nemotron)
            + WhisperModelVariant.allCases.map(EngineVariantKey.whisper)
            + [.cohere]
    }

    public var engine: SpeechEnginePreference {
        switch self {
        case .parakeet:
            .parakeet
        case .nemotron:
            .nemotron
        case .whisper:
            .whisper
        case .cohere:
            .cohere
        }
    }

    public var variantID: String? {
        switch self {
        case .parakeet(let variant):
            variant.rawValue
        case .nemotron(let variant):
            variant.rawValue
        case .whisper(let variant):
            variant.rawValue
        case .cohere:
            nil
        }
    }

    public var description: String {
        if let variantID {
            "\(engine.rawValue):\(variantID)"
        } else {
            engine.rawValue
        }
    }
}

public struct EngineLanguagePolicy: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case automatic
        case fixed
        case selectable
        case unavailable
    }

    public let mode: Mode
    public let defaultLanguage: String?
    public let supportedLanguageCodes: [String]?

    public static func automatic(
        defaultLanguage: String? = nil,
        supportedLanguageCodes: [String]? = nil
    ) -> EngineLanguagePolicy {
        EngineLanguagePolicy(
            mode: .automatic,
            defaultLanguage: defaultLanguage,
            supportedLanguageCodes: supportedLanguageCodes
        )
    }

    public static func fixed(_ language: String) -> EngineLanguagePolicy {
        EngineLanguagePolicy(
            mode: .fixed,
            defaultLanguage: language,
            supportedLanguageCodes: [language]
        )
    }

    public static func selectable(
        defaultLanguage: String? = nil,
        supportedLanguageCodes: [String]? = nil
    ) -> EngineLanguagePolicy {
        EngineLanguagePolicy(
            mode: .selectable,
            defaultLanguage: defaultLanguage,
            supportedLanguageCodes: supportedLanguageCodes
        )
    }

    public static let unavailable = EngineLanguagePolicy(
        mode: .unavailable,
        defaultLanguage: nil,
        supportedLanguageCodes: nil
    )
}

public enum EngineTelemetryVariant: Equatable, Sendable {
    case none
    case fixed(String)
    case cohereComputePolicy

    public func value(defaults: UserDefaults = .standard) -> String? {
        switch self {
        case .none:
            nil
        case .fixed(let value):
            value
        case .cohereComputePolicy:
            CohereTranscribeEngine.ComputePolicy.current(defaults: defaults).rawValue
        }
    }
}

public struct EngineTelemetryIdentity: Equatable, Sendable {
    public let modelKind: TelemetryModelKind
    public let engineVariant: EngineTelemetryVariant
}

public struct EngineModelLifecycle: Equatable, Sendable {
    public let modelName: String
    public let variantID: String?
    public let selectableVariantIDs: [String]
    public let approximateDownloadSize: String?
    public let isUserDeletable: Bool
    public let minimumMemoryBytes: UInt64?
}

public struct EngineCapabilities: Equatable, Sendable {
    public let key: EngineVariantKey
    public let supportsNativeLiveDictation: Bool
    public let supportsTailPreview: Bool
    public let providesWordTimestamps: Bool
    public let supportedLanguages: EngineLanguagePolicy
    public let supportsCustomVocabulary: Bool
    public let modelLifecycle: EngineModelLifecycle
    public let telemetryIdentity: EngineTelemetryIdentity
}

public enum EngineCapabilityRegistry {
    public static let cohereMinimumMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024

    public static let all: [EngineCapabilities] =
        makeParakeetRows() + makeNemotronRows() + makeWhisperRows() + [cohereRow()]

    private static let table = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    public static func capabilitiesIfPresent(for key: EngineVariantKey) -> EngineCapabilities? {
        table[key]
    }

    public static func capabilities(for key: EngineVariantKey) -> EngineCapabilities {
        guard let capabilities = capabilitiesIfPresent(for: key) else {
            preconditionFailure("Missing EngineCapabilities row for \(key)")
        }
        return capabilities
    }

    private static func makeParakeetRows() -> [EngineCapabilities] {
        ParakeetModelVariant.allCases.map { variant in
            EngineCapabilities(
                key: .parakeet(variant),
                supportsNativeLiveDictation: variant.usesUnifiedEngine,
                supportsTailPreview: !variant.usesUnifiedEngine,
                providesWordTimestamps: !variant.usesUnifiedEngine,
                supportedLanguages: variant.isEnglishOnly ? .fixed("en") : .automatic(),
                supportsCustomVocabulary: false,
                modelLifecycle: EngineModelLifecycle(
                    modelName: variant.modelName,
                    variantID: variant.rawValue,
                    selectableVariantIDs: ParakeetModelVariant.allCases.map(\.rawValue),
                    approximateDownloadSize: variant.approximateDownloadSize,
                    isUserDeletable: true,
                    minimumMemoryBytes: nil
                ),
                telemetryIdentity: EngineTelemetryIdentity(
                    modelKind: .parakeetSTT,
                    engineVariant: .fixed(variant.rawValue)
                )
            )
        }
    }

    private static func makeNemotronRows() -> [EngineCapabilities] {
        NemotronModelVariant.allCases.map { variant in
            EngineCapabilities(
                key: .nemotron(variant),
                supportsNativeLiveDictation: true,
                supportsTailPreview: false,
                providesWordTimestamps: true,
                supportedLanguages: variant.isEnglishOnly ? .fixed("en") : .selectable(),
                supportsCustomVocabulary: false,
                modelLifecycle: EngineModelLifecycle(
                    modelName: variant.modelName,
                    variantID: variant.rawValue,
                    selectableVariantIDs: NemotronModelVariant.allCases.map(\.rawValue),
                    approximateDownloadSize: variant.approximateDownloadSize,
                    isUserDeletable: true,
                    minimumMemoryBytes: nil
                ),
                telemetryIdentity: EngineTelemetryIdentity(
                    modelKind: .nemotronSTT,
                    engineVariant: .fixed(variant.rawValue)
                )
            )
        }
    }

    private static func makeWhisperRows() -> [EngineCapabilities] {
        WhisperModelVariant.allCases.map { variant in
            EngineCapabilities(
                key: .whisper(variant),
                supportsNativeLiveDictation: false,
                supportsTailPreview: true,
                providesWordTimestamps: true,
                supportedLanguages: .selectable(
                    defaultLanguage: WhisperLanguageCatalog.autoCode,
                    supportedLanguageCodes: WhisperLanguageCatalog.all.map(\.code)
                ),
                supportsCustomVocabulary: false,
                modelLifecycle: EngineModelLifecycle(
                    modelName: variant.modelName,
                    variantID: variant.rawValue,
                    selectableVariantIDs: WhisperModelVariant.allCases.map(\.rawValue),
                    approximateDownloadSize: variant.approximateDownloadSize,
                    isUserDeletable: true,
                    minimumMemoryBytes: nil
                ),
                telemetryIdentity: EngineTelemetryIdentity(
                    modelKind: .whisperSTT,
                    engineVariant: .fixed(variant.rawValue)
                )
            )
        }
    }

    private static func cohereRow() -> EngineCapabilities {
        EngineCapabilities(
            key: .cohere,
            supportsNativeLiveDictation: false,
            supportsTailPreview: false,
            providesWordTimestamps: false,
            supportedLanguages: .selectable(
                defaultLanguage: "en",
                supportedLanguageCodes: CohereTranscribeEngine.supportedLanguages.map(\.code)
            ),
            supportsCustomVocabulary: false,
            modelLifecycle: EngineModelLifecycle(
                modelName: "Cohere Transcribe",
                variantID: nil,
                selectableVariantIDs: [],
                approximateDownloadSize: "~2.1 GB",
                isUserDeletable: true,
                minimumMemoryBytes: cohereMinimumMemoryBytes
            ),
            telemetryIdentity: EngineTelemetryIdentity(
                modelKind: .cohereSTT,
                engineVariant: .cohereComputePolicy
            )
        )
    }
}
