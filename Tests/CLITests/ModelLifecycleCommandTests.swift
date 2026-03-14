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
        await stt.setFailuresBeforeSuccess(2)

        do {
            try await warmUpModels(
                attempts: 3,
                sttClient: stt,
                log: { _ in }
            )
        } catch {
            XCTFail("Expected warm-up to succeed after retries, got \(error)")
        }

        let sttCalls = await stt.warmUpCalls
        XCTAssertEqual(sttCalls, 3)
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

    func transcribe(audioPath: String, onProgress: (@Sendable (Int, Int) -> Void)?) async throws -> STTResult {
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

    func isReady() async -> Bool {
        ready
    }

    func clearModelCache() async {
        ready = false
    }

    func shutdown() async {}
}
