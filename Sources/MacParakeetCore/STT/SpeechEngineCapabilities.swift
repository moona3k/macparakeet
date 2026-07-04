import Foundation

public enum SpeechEngineVariantKey: Hashable, Sendable, CustomStringConvertible {
    case parakeet(ParakeetModelVariant)
    case nemotron(NemotronModelVariant)
    case whisper(WhisperModelVariant)
    case cohere

    public static var allCases: [SpeechEngineVariantKey] {
        ParakeetModelVariant.allCases.map(SpeechEngineVariantKey.parakeet)
            + NemotronModelVariant.allCases.map(SpeechEngineVariantKey.nemotron)
            + WhisperModelVariant.allCases.map(SpeechEngineVariantKey.whisper)
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

public struct SpeechEngineLanguagePolicy: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case automatic
        case fixed
        case selectable
    }

    public let mode: Mode
    public let defaultLanguage: String?
    public let supportedLanguageCodes: [String]?

    public static func automatic(
        defaultLanguage: String? = nil,
        supportedLanguageCodes: [String]? = nil
    ) -> SpeechEngineLanguagePolicy {
        SpeechEngineLanguagePolicy(
            mode: .automatic,
            defaultLanguage: defaultLanguage,
            supportedLanguageCodes: supportedLanguageCodes
        )
    }

    public static func fixed(_ language: String) -> SpeechEngineLanguagePolicy {
        SpeechEngineLanguagePolicy(
            mode: .fixed,
            defaultLanguage: language,
            supportedLanguageCodes: [language]
        )
    }

    public static func selectable(
        defaultLanguage: String? = nil,
        supportedLanguageCodes: [String]? = nil
    ) -> SpeechEngineLanguagePolicy {
        SpeechEngineLanguagePolicy(
            mode: .selectable,
            defaultLanguage: defaultLanguage,
            supportedLanguageCodes: supportedLanguageCodes
        )
    }
}

public enum SpeechEngineTelemetryVariant: Equatable, Sendable {
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

public struct SpeechEngineTelemetryIdentity: Equatable, Sendable {
    public let modelKind: TelemetryModelKind
    public let engineVariant: SpeechEngineTelemetryVariant
}

public struct SpeechEngineModelLifecycle: Equatable, Sendable {
    public let modelName: String
    public let variantID: String?
    public let selectableVariantIDs: [String]
    public let approximateDownloadSize: String?
    public let isUserDeletable: Bool
    public let minimumMemoryBytes: UInt64?
}

public struct SpeechEngineCapabilities: Equatable, Sendable {
    public let key: SpeechEngineVariantKey
    public let supportsNativeLiveDictation: Bool
    public let supportsTailPreview: Bool
    public let providesWordTimestamps: Bool
    public let supportedLanguages: SpeechEngineLanguagePolicy
    public let supportsCustomVocabulary: Bool
    public let modelLifecycle: SpeechEngineModelLifecycle
    public let telemetryIdentity: SpeechEngineTelemetryIdentity
}

public enum SpeechEngineCapabilityRegistry {
    public static let cohereMinimumMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024

    public static let all: [SpeechEngineCapabilities] =
        makeParakeetRows() + makeNemotronRows() + makeWhisperRows() + [cohereRow()]

    private static let table = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    public static func capabilitiesIfPresent(for key: SpeechEngineVariantKey) -> SpeechEngineCapabilities? {
        table[key]
    }

    public static func capabilities(for key: SpeechEngineVariantKey) -> SpeechEngineCapabilities {
        guard let capabilities = capabilitiesIfPresent(for: key) else {
            preconditionFailure("Missing SpeechEngineCapabilities row for \(key)")
        }
        return capabilities
    }

    public static func variantKey(
        for engine: SpeechEnginePreference,
        parakeetModelVariant: ParakeetModelVariant = SpeechEnginePreference.defaultParakeetModelVariant,
        nemotronModelVariant: NemotronModelVariant = SpeechEnginePreference.defaultNemotronModelVariant,
        whisperModelVariant: String = SpeechEnginePreference.defaultWhisperModelVariant
    ) -> SpeechEngineVariantKey? {
        switch engine {
        case .parakeet:
            .parakeet(parakeetModelVariant)
        case .nemotron:
            .nemotron(nemotronModelVariant)
        case .whisper:
            WhisperModelVariant.normalize(whisperModelVariant).map(SpeechEngineVariantKey.whisper)
        case .cohere:
            .cohere
        }
    }

    public static func capabilities(
        for engine: SpeechEnginePreference,
        parakeetModelVariant: ParakeetModelVariant = SpeechEnginePreference.defaultParakeetModelVariant,
        nemotronModelVariant: NemotronModelVariant = SpeechEnginePreference.defaultNemotronModelVariant,
        whisperModelVariant: String = SpeechEnginePreference.defaultWhisperModelVariant
    ) -> SpeechEngineCapabilities? {
        guard let key = variantKey(
            for: engine,
            parakeetModelVariant: parakeetModelVariant,
            nemotronModelVariant: nemotronModelVariant,
            whisperModelVariant: whisperModelVariant
        ) else {
            return nil
        }
        return capabilities(for: key)
    }

    private static func makeParakeetRows() -> [SpeechEngineCapabilities] {
        ParakeetModelVariant.allCases.map { variant in
            SpeechEngineCapabilities(
                key: .parakeet(variant),
                supportsNativeLiveDictation: variant.usesUnifiedEngine,
                supportsTailPreview: !variant.usesUnifiedEngine,
                providesWordTimestamps: !variant.usesUnifiedEngine,
                supportedLanguages: variant.isEnglishOnly ? .fixed("en") : .automatic(),
                supportsCustomVocabulary: false,
                modelLifecycle: SpeechEngineModelLifecycle(
                    modelName: variant.modelName,
                    variantID: variant.rawValue,
                    selectableVariantIDs: ParakeetModelVariant.allCases.map(\.rawValue),
                    approximateDownloadSize: variant.approximateDownloadSize,
                    isUserDeletable: true,
                    minimumMemoryBytes: nil
                ),
                telemetryIdentity: SpeechEngineTelemetryIdentity(
                    modelKind: .parakeetSTT,
                    engineVariant: .fixed(variant.rawValue)
                )
            )
        }
    }

    private static func makeNemotronRows() -> [SpeechEngineCapabilities] {
        NemotronModelVariant.allCases.map { variant in
            SpeechEngineCapabilities(
                key: .nemotron(variant),
                supportsNativeLiveDictation: true,
                supportsTailPreview: false,
                providesWordTimestamps: true,
                supportedLanguages: variant.isEnglishOnly ? .fixed("en") : .selectable(),
                supportsCustomVocabulary: false,
                modelLifecycle: SpeechEngineModelLifecycle(
                    modelName: variant.modelName,
                    variantID: variant.rawValue,
                    selectableVariantIDs: NemotronModelVariant.allCases.map(\.rawValue),
                    approximateDownloadSize: variant.approximateDownloadSize,
                    isUserDeletable: true,
                    minimumMemoryBytes: nil
                ),
                telemetryIdentity: SpeechEngineTelemetryIdentity(
                    modelKind: .nemotronSTT,
                    engineVariant: .fixed(variant.rawValue)
                )
            )
        }
    }

    private static func makeWhisperRows() -> [SpeechEngineCapabilities] {
        WhisperModelVariant.allCases.map { variant in
            SpeechEngineCapabilities(
                key: .whisper(variant),
                supportsNativeLiveDictation: false,
                supportsTailPreview: true,
                providesWordTimestamps: true,
                supportedLanguages: .selectable(
                    defaultLanguage: WhisperLanguageCatalog.autoCode,
                    supportedLanguageCodes: [WhisperLanguageCatalog.autoCode]
                        + WhisperLanguageCatalog.all.map(\.code)
                ),
                supportsCustomVocabulary: false,
                modelLifecycle: SpeechEngineModelLifecycle(
                    modelName: variant.modelName,
                    variantID: variant.rawValue,
                    selectableVariantIDs: WhisperModelVariant.allCases.map(\.rawValue),
                    approximateDownloadSize: variant.approximateDownloadSize,
                    isUserDeletable: true,
                    minimumMemoryBytes: nil
                ),
                telemetryIdentity: SpeechEngineTelemetryIdentity(
                    modelKind: .whisperSTT,
                    engineVariant: .fixed(variant.rawValue)
                )
            )
        }
    }

    private static func cohereRow() -> SpeechEngineCapabilities {
        SpeechEngineCapabilities(
            key: .cohere,
            supportsNativeLiveDictation: false,
            supportsTailPreview: false,
            providesWordTimestamps: false,
            supportedLanguages: .selectable(
                defaultLanguage: "en",
                supportedLanguageCodes: CohereTranscribeEngine.supportedLanguages.map(\.code)
            ),
            supportsCustomVocabulary: false,
            modelLifecycle: SpeechEngineModelLifecycle(
                modelName: "Cohere Transcribe",
                variantID: nil,
                selectableVariantIDs: [],
                approximateDownloadSize: "~2.1 GB",
                isUserDeletable: true,
                minimumMemoryBytes: cohereMinimumMemoryBytes
            ),
            telemetryIdentity: SpeechEngineTelemetryIdentity(
                modelKind: .cohereSTT,
                engineVariant: .cohereComputePolicy
            )
        )
    }
}
