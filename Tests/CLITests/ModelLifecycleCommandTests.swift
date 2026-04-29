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
