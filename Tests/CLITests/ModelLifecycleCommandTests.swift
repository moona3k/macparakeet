import ArgumentParser
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
        let command = try HealthCommand.parse(["--repair-models", "--repair-attempts", "6"])
        XCTAssertTrue(command.repairModels)
        XCTAssertEqual(command.repairAttempts, 6)
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
            isSpeechModelCached: { true }
        )

        XCTAssertEqual(
            status,
            SpeechStackStatus(
                speechModelCached: true,
                speechRuntimeReady: true,
                speakerModelsCached: false,
                speakerModelsPrepared: false
            )
        )
        XCTAssertEqual(status.summary, "Speech model present, speaker models missing")
    }
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
