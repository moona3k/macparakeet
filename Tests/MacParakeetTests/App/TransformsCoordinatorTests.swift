import XCTest
@testable import MacParakeet

@MainActor
final class TransformsCoordinatorTests: XCTestCase {
    func testActiveModelIsSnapshottedBeforeAQueuedTransformCanObserveConfigChange() {
        var activeModel = "model-before-queue"

        let snapshot = TransformsCoordinator.resolveModelSnapshot(
            promptOverride: nil,
            activeModelName: activeModel
        )
        activeModel = "model-after-queue"

        XCTAssertEqual(snapshot, "model-before-queue")
        XCTAssertEqual(activeModel, "model-after-queue")
    }

    func testPromptModelOverrideWinsOverActiveModelSnapshot() {
        XCTAssertEqual(
            TransformsCoordinator.resolveModelSnapshot(
                promptOverride: " prompt-model ",
                activeModelName: "global-model"
            ),
            "prompt-model"
        )
    }
}
