import XCTest
@testable import MacParakeet

@MainActor
final class BreathingSeedOfLifeViewTests: XCTestCase {
    func testListeningStateRotatesAtFullCoral() {
        let view = makeView()

        view.update(animating: true, frozen: false, quiet: false)

        XCTAssertTrue(view.testHook_hasRotationAnimation)
        XCTAssertFalse(view.testHook_isQuiet)
        XCTAssertEqual(
            view.testHook_centerRingStrokeAlpha,
            BreathingSeedOfLifeNSView.listeningCenterRingAlpha,
            accuracy: 0.02
        )
    }

    func testQuietStateStopsRotationAndFadesCoral() {
        let view = makeView()

        view.update(animating: false, frozen: false, quiet: true)

        XCTAssertFalse(view.testHook_hasRotationAnimation)
        XCTAssertTrue(view.testHook_isQuiet)
        XCTAssertEqual(
            view.testHook_centerRingStrokeAlpha,
            BreathingSeedOfLifeNSView.listeningCenterRingAlpha
                * BreathingSeedOfLifeNSView.quietColorFactor,
            accuracy: 0.02
        )
    }

    func testPauseFreezeKeepsFullColorAndAttachedRotation() {
        let view = makeView()

        view.update(animating: true, frozen: true, quiet: false)

        XCTAssertTrue(
            view.testHook_hasRotationAnimation,
            "Pause freezes the listening animation in place rather than removing it"
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

        view.update(animating: false, frozen: false, quiet: true)

        XCTAssertFalse(view.testHook_hasRotationAnimation)
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
