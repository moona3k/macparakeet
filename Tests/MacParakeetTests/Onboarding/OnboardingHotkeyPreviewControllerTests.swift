import XCTest
@testable import MacParakeet
@testable import MacParakeetViewModels

@MainActor
final class OnboardingHotkeyPreviewControllerTests: XCTestCase {

    /// Mutable capture box (the closures need shared mutable state).
    private final class Box {
        var suspendCount = 0
        var resumeCount = 0
        var planRequests = 0
        var keyStates: [OnboardingViewModel.PracticeKey?] = []
    }

    /// Builds a controller with an empty hotkey plan so no real CGEvent taps
    /// are created during the test.
    private func makeHarness() -> (OnboardingHotkeyPreviewController, Box) {
        let box = Box()
        let controller = OnboardingHotkeyPreviewController(
            planProvider: {
                box.planRequests += 1
                return .init(specs: [], conflict: nil)
            },
            suspendProductionHotkeys: { box.suspendCount += 1 },
            resumeProductionHotkeys: { box.resumeCount += 1 }
        )
        controller.onKeyStateChanged = { box.keyStates.append($0) }
        return (controller, box)
    }

    func testArmSuspendsAndDisarmResumesBalanced() {
        let (controller, box) = makeHarness()

        controller.arm()
        XCTAssertTrue(controller.isArmed)
        XCTAssertEqual(box.suspendCount, 1)
        XCTAssertEqual(box.resumeCount, 0)

        controller.disarm()
        XCTAssertFalse(controller.isArmed)
        XCTAssertEqual(box.suspendCount, 1)
        XCTAssertEqual(box.resumeCount, 1)
    }

    func testDoubleArmAndDisarmAreIdempotent() {
        let (controller, box) = makeHarness()

        controller.arm()
        controller.arm()
        XCTAssertEqual(box.suspendCount, 1, "Second arm() must not re-suspend")

        controller.disarm()
        controller.disarm()
        XCTAssertEqual(box.resumeCount, 1, "Second disarm() must not re-resume")
    }

    func testHoldLightsPushToTalkKeyAndReleaseReturnsItToRest() {
        let (controller, box) = makeHarness()
        controller.arm()

        controller.keyDidActivate(mode: .holdToTalk)
        XCTAssertEqual(controller.litKey, .pushToTalk)

        controller.keyDidRest()
        XCTAssertNil(controller.litKey)
        XCTAssertEqual(box.keyStates, [.pushToTalk, nil])
    }

    func testHandsFreeGestureLightsHandsFreeKey() {
        let (controller, box) = makeHarness()
        controller.arm()

        controller.keyDidActivate(mode: .persistent)
        XCTAssertEqual(controller.litKey, .handsFree)
        XCTAssertEqual(box.keyStates, [.handsFree])
    }

    func testActivationWhileDisarmedDoesNotLight() {
        let (controller, box) = makeHarness()

        controller.keyDidActivate(mode: .holdToTalk)

        XCTAssertNil(controller.litKey)
        XCTAssertTrue(box.keyStates.isEmpty)
    }

    func testDisarmWhileLitReturnsKeyToRestAndResumesOnce() {
        let (controller, box) = makeHarness()
        controller.arm()
        controller.keyDidActivate(mode: .holdToTalk)

        controller.disarm()

        XCTAssertNil(controller.litKey)
        XCTAssertEqual(box.keyStates.last, .some(nil), "The card must not keep a lit key after disarm")
        XCTAssertEqual(box.resumeCount, 1, "Production hotkeys must be resumed exactly once")
    }

    func testCapturePauseKeepsProductionSuspendedAndRebuildsFromPlan() {
        let (controller, box) = makeHarness()
        controller.arm()
        XCTAssertEqual(box.planRequests, 1)

        controller.setCapturePaused(true)
        controller.keyDidActivate(mode: .holdToTalk)
        XCTAssertNil(controller.litKey, "A recorder owns the keyboard while paused")
        XCTAssertEqual(box.resumeCount, 0, "Pausing must not hand the key back to production")

        controller.setCapturePaused(false)
        XCTAssertEqual(box.planRequests, 2, "Unpausing rebuilds taps from the current binding")
        XCTAssertTrue(controller.isArmed)
    }

    func testArmWhilePausedWaitsForUnpauseToBuildTaps() {
        let (controller, box) = makeHarness()
        controller.setCapturePaused(true)

        controller.arm()
        XCTAssertEqual(box.planRequests, 0)
        XCTAssertEqual(box.suspendCount, 1)

        controller.setCapturePaused(false)
        XCTAssertEqual(box.planRequests, 1)
    }

    func testRefreshBindingsRebuildsOnlyWhenArmedAndNotPaused() {
        let (controller, box) = makeHarness()

        controller.refreshBindings()
        XCTAssertEqual(box.planRequests, 0)

        controller.arm()
        controller.refreshBindings()
        XCTAssertEqual(box.planRequests, 2)

        controller.setCapturePaused(true)
        controller.refreshBindings()
        XCTAssertEqual(box.planRequests, 2)
    }
}
