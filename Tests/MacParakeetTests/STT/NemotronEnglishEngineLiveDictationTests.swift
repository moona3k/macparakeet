import XCTest
@testable import MacParakeetCore

/// Guards the wiring that lets the English-only Nemotron build drive live
/// dictation partials, just like the multilingual build. The happy path needs
/// real CoreML models, so these tests cover the model-free invariants: the
/// `NemotronLiveDictating` conformance (so `STTRuntime` can route to it) and the
/// session guards that reject append/finish without an active session.
///
/// Regression target: the English build used to be rejected from the live path
/// (`STTRuntime` threw `unsupportedEngine(.nemotron)` for `isEnglishOnly`). If
/// that exclusion or the conformance is reintroduced, these fail to compile or
/// fail at runtime.
final class NemotronEnglishEngineLiveDictationTests: XCTestCase {
    func testConformsToNemotronLiveDictating() {
        // Compile-time proof the runtime can hold this build as the active
        // live-dictation engine.
        let engine: any NemotronLiveDictating = NemotronEnglishEngine()
        XCTAssertNotNil(engine)
    }

    func testRuntimeDoesNotRejectEnglishVariantAsUnsupportedForLiveDictation() async {
        let runtime = STTRuntime(speechEngine: .nemotron, nemotronModelVariant: .english1120)

        do {
            try await runtime.beginLiveDictationTranscription(sessionID: UUID()) { _ in }
            XCTFail("Expected unprepared English Nemotron runtime to throw modelNotReady")
        } catch let error as STTLiveDictationTranscriptionError {
            XCTAssertEqual(error, .modelNotReady)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProcessSamplesWithoutActiveSessionThrowsSessionNotActive() async {
        let engine = NemotronEnglishEngine()
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
        // Empty slices short-circuit before the session guard (mirrors the
        // multilingual engine), so they must not throw.
        let engine = NemotronEnglishEngine()
        try await engine.processLiveDictationSamples([])
    }

    func testFinishWithoutActiveSessionThrowsSessionNotActive() async {
        let engine = NemotronEnglishEngine()
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
        // Cancel must be safe to call on an idle engine (the runtime calls it on
        // abort/shutdown paths even when no session was started).
        let engine = NemotronEnglishEngine()
        await engine.cancelLiveDictation()
    }
}
