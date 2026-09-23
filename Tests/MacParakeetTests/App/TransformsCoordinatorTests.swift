import XCTest
@testable import MacParakeet
import MacParakeetCore

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

    func testMenuCaptureMustBelongToMenuOpenApp() {
        let menuOpenTarget = SelectionCaptureTarget(
            processIdentifier: 99,
            bundleIdentifier: "com.apple.mail"
        )
        let otherTarget = SelectionCaptureTarget(
            processIdentifier: 1234,
            bundleIdentifier: "com.example.Other"
        )
        let captured = SelectionCaptureResult.clipboard(
            text: "Other app selection",
            savedClipboard: .none,
            target: otherTarget
        )

        XCTAssertFalse(TransformsCoordinator.menuCaptureBelongsToTarget(captured, target: menuOpenTarget))
        XCTAssertFalse(TransformsCoordinator.menuCaptureBelongsToTarget(captured, target: nil))
        XCTAssertTrue(TransformsCoordinator.menuCaptureBelongsToTarget(captured, target: otherTarget))
    }
}
