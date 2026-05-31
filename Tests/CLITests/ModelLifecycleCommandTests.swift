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
            isWhisperModelDownloaded: { $0 == "large-v3-v20240930_turbo_632MB" }
        )

        XCTAssertEqual(models.count, 3)
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
            isWhisperModelDownloaded: { _ in false }
        )

        let v3 = try XCTUnwrap(models.first { $0.id == "parakeet-v3" })
        let v2 = try XCTUnwrap(models.first { $0.id == "parakeet-v2" })
        XCTAssertFalse(v3.selected, "Multilingual build should not be marked selected")
        XCTAssertTrue(v2.selected, "English-only build is the persisted Parakeet variant")
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
        // Bare "parakeet" resolves to the persisted build.
        SpeechEnginePreference.saveParakeetModelVariant(.v2, defaults: defaults)
        XCTAssertEqual(parakeetDownloadVariant(from: "parakeet", defaults: defaults), .v2)
        // Non-Parakeet ids fall through (nil) so Whisper parsing runs.
        XCTAssertNil(parakeetDownloadVariant(from: "whisper-large-v3", defaults: defaults))
        XCTAssertNil(parakeetDownloadVariant(from: "tiny", defaults: defaults))
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
            try resolveModelDeletionTarget("whisper-large-v3-v20240930-turbo-632MB", defaults: defaults).kind,
            .whisper("large-v3-v20240930_turbo_632MB")
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
    }

    func testDeleteCommandParsesForceFlag() throws {
        let plain = try ModelsCommand.Delete.parse(["parakeet-v2"])
        XCTAssertEqual(plain.id, "parakeet-v2")
        XCTAssertFalse(plain.force)

        let forced = try ModelsCommand.Delete.parse(["parakeet-v2", "--force"])
        XCTAssertTrue(forced.force)
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

    func testLoadSpeechStackStatusReflectsSpeechAndSpeakerReadinessSeparately() async {
        let stt = StubSTTClient()
        let diarization = StubDiarizationService()
        await stt.setReady(true)
        await diarization.setCachedModels(false)
        await diarization.setReady(false)

        let status = await loadSpeechStackStatus(
            sttClient: stt,
            diarizationService: diarization,
            isSpeechModelCached: { true },
            whisperModelVariant: "large-v3-v20240930_turbo_632MB",
            isWhisperModelDownloaded: { $0 == "large-v3-v20240930_turbo_632MB" }
        )

        XCTAssertEqual(
            status,
            SpeechStackStatus(
                speechModelCached: true,
                speechRuntimeReady: true,
                speakerModelsCached: false,
                speakerModelsPrepared: false,
                whisperModelVariant: "large-v3-v20240930_turbo_632MB",
                whisperModelDownloaded: true
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
