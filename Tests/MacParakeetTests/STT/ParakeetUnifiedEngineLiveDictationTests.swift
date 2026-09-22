import XCTest
@testable import MacParakeetCore

/// Guards Parakeet Unified's native streaming live-dictation wiring. The happy
/// path needs real CoreML models, so these tests cover model-free invariants:
/// runtime routing, protocol conformance, and idle-session guards.
final class ParakeetUnifiedEngineLiveDictationTests: XCTestCase {
    func testConformsToNativeLiveDictating() {
        let engine: any NativeLiveDictating = ParakeetUnifiedEngine()
        XCTAssertNotNil(engine)
    }

    func testRuntimeRoutesUnifiedParakeetToLiveDictationWithoutUnsupportedEngine() async {
        let runtime = STTRuntime(parakeetModelVariant: .unified, speechEngine: .parakeet)

        do {
            try await runtime.beginLiveDictationTranscription(sessionID: UUID()) { _ in }
            XCTFail("Expected unprepared Unified runtime to throw modelNotReady")
        } catch let error as STTLiveDictationTranscriptionError {
            XCTAssertEqual(error, .modelNotReady)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRuntimeStillRejectsTDTParakeetVariantsForNativeLiveDictation() async {
        let runtime = STTRuntime(parakeetModelVariant: .v3, speechEngine: .parakeet)

        do {
            try await runtime.beginLiveDictationTranscription(sessionID: UUID()) { _ in }
            XCTFail("Expected Parakeet TDT runtime to reject native live dictation")
        } catch let error as STTLiveDictationTranscriptionError {
            XCTAssertEqual(error, .unsupportedEngine(.parakeet))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProcessSamplesWithoutActiveSessionThrowsSessionNotActive() async {
        let engine = ParakeetUnifiedEngine()
        do {
            try await engine.processLiveDictationSamples([0.1, 0.2, 0.3])
            XCTFail("Expected processLiveDictationSamples to throw without an active session")
        } catch let error as STTLiveDictationTranscriptionError {
            XCTAssertEqual(error, .sessionNotActive)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProcessEmptySamplesIsANoOpWithoutActiveSession() async throws {
        let engine = ParakeetUnifiedEngine()
        try await engine.processLiveDictationSamples([])
    }

    func testFinishWithoutActiveSessionThrowsSessionNotActive() async {
        let engine = ParakeetUnifiedEngine()
        do {
            _ = try await engine.finishLiveDictation()
            XCTFail("Expected finishLiveDictation to throw without an active session")
        } catch let error as STTLiveDictationTranscriptionError {
            XCTAssertEqual(error, .sessionNotActive)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancelWithoutActiveSessionIsANoOp() async {
        let engine = ParakeetUnifiedEngine()
        await engine.cancelLiveDictation()
    }
}
