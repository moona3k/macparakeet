import XCTest
@testable import MacParakeetCore

final class MeetingSpeechPlanTests: XCTestCase {
    func testLiveParakeetAndFinalCohereUsesParakeetForPreview() {
        let live = SpeechEngineSelection(engine: .parakeet)
        let final = SpeechEngineSelection(engine: .cohere, language: "fr")

        let plan = MeetingSpeechPlan.resolve(
            live: live,
            final: final,
            liveCapabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3))
        )

        XCTAssertEqual(plan.preview, live)
        XCTAssertEqual(plan.final, final)
    }

    func testLiveCohereAndFinalWhisperDisablesPreviewWithoutFallback() {
        let live = SpeechEngineSelection(engine: .cohere, language: "fr")
        let final = SpeechEngineSelection(engine: .whisper, language: "ko")

        let plan = MeetingSpeechPlan.resolve(
            live: live,
            final: final,
            liveCapabilities: SpeechEngineCapabilityRegistry.capabilities(for: .cohere)
        )

        XCTAssertNil(plan.preview)
        XCTAssertEqual(plan.final, final)
    }

    func testSamePreviewCapableEngineUsesSelectionForBothRoles() {
        let selection = SpeechEngineSelection(engine: .whisper, language: "ja")

        let plan = MeetingSpeechPlan.resolve(
            live: selection,
            final: selection,
            liveCapabilities: SpeechEngineCapabilityRegistry.capabilities(
                for: .whisper(.largeV3Turbo632MB)
            )
        )

        XCTAssertEqual(plan, MeetingSpeechPlan(preview: selection, final: selection))
    }

    func testMissingCapabilitiesDisablesPreviewWithoutChangingFinalRoute() {
        let final = SpeechEngineSelection(engine: .parakeet)

        let plan = MeetingSpeechPlan.resolve(
            live: SpeechEngineSelection(engine: .whisper, language: "ja"),
            final: final,
            liveCapabilities: nil
        )

        XCTAssertNil(plan.preview)
        XCTAssertEqual(plan.final, final)
    }
}
