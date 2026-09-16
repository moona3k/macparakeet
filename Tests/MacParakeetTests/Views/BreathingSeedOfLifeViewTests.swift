import XCTest
@testable import MacParakeet

@MainActor
final class BreathingSeedOfLifeViewTests: XCTestCase {
    func testListeningStateRotatesAndBreathesAtFullCoral() {
        let view = makeView()

        view.update(animating: true, frozen: false, quiet: false)

        XCTAssertTrue(view.testHook_hasRotationAnimation)
        XCTAssertTrue(view.testHook_hasBreathingAnimation)
        XCTAssertEqual(view.testHook_flowerLayerSpeed, 1, accuracy: 0.01)
        XCTAssertFalse(view.testHook_isQuiet)
        XCTAssertEqual(
            view.testHook_centerRingStrokeAlpha,
            BreathingSeedOfLifeNSView.listeningCenterRingAlpha,
            accuracy: 0.02
        )
    }

    func testQuietStateStopsMotionAndFadesCoralEvenIfCallerAsksToAnimate() {
        let view = makeView()

        // Pass animating: true on purpose. Quiet must still win, otherwise a
        // faded spin would ship if the representable forgot to AND the flags.
        view.update(animating: true, frozen: false, quiet: true)

        XCTAssertFalse(view.testHook_hasRotationAnimation)
        XCTAssertFalse(view.testHook_hasBreathingAnimation)
        XCTAssertTrue(view.testHook_isQuiet)
        XCTAssertEqual(
            view.testHook_centerRingStrokeAlpha,
            BreathingSeedOfLifeNSView.listeningCenterRingAlpha
                * BreathingSeedOfLifeNSView.quietColorFactor,
            accuracy: 0.02
        )
    }

    func testPauseFreezeKeepsFullColorAndHoldsAttachedMotion() {
        let view = makeView()

        view.update(animating: true, frozen: true, quiet: false)

        XCTAssertTrue(
            view.testHook_hasRotationAnimation,
            "Pause freezes the listening animation in place rather than removing it"
        )
        XCTAssertTrue(view.testHook_hasBreathingAnimation)
        XCTAssertEqual(
            view.testHook_flowerLayerSpeed,
            0,
            accuracy: 0.01,
            "Pause must stop the layer clock so the current frame holds"
        )
        XCTAssertFalse(view.testHook_isQuiet)
        XCTAssertEqual(
            view.testHook_centerRingStrokeAlpha,
            BreathingSeedOfLifeNSView.listeningCenterRingAlpha,
            accuracy: 0.02
        )
    }

    func testQuietOverridesAPreviousListeningAnimation() {
        let view = makeView()
        view.update(animating: true, frozen: false, quiet: false)
        XCTAssertTrue(view.testHook_hasRotationAnimation)
        XCTAssertTrue(view.testHook_hasBreathingAnimation)

        view.update(animating: true, frozen: false, quiet: true)

        XCTAssertFalse(view.testHook_hasRotationAnimation)
        XCTAssertFalse(view.testHook_hasBreathingAnimation)
        XCTAssertTrue(view.testHook_isQuiet)
        XCTAssertEqual(
            view.testHook_centerRingStrokeAlpha,
            BreathingSeedOfLifeNSView.listeningCenterRingAlpha
                * BreathingSeedOfLifeNSView.quietColorFactor,
            accuracy: 0.02
        )
    }

    func testPauseDoesNotRestoreMotionOrFullColorWhileQuiet() {
        let view = makeView()
        view.update(animating: true, frozen: false, quiet: true)

        view.update(animating: true, frozen: true, quiet: true)

        XCTAssertFalse(view.testHook_hasRotationAnimation)
        XCTAssertFalse(view.testHook_hasBreathingAnimation)
        XCTAssertTrue(view.testHook_isQuiet)
        XCTAssertEqual(
            view.testHook_centerRingStrokeAlpha,
            BreathingSeedOfLifeNSView.listeningCenterRingAlpha
                * BreathingSeedOfLifeNSView.quietColorFactor,
            accuracy: 0.02
        )
    }

    private func makeView() -> BreathingSeedOfLifeNSView {
        let view = BreathingSeedOfLifeNSView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: BreathingSeedOfLifeNSView.designSize,
                height: BreathingSeedOfLifeNSView.designSize
            )
        )
        view.layoutSubtreeIfNeeded()
        return view
    }
}
