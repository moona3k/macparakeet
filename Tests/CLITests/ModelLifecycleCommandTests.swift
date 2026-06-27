import ArgumentParser
import CoreAudio
import XCTest
@testable import MacParakeetCore
@testable import CLI

final class ModelLifecycleCommandTests: XCTestCase {
    func testValidatedAttemptsRejectsZero() {
        XCTAssertThrowsError(try validatedAttempts(0)) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testValidatedAttemptsAcceptsPositiveValues() throws {
        XCTAssertEqual(try validatedAttempts(1), 1)
        XCTAssertEqual(try validatedAttempts(5), 5)
    }

    func testHealthParsesRepairFlags() throws {
        let command = try HealthCommand.parse(["--repair-models", "--repair-attempts", "6", "--repair-binaries"])
        XCTAssertTrue(command.repairModels)
        XCTAssertEqual(command.repairAttempts, 6)
        XCTAssertTrue(command.repairBinaries)
    }

    func testResolveWhisperDownloadModelRequiresWhisperPrefix() throws {
        XCTAssertEqual(
            try resolveWhisperDownloadModel("whisper-large-v3-v20240930-turbo-632MB"),
            "large-v3-v20240930_turbo_632MB"
        )

        XCTAssertThrowsError(try resolveWhisperDownloadModel("parakeet-v3")) { error in
            XCTAssertTrue(error is ValidationError)
            XCTAssertTrue(String(describing: error).contains("parakeet-unified"))
            XCTAssertTrue(String(describing: error).contains("cohere-transcribe"))
        }
    }

    func testLoadSelectableSpeechModelsReflectsSharedDefaults() throws {
        let suiteName = "com.macparakeet.tests.cli.models.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SpeechEnginePreference.whisper.save(to: defaults)
        SpeechEnginePreference.saveWhisperDefaultLanguage("KO_kr", defaults: defaults)
        SpeechEnginePreference.saveWhisperModelVariant(
            "large-v3-v20240930_turbo_632MB",
            defaults: defaults
        )

        let models = loadSelectableSpeechModels(
            defaults: defaults,
            isParakeetModelCached: { $0 == .v3 },
            isNemotronModelDownloaded: { $0 == .multilingual1120 },
            isWhisperModelDownloaded: { $0 == "large-v3-v20240930_turbo_632MB" },
            isCohereModelDownloaded: { false }
        )

        XCTAssertEqual(models.count, 7)
        XCTAssertEqual(models[0], SelectableSpeechModel(
            id: "parakeet-v3",
            name: "Parakeet TDT 0.6B v3 (Multilingual)",
            engine: "parakeet",
            variant: "v3",
            size: "~465 MB",
            installed: true,
            selected: false,
            language: nil
        ))
        XCTAssertEqual(models[1], SelectableSpeechModel(
            id: "parakeet-v2",
            name: "Parakeet TDT 0.6B v2 (English only)",
            engine: "parakeet",
            variant: "v2",
            size: "~465 MB",
            installed: false,
            selected: false,
            language: "en"
        ))
        XCTAssertEqual(models[2], SelectableSpeechModel(
            id: "parakeet-unified",
            name: "Parakeet Unified 0.6B (English (Unified))",
            engine: "parakeet",
            variant: "unified",
            size: "~565 MB",
            installed: false,
            selected: false,
            language: "en"
        ))
        XCTAssertEqual(models[3], SelectableSpeechModel(
            id: "nemotron-multilingual-1120ms",
            name: "Nemotron 3.5 ASR Streaming 0.6B (Multilingual Beta)",
            engine: "nemotron",
            variant: "multilingual-1120ms",
            size: "~1.5 GB",
            installed: true,
            selected: false,
            language: "auto"
        ))
        XCTAssertEqual(models[4], SelectableSpeechModel(
            id: "nemotron-english-1120ms",
            name: "Nemotron Speech Streaming EN 0.6B (English Beta)",
            engine: "nemotron",
            variant: "english-1120ms",
            size: "~600 MB",
            installed: false,
            selected: false,
            language: "en"
        ))
        XCTAssertEqual(models[5], SelectableSpeechModel(
            id: "cohere-transcribe",
            name: "Cohere Transcribe",
            engine: "cohere",
            variant: nil,
            size: "~2.1 GB",
            installed: false,
            selected: false,
            language: "en"
        ))
        XCTAssertEqual(models[6], SelectableSpeechModel(
            id: "whisper-large-v3-v20240930-turbo-632MB",
            name: "Whisper Large v3 Turbo",
            engine: "whisper",
            variant: "large-v3-v20240930_turbo_632MB",
            size: "632 MB",
            installed: true,
            selected: true,
            language: "ko"
        ))
    }

    func testLoadSelectableSpeechModelsMarksSelectedParakeetVariant() throws {
        let suiteName = "com.macparakeet.tests.cli.model-list-parakeet.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SpeechEnginePreference.parakeet.save(to: defaults)
        SpeechEnginePreference.saveParakeetModelVariant(.v2, defaults: defaults)

        let models = loadSelectableSpeechModels(
            defaults: defaults,
            isParakeetModelCached: { _ in true },
            isNemotronModelDownloaded: { _ in false },
            isWhisperModelDownloaded: { _ in false },
            isCohereModelDownloaded: { false }
        )

        let v3 = try XCTUnwrap(models.first { $0.id == "parakeet-v3" })
        let v2 = try XCTUnwrap(models.first { $0.id == "parakeet-v2" })
        XCTAssertFalse(v3.selected, "Multilingual build should not be marked selected")
        XCTAssertTrue(v2.selected, "English-only build is the persisted Parakeet variant")
    }

    func testLoadSelectableSpeechModelsMarksSelectedNemotronVariant() throws {
        let suiteName = "com.macparakeet.tests.cli.model-list-nemotron.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SpeechEnginePreference.nemotron.save(to: defaults)
        SpeechEnginePreference.saveNemotronModelVariant(.english1120, defaults: defaults)

        let models = loadSelectableSpeechModels(
            defaults: defaults,
            isParakeetModelCached: { _ in false },
            isNemotronModelDownloaded: { _ in true },
            isWhisperModelDownloaded: { _ in false },
            isCohereModelDownloaded: { false }
        )

        let multilingual = try XCTUnwrap(models.first { $0.id == "nemotron-multilingual-1120ms" })
        let english = try XCTUnwrap(models.first { $0.id == "nemotron-english-1120ms" })
        XCTAssertFalse(multilingual.selected, "Multilingual build should not be marked selected")
        XCTAssertTrue(english.selected, "English-only build is the persisted Nemotron variant")
        XCTAssertEqual(english.language, "en", "English build ignores the nemotron-language hint")
    }

    func testResolveSelectableSpeechModelAcceptsEngineAndWhisperIDs() throws {
        let suiteName = "com.macparakeet.tests.cli.model-select.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        SpeechEnginePreference.saveWhisperModelVariant(
            "large-v3-v20240930_turbo_632MB",
            defaults: defaults
        )

        XCTAssertEqual(
            try resolveSelectableSpeechModel("parakeet", defaults: defaults),
            SelectableSpeechModelSelection(engine: .parakeet, whisperVariant: nil, parakeetVariant: .v3)
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("parakeet-v2", defaults: defaults),
            SelectableSpeechModelSelection(engine: .parakeet, whisperVariant: nil, parakeetVariant: .v2)
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("parakeet:v3", defaults: defaults),
            SelectableSpeechModelSelection(engine: .parakeet, whisperVariant: nil, parakeetVariant: .v3)
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("parakeet-english", defaults: defaults),
            SelectableSpeechModelSelection(engine: .parakeet, whisperVariant: nil, parakeetVariant: .v2)
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("nemotron", defaults: defaults),
            SelectableSpeechModelSelection(
                engine: .nemotron,
                whisperVariant: nil,
                nemotronVariant: .multilingual1120
            )
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("nemotron-multilingual-1120ms", defaults: defaults),
            SelectableSpeechModelSelection(
                engine: .nemotron,
                whisperVariant: nil,
                nemotronVariant: .multilingual1120
            )
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("nemotron:beta", defaults: defaults),
            SelectableSpeechModelSelection(
                engine: .nemotron,
                whisperVariant: nil,
                nemotronVariant: .multilingual1120
            )
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("nemotron-english-1120ms", defaults: defaults),
            SelectableSpeechModelSelection(
                engine: .nemotron,
                whisperVariant: nil,
                nemotronVariant: .english1120
            )
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("nemotron:en", defaults: defaults),
            SelectableSpeechModelSelection(
                engine: .nemotron,
                whisperVariant: nil,
                nemotronVariant: .english1120
            )
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("whisper", defaults: defaults),
            SelectableSpeechModelSelection(
                engine: .whisper,
                whisperVariant: "large-v3-v20240930_turbo_632MB"
            )
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("whisper-large-v3-v20240930-turbo-632MB", defaults: defaults),
            SelectableSpeechModelSelection(
                engine: .whisper,
                whisperVariant: "large-v3-v20240930_turbo_632MB"
            )
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("Whisper-large-v3-v20240930-turbo-632MB", defaults: defaults),
            SelectableSpeechModelSelection(
                engine: .whisper,
                whisperVariant: "large-v3-v20240930_turbo_632MB"
            )
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("whisper:large-v3-v20240930_turbo_632MB", defaults: defaults),
            SelectableSpeechModelSelection(
                engine: .whisper,
                whisperVariant: "large-v3-v20240930_turbo_632MB"
            )
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("cohere", defaults: defaults),
            SelectableSpeechModelSelection(engine: .cohere, whisperVariant: nil)
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("cohere-transcribe", defaults: defaults),
            SelectableSpeechModelSelection(engine: .cohere, whisperVariant: nil)
        )
        XCTAssertEqual(
            try resolveSelectableSpeechModel("cohere-transcribe-03-2026", defaults: defaults),
            SelectableSpeechModelSelection(engine: .cohere, whisperVariant: nil)
        )
        // Bare "nemotron" follows the persisted variant; `models select` then
        // re-persists both the engine and that variant.
        SpeechEnginePreference.saveNemotronModelVariant(.english1120, defaults: defaults)
        XCTAssertEqual(
            try resolveSelectableSpeechModel("nemotron", defaults: defaults),
            SelectableSpeechModelSelection(
                engine: .nemotron,
                whisperVariant: nil,
                nemotronVariant: .english1120
            )
        )
    }

    func testParakeetDownloadVariantRecognizesParakeetIDs() throws {
        let suiteName = "com.macparakeet.tests.cli.parakeet-download.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(parakeetDownloadVariant(from: "parakeet-v2", defaults: defaults), .v2)
        XCTAssertEqual(parakeetDownloadVariant(from: "parakeet:v3", defaults: defaults), .v3)
        XCTAssertEqual(parakeetDownloadVariant(from: "parakeet-english", defaults: defaults), .v2)
        // Underscore spellings normalize to hyphens, matching `config set`.
        XCTAssertEqual(parakeetDownloadVariant(from: "parakeet_v2", defaults: defaults), .v2)
        XCTAssertEqual(parakeetDownloadVariant(from: "parakeet_english", defaults: defaults), .v2)
        // Unified (issue #520) resolves from its id and aliases.
        XCTAssertEqual(parakeetDownloadVariant(from: "parakeet-unified", defaults: defaults), .unified)
        XCTAssertEqual(parakeetDownloadVariant(from: "parakeet:unified", defaults: defaults), .unified)
        XCTAssertEqual(parakeetModelID(for: .unified), "parakeet-unified")
        // Bare "parakeet" resolves to the persisted build.
        SpeechEnginePreference.saveParakeetModelVariant(.v2, defaults: defaults)
        XCTAssertEqual(parakeetDownloadVariant(from: "parakeet", defaults: defaults), .v2)
        // Non-Parakeet ids fall through (nil) so Whisper parsing runs.
        XCTAssertNil(parakeetDownloadVariant(from: "whisper-large-v3", defaults: defaults))
        XCTAssertNil(parakeetDownloadVariant(from: "tiny", defaults: defaults))
    }

    func testNemotronDownloadVariantRecognizesNemotronIDs() throws {
        let suiteName = "com.macparakeet.tests.cli.nemotron-download.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(nemotronDownloadVariant(from: "nemotron-multilingual-1120ms", defaults: defaults), .multilingual1120)
        XCTAssertEqual(nemotronDownloadVariant(from: "nemotron:beta", defaults: defaults), .multilingual1120)
        XCTAssertEqual(nemotronDownloadVariant(from: "nemotron_multilingual", defaults: defaults), .multilingual1120)
        XCTAssertEqual(nemotronDownloadVariant(from: "nemotron-english-1120ms", defaults: defaults), .english1120)
        XCTAssertEqual(nemotronDownloadVariant(from: "nemotron-english", defaults: defaults), .english1120)
        XCTAssertEqual(nemotronDownloadVariant(from: "nemotron-english-only", defaults: defaults), .english1120)
        XCTAssertEqual(nemotronDownloadVariant(from: "nemotron:en", defaults: defaults), .english1120)
        // Underscore spellings normalize to hyphens, matching `config set`.
        XCTAssertEqual(nemotronDownloadVariant(from: "nemotron_english_1120ms", defaults: defaults), .english1120)
        // Bare "nemotron" resolves to the persisted build (multilingual when unset).
        XCTAssertEqual(nemotronDownloadVariant(from: "nemotron", defaults: defaults), .multilingual1120)
        SpeechEnginePreference.saveNemotronModelVariant(.english1120, defaults: defaults)
        XCTAssertEqual(nemotronDownloadVariant(from: "nemotron", defaults: defaults), .english1120)
        // Non-Nemotron ids fall through (nil) so Whisper parsing runs.
        XCTAssertNil(nemotronDownloadVariant(from: "parakeet-v3", defaults: defaults))
        XCTAssertNil(nemotronDownloadVariant(from: "whisper-large-v3", defaults: defaults))
    }

    func testCohereModelLifecycleSubcommandsParseCanonicalModelID() throws {
        let modelID = "cohere-transcribe"

        let download = try ModelsCommand.Download.parse([modelID])
        XCTAssertEqual(download.variant, modelID)
        XCTAssertTrue(isCohereModelID(download.variant))

        let select = try ModelsCommand.Select.parse([modelID])
        XCTAssertEqual(select.id, modelID)
        XCTAssertEqual(
            try resolveSelectableSpeechModel(select.id),
            SelectableSpeechModelSelection(engine: .cohere, whisperVariant: nil)
        )

        let delete = try ModelsCommand.Delete.parse([modelID, "--force"])
        XCTAssertEqual(delete.id, modelID)
        XCTAssertTrue(delete.force)
        XCTAssertEqual(try resolveModelDeletionTarget(delete.id).kind, .cohere)
    }

    func testNemotronModelLifecycleSubcommandsParseCanonicalModelID() throws {
        let modelID = "nemotron-multilingual-1120ms"

        let download = try ModelsCommand.Download.parse([modelID])
        XCTAssertEqual(download.variant, modelID)
        XCTAssertEqual(nemotronDownloadVariant(from: download.variant), .multilingual1120)

        let select = try ModelsCommand.Select.parse([modelID])
        XCTAssertEqual(select.id, modelID)
        XCTAssertEqual(
            try resolveSelectableSpeechModel(select.id),
            SelectableSpeechModelSelection(
                engine: .nemotron,
                whisperVariant: nil,
                nemotronVariant: .multilingual1120
            )
        )

        let delete = try ModelsCommand.Delete.parse([modelID, "--force"])
        XCTAssertEqual(delete.id, modelID)
        XCTAssertTrue(delete.force)
        XCTAssertEqual(try resolveModelDeletionTarget(delete.id).kind, .nemotron(.multilingual1120))
    }

    func testNemotronEnglishModelLifecycleSubcommandsParseCanonicalModelID() throws {
        let modelID = "nemotron-english-1120ms"

        let download = try ModelsCommand.Download.parse([modelID])
        XCTAssertEqual(download.variant, modelID)
        XCTAssertEqual(nemotronDownloadVariant(from: download.variant), .english1120)

        let select = try ModelsCommand.Select.parse([modelID])
        XCTAssertEqual(select.id, modelID)
        XCTAssertEqual(
            try resolveSelectableSpeechModel(select.id),
            SelectableSpeechModelSelection(
                engine: .nemotron,
                whisperVariant: nil,
                nemotronVariant: .english1120
            )
        )

        let delete = try ModelsCommand.Delete.parse([modelID, "--force"])
        XCTAssertEqual(delete.id, modelID)
        XCTAssertTrue(delete.force)
        XCTAssertEqual(try resolveModelDeletionTarget(delete.id).kind, .nemotron(.english1120))
    }

    func testResolveSelectableSpeechModelRejectsUnknownID() {
        XCTAssertThrowsError(try resolveSelectableSpeechModel("tiny")) { error in
            XCTAssertTrue(error is ValidationError)
        }
        XCTAssertThrowsError(try resolveSelectableSpeechModel("parakeet:large")) { error in
            XCTAssertTrue(error is ValidationError)
        }
        XCTAssertThrowsError(try resolveSelectableSpeechModel("whisper-")) { error in
            XCTAssertTrue(error is ValidationError)
        }
        XCTAssertThrowsError(try resolveSelectableSpeechModel("whisper:")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testValidateSelectableSpeechModelDownloadRejectsMissingNemotron() throws {
        let suiteName = "com.macparakeet.tests.cli.model-select-nemotron-missing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SpeechEnginePreference.saveNemotronDefaultLanguage("en_US", defaults: defaults)
        var checkedVariant: NemotronModelVariant?
        var checkedLanguage: String?
        let selection = SelectableSpeechModelSelection(
            engine: .nemotron,
            whisperVariant: nil,
            nemotronVariant: .multilingual1120
        )

        XCTAssertThrowsError(
            try validateSelectableSpeechModelDownload(
                selection,
                defaults: defaults,
                isNemotronModelDownloaded: { variant, language in
                    checkedVariant = variant
                    checkedLanguage = language
                    return false
                },
                isWhisperModelDownloaded: { _ in true },
                isCohereModelDownloaded: { true }
            )
        ) { error in
            XCTAssertTrue(error is ValidationError)
            XCTAssertTrue(String(describing: error).contains("models download nemotron-multilingual-1120ms"))
        }
        XCTAssertEqual(checkedVariant, .multilingual1120)
        XCTAssertEqual(checkedLanguage, "en-US")
        XCTAssertNil(defaults.string(forKey: SpeechEnginePreference.defaultsKey))
    }

    func testValidateSelectableSpeechModelDownloadAllowsDownloadedNemotron() throws {
        let suiteName = "com.macparakeet.tests.cli.model-select-nemotron-downloaded.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let selection = SelectableSpeechModelSelection(
            engine: .nemotron,
            whisperVariant: nil,
            nemotronVariant: .multilingual1120
        )

        XCTAssertNoThrow(
            try validateSelectableSpeechModelDownload(
                selection,
                defaults: defaults,
                isNemotronModelDownloaded: { variant, language in
                    XCTAssertEqual(variant, .multilingual1120)
                    XCTAssertNil(language)
                    return true
                },
                isWhisperModelDownloaded: { _ in false },
                isCohereModelDownloaded: { false }
            )
        )
    }

    func testValidateSelectableSpeechModelDownloadRejectsMissingCohere() throws {
        let suiteName = "com.macparakeet.tests.cli.model-select-cohere-missing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let selection = SelectableSpeechModelSelection(engine: .cohere, whisperVariant: nil)

        XCTAssertThrowsError(
            try validateSelectableSpeechModelDownload(
                selection,
                defaults: defaults,
                isNemotronModelDownloaded: { _, _ in true },
                isWhisperModelDownloaded: { _ in true },
                isCohereModelDownloaded: { false }
            )
        ) { error in
            XCTAssertTrue(error is ValidationError)
            XCTAssertTrue(String(describing: error).contains("models download cohere-transcribe"))
        }
    }

    func testValidateSelectableSpeechModelDownloadAllowsDownloadedCohere() throws {
        let suiteName = "com.macparakeet.tests.cli.model-select-cohere-downloaded.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNoThrow(
            try validateSelectableSpeechModelDownload(
                SelectableSpeechModelSelection(engine: .cohere, whisperVariant: nil),
                defaults: defaults,
                isNemotronModelDownloaded: { _, _ in false },
                isWhisperModelDownloaded: { _ in false },
                isCohereModelDownloaded: { true }
            )
        )
    }

    // MARK: - models delete

    private func makeDeleteDefaults() throws -> (UserDefaults, String) {
        let suite = "test.ModelsDelete.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testResolveModelDeletionTargetMapsParakeetAndWhisperIDs() throws {
        let (defaults, suite) = try makeDeleteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            try resolveModelDeletionTarget("parakeet-v2", defaults: defaults).kind,
            .parakeet(.v2)
        )
        XCTAssertEqual(
            try resolveModelDeletionTarget("parakeet-v3", defaults: defaults).kind,
            .parakeet(.v3)
        )
        XCTAssertEqual(
            try resolveModelDeletionTarget("nemotron-multilingual-1120ms", defaults: defaults).kind,
            .nemotron(.multilingual1120)
        )
        XCTAssertEqual(
            try resolveModelDeletionTarget("nemotron-english-1120ms", defaults: defaults).kind,
            .nemotron(.english1120)
        )
        XCTAssertEqual(
            try resolveModelDeletionTarget("whisper-large-v3-v20240930-turbo-632MB", defaults: defaults).kind,
            .whisper("large-v3-v20240930_turbo_632MB")
        )
        XCTAssertEqual(
            try resolveModelDeletionTarget("cohere-transcribe", defaults: defaults).kind,
            .cohere
        )
    }

    func testResolveModelDeletionTargetRejectsUnknownID() throws {
        let (defaults, suite) = try makeDeleteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertThrowsError(try resolveModelDeletionTarget("tiny", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testIsModelInUseProtectsConfiguredParakeetBuild() throws {
        let (defaults, suite) = try makeDeleteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.parakeet.save(to: defaults)
        SpeechEnginePreference.saveParakeetModelVariant(.v3, defaults: defaults)

        XCTAssertTrue(isModelInUse(.init(kind: .parakeet(.v3), displayName: "v3"), defaults: defaults))
        XCTAssertFalse(isModelInUse(.init(kind: .parakeet(.v2), displayName: "v2"), defaults: defaults))
        // Parakeet is active, so Whisper is never the in-use model.
        XCTAssertFalse(
            isModelInUse(
                .init(kind: .whisper(SpeechEnginePreference.defaultWhisperModelVariant), displayName: "whisper"),
                defaults: defaults
            )
        )
        XCTAssertFalse(isModelInUse(.init(kind: .nemotron(.multilingual1120), displayName: "nemotron"), defaults: defaults))
        XCTAssertFalse(isModelInUse(.init(kind: .cohere, displayName: "cohere"), defaults: defaults))
    }

    func testIsModelInUseProtectsWhisperAndConfiguredParakeetWhenWhisperActive() throws {
        let (defaults, suite) = try makeDeleteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.whisper.save(to: defaults)
        SpeechEnginePreference.saveParakeetModelVariant(.v3, defaults: defaults)
        let variant = SpeechEnginePreference.whisperModelVariant(defaults: defaults)

        XCTAssertTrue(isModelInUse(.init(kind: .whisper(variant), displayName: "whisper"), defaults: defaults))
        // Parakeet's configured build is protected too: it is what Parakeet
        // would load if the user switches back from Whisper.
        XCTAssertTrue(isModelInUse(.init(kind: .parakeet(.v3), displayName: "v3"), defaults: defaults))
        XCTAssertFalse(isModelInUse(.init(kind: .parakeet(.v2), displayName: "v2"), defaults: defaults))
        XCTAssertFalse(isModelInUse(.init(kind: .nemotron(.multilingual1120), displayName: "nemotron"), defaults: defaults))
    }

    func testIsModelInUseProtectsNemotronWhenNemotronActive() throws {
        let (defaults, suite) = try makeDeleteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.nemotron.save(to: defaults)

        // No persisted variant: multilingual is the default Nemotron build.
        XCTAssertTrue(isModelInUse(.init(kind: .nemotron(.multilingual1120), displayName: "nemotron"), defaults: defaults))
        XCTAssertFalse(isModelInUse(.init(kind: .nemotron(.english1120), displayName: "nemotron-en"), defaults: defaults))
        XCTAssertFalse(
            isModelInUse(
                .init(kind: .whisper(SpeechEnginePreference.defaultWhisperModelVariant), displayName: "whisper"),
                defaults: defaults
            )
        )
        XCTAssertFalse(isModelInUse(.init(kind: .cohere, displayName: "cohere"), defaults: defaults))
    }

    func testIsModelInUseProtectsCohereWhenCohereActive() throws {
        let (defaults, suite) = try makeDeleteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.cohere.save(to: defaults)

        XCTAssertTrue(isModelInUse(.init(kind: .cohere, displayName: "cohere"), defaults: defaults))
        // The configured Parakeet build is also protected: it is what Parakeet
        // would load if the user switches back from Cohere.
        XCTAssertTrue(isModelInUse(.init(kind: .parakeet(.v3), displayName: "v3"), defaults: defaults))
        XCTAssertFalse(isModelInUse(.init(kind: .nemotron(.multilingual1120), displayName: "nemotron"), defaults: defaults))
        XCTAssertFalse(
            isModelInUse(
                .init(kind: .whisper(SpeechEnginePreference.defaultWhisperModelVariant), displayName: "whisper"),
                defaults: defaults
            )
        )
    }

    func testIsModelInUseProtectsConfiguredNemotronBuildWhenNemotronActive() throws {
        let (defaults, suite) = try makeDeleteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.nemotron.save(to: defaults)
        SpeechEnginePreference.saveNemotronModelVariant(.english1120, defaults: defaults)

        XCTAssertTrue(isModelInUse(.init(kind: .nemotron(.english1120), displayName: "nemotron-en"), defaults: defaults))
        XCTAssertFalse(isModelInUse(.init(kind: .nemotron(.multilingual1120), displayName: "nemotron"), defaults: defaults))

        SpeechEnginePreference.saveNemotronModelVariant(.multilingual1120, defaults: defaults)
        XCTAssertTrue(isModelInUse(.init(kind: .nemotron(.multilingual1120), displayName: "nemotron"), defaults: defaults))
        XCTAssertFalse(isModelInUse(.init(kind: .nemotron(.english1120), displayName: "nemotron-en"), defaults: defaults))
    }

    func testDeleteCommandParsesForceFlag() throws {
        let plain = try ModelsCommand.Delete.parse(["parakeet-v2"])
        XCTAssertEqual(plain.id, "parakeet-v2")
        XCTAssertFalse(plain.force)

        let forced = try ModelsCommand.Delete.parse(["parakeet-v2", "--force"])
        XCTAssertTrue(forced.force)
    }

    func testDeleteFailureIsRuntimeFailure() {
        let error = ModelDeletionError.deleteFailed("Could not delete Parakeet v2.")
        XCTAssertEqual(CLI.normalizedExitCode(for: error), .failure)
    }

    func testWarmUpRetriesConfiguredAttempts() async {
        let stt = StubSTTClient()
        let diarization = StubDiarizationService()
        await stt.setFailuresBeforeSuccess(2)

        do {
            try await prepareSpeechStack(
                attempts: 3,
                sttClient: stt,
                diarizationService: diarization,
                log: { _ in }
            )
        } catch {
            XCTFail("Expected warm-up to succeed after retries, got \(error)")
        }

        let sttCalls = await stt.warmUpCalls
        XCTAssertEqual(sttCalls, 3)
        let diarizationCalls = await diarization.prepareModelsCalls
        XCTAssertEqual(diarizationCalls, 1)
    }

    func testLoadSpeechStackStatusReflectsSpeechAndSpeakerReadinessSeparately() async throws {
        let stt = StubSTTClient()
        let diarization = StubDiarizationService()
        await stt.setReady(true)
        await diarization.setCachedModels(false)
        await diarization.setReady(false)

        // Isolated suite: without it the status reads the live app's
        // preferences, so the test result depends on whichever speech
        // engine the developer's MacParakeet install has selected.
        let suiteName = "com.macparakeet.tests.cli.models.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let status = await loadSpeechStackStatus(
            sttClient: stt,
            diarizationService: diarization,
            defaults: defaults,
            isParakeetModelCached: { $0 == .v3 },
            nemotronModelVariant: .multilingual1120,
            isNemotronModelDownloaded: { $0 == .multilingual1120 },
            whisperModelVariant: "large-v3-v20240930_turbo_632MB",
            isWhisperModelDownloaded: { $0 == "large-v3-v20240930_turbo_632MB" },
            isCohereModelDownloaded: { false }
        )

        XCTAssertEqual(
            status,
            SpeechStackStatus(
                speechEngine: .parakeet,
                speechModelCached: true,
                speechRuntimeReady: true,
                speakerModelsCached: false,
                speakerModelsPrepared: false,
                parakeetModelVariant: .v3,
                parakeetModelDownloaded: true,
                nemotronModelVariant: .multilingual1120,
                nemotronModelDownloaded: true,
                whisperModelVariant: "large-v3-v20240930_turbo_632MB",
                whisperModelDownloaded: true,
                cohereModelDownloaded: false
            )
        )
        XCTAssertEqual(status.summary, "Speech model present, speaker models missing")
    }

    func testAudioInputDiagnosticsShowsSelectedDefaultAndFallbackOrder() {
        let selected = inputDevice(
            id: 10,
            uid: "usb-mic",
            name: "Desk USB Mic",
            transport: kAudioDeviceTransportTypeUSB
        )
        let defaultDevice = inputDevice(
            id: 20,
            uid: "conference-mic",
            name: "Conference Mic",
            transport: kAudioDeviceTransportTypeBluetooth
        )
        let builtIn = inputDevice(
            id: 30,
            uid: "builtin-mic",
            name: "MacBook Pro Microphone",
            transport: kAudioDeviceTransportTypeBuiltIn
        )
        let diagnostics = AudioInputDiagnostics(
            devices: [selected, defaultDevice, builtIn],
            defaultDevice: defaultDevice,
            storedSelectedUID: "usb-mic"
        )

        XCTAssertEqual(
            audioInputDiagnosticsLines(diagnostics),
            [
                "  System default: Conference Mic [bluetooth]",
                "  Stored selection: Desk USB Mic [usb, selected, available]",
                "  Effective fallback order:",
                "    1. Desk USB Mic [usb, selected]",
                "    2. Conference Mic [bluetooth, system default]",
                "    3. MacBook Pro Microphone [built-in, built-in fallback]",
                "  Devices:",
                "    - Desk USB Mic [usb, selected]",
                "    - Conference Mic [bluetooth, system default]",
                "    - MacBook Pro Microphone [built-in]",
            ]
        )
    }

    func testAudioInputDiagnosticsReportsUnavailableStoredSelectionWithoutUID() {
        let defaultDevice = inputDevice(
            id: 20,
            uid: "builtin-mic",
            name: "MacBook Pro Microphone",
            transport: kAudioDeviceTransportTypeBuiltIn
        )
        let diagnostics = AudioInputDiagnostics(
            devices: [defaultDevice],
            defaultDevice: defaultDevice,
            storedSelectedUID: "missing-secret-uid"
        )

        let lines = audioInputDiagnosticsLines(diagnostics)

        XCTAssertTrue(lines.contains("  Stored selection: Unavailable (stored device is not currently connected)"))
        XCTAssertFalse(lines.joined(separator: "\n").contains("missing-secret-uid"))
        XCTAssertEqual(
            lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("1.") },
            ["    1. MacBook Pro Microphone [built-in, system default, built-in fallback]"]
        )
    }

    func testAudioInputDiagnosticsDeduplicatesDefaultBuiltInFallback() {
        let builtInDefault = inputDevice(
            id: 30,
            uid: "builtin-mic",
            name: "MacBook Pro Microphone",
            transport: kAudioDeviceTransportTypeBuiltIn
        )
        let diagnostics = AudioInputDiagnostics(
            devices: [builtInDefault],
            defaultDevice: builtInDefault,
            storedSelectedUID: nil
        )

        XCTAssertEqual(
            audioInputDiagnosticsLines(diagnostics),
            [
                "  System default: MacBook Pro Microphone [built-in]",
                "  Stored selection: System Default",
                "  Effective fallback order:",
                "    1. MacBook Pro Microphone [built-in, system default, built-in fallback]",
                "  Devices:",
                "    - MacBook Pro Microphone [built-in, system default]",
            ]
        )
    }

    func testAudioInputDiagnosticsMarksSelectedDeviceThatIsAlsoSystemDefault() {
        let selectedDefault = inputDevice(
            id: 10,
            uid: "usb-mic",
            name: "Desk USB Mic",
            transport: kAudioDeviceTransportTypeUSB
        )
        let builtIn = inputDevice(
            id: 30,
            uid: "builtin-mic",
            name: "MacBook Pro Microphone",
            transport: kAudioDeviceTransportTypeBuiltIn
        )
        let diagnostics = AudioInputDiagnostics(
            devices: [selectedDefault, builtIn],
            defaultDevice: selectedDefault,
            storedSelectedUID: "usb-mic"
        )

        XCTAssertEqual(
            audioInputDiagnosticsLines(diagnostics),
            [
                "  System default: Desk USB Mic [usb]",
                "  Stored selection: Desk USB Mic [usb, selected, available]",
                "  Effective fallback order:",
                "    1. Desk USB Mic [usb, selected, system default]",
                "    2. MacBook Pro Microphone [built-in, built-in fallback]",
                "  Devices:",
                "    - Desk USB Mic [usb, system default, selected]",
                "    - MacBook Pro Microphone [built-in]",
            ]
        )
    }

    func testLoadAudioInputDiagnosticsUsesInjectedDefaultsAndProviders() {
        let suiteName = "com.macparakeet.tests.cli.audio.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("usb-mic", forKey: UserDefaultsAppRuntimePreferences.selectedMicrophoneDeviceUIDKey)

        let selected = inputDevice(
            id: 10,
            uid: "usb-mic",
            name: "Desk USB Mic",
            transport: kAudioDeviceTransportTypeUSB
        )
        let defaultDevice = inputDevice(
            id: 20,
            uid: "conference-mic",
            name: "Conference Mic",
            transport: kAudioDeviceTransportTypeBluetooth
        )
        var inputDevicesCalls = 0
        var defaultInputDeviceInfoCalls = 0

        let diagnostics = loadAudioInputDiagnostics(
            defaults: defaults,
            inputDevices: {
                inputDevicesCalls += 1
                return [selected, defaultDevice]
            },
            defaultInputDeviceInfo: {
                defaultInputDeviceInfoCalls += 1
                return defaultDevice
            }
        )

        XCTAssertEqual(inputDevicesCalls, 1)
        XCTAssertEqual(defaultInputDeviceInfoCalls, 1)
        XCTAssertEqual(diagnostics.devices.map(\.uid), ["usb-mic", "conference-mic"])
        XCTAssertEqual(diagnostics.defaultDevice?.uid, "conference-mic")
        XCTAssertEqual(diagnostics.storedSelectedUID, "usb-mic")
        XCTAssertEqual(diagnostics.selectedDevice?.uid, "usb-mic")
        XCTAssertEqual(diagnostics.fallbackOrder.map(\.uid), ["usb-mic", "conference-mic"])
    }
}

private func inputDevice(
    id: AudioDeviceID,
    uid: String,
    name: String,
    transport: UInt32
) -> AudioDeviceManager.InputDevice {
    AudioDeviceManager.InputDevice(
        id: id,
        uid: uid,
        name: name,
        transportType: transport
    )
}

private actor StubSTTClient: STTClientProtocol {
    private(set) var warmUpCalls = 0
    private var alwaysFail = false
    private var failuresBeforeSuccess = 0
    private var ready = false

    func setAlwaysFail(_ value: Bool) {
        alwaysFail = value
    }

    func setFailuresBeforeSuccess(_ count: Int) {
        failuresBeforeSuccess = max(0, count)
    }

    func setReady(_ value: Bool) {
        ready = value
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        STTResult(text: "", words: [])
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        warmUpCalls += 1
        if alwaysFail {
            throw STTError.engineStartFailed("forced failure")
        }
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw STTError.engineStartFailed("transient failure")
        }
        ready = true
    }

    func backgroundWarmUp() async {}

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(ready ? .ready : .idle)
            continuation.finish()
        }
        return (UUID(), stream)
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool {
        ready
    }

    func clearModelCache() async {
        ready = false
    }

    func shutdown() async {}
}

private actor StubDiarizationService: DiarizationServiceProtocol {
    private(set) var prepareModelsCalls = 0
    private var ready = false
    private var cachedModels = false

    func setReady(_ value: Bool) {
        ready = value
    }

    func setCachedModels(_ value: Bool) {
        cachedModels = value
    }

    func diarize(audioURL: URL) async throws -> MacParakeetDiarizationResult {
        MacParakeetDiarizationResult(segments: [], speakerCount: 0, speakers: [])
    }

    func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws {
        prepareModelsCalls += 1
        ready = true
        cachedModels = true
        onProgress?("Speaker models ready")
    }

    func isReady() async -> Bool {
        ready
    }

    func hasCachedModels() async -> Bool {
        cachedModels
    }
}
