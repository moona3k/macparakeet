import XCTest
@testable import MacParakeet
@testable import MacParakeetViewModels

@MainActor
final class OnboardingHotkeyPreviewControllerTests: XCTestCase {

    // MARK: - Fakes

    private final class SpyOverlayController: DictationOverlayControlling {
        let viewModel: DictationOverlayViewModel
        private(set) var showCount = 0
        private(set) var hideCount = 0
        var isShown: Bool { showCount > hideCount }

        init(viewModel: DictationOverlayViewModel) {
            self.viewModel = viewModel
        }

        func show() { showCount += 1 }
        func hide() { hideCount += 1 }
        func resignKeyWindow() {}
    }

    private final class FakeMicLeveling: OnboardingHotkeyPreviewController.MicLeveling {
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private var onLevel: (@MainActor (Float) -> Void)?

        func start(onLevel: @escaping @MainActor (Float) -> Void) {
            startCount += 1
            self.onLevel = onLevel
        }

        func stop() {
            stopCount += 1
            onLevel = nil
        }

        /// Drive a level as if a mic buffer arrived.
        func emit(_ level: Float) { onLevel?(level) }
    }

    /// Builds a controller wired to fakes with an empty hotkey plan so no real
    /// CGEvent taps are created during the test.
    private func makeHarness() -> (OnboardingHotkeyPreviewController, FakeMicLeveling, Box) {
        let leveling = FakeMicLeveling()
        let box = Box()
        let controller = OnboardingHotkeyPreviewController(
            planProvider: { .init(specs: [], conflict: nil) },
            micLevelingProvider: { leveling },
            overlayFactory: { vm in
                let spy = SpyOverlayController(viewModel: vm)
                box.lastOverlay = spy
                return spy
            },
            suspendProductionHotkeys: { box.suspendCount += 1 },
            resumeProductionHotkeys: { box.resumeCount += 1 }
        )
        return (controller, leveling, box)
    }

    /// Mutable capture box (the factory/closures need shared mutable state).
    private final class Box {
        var lastOverlay: SpyOverlayController?
        var suspendCount = 0
        var resumeCount = 0
    }

    // MARK: - Tests

    func testArmSuspendsAndDisarmResumesBalanced() {
        let (controller, _, box) = makeHarness()

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
        let (controller, _, box) = makeHarness()

        controller.arm()
        controller.arm()
        XCTAssertEqual(box.suspendCount, 1, "Second arm() must not re-suspend")

        controller.disarm()
        controller.disarm()
        XCTAssertEqual(box.resumeCount, 1, "Second disarm() must not re-resume")
    }

    func testBeginPreviewShowsOverlayAndStartsMic() {
        let (controller, leveling, box) = makeHarness()
        controller.arm()

        controller.beginPreview(mode: .holdToTalk)

        XCTAssertTrue(controller.isPreviewing)
        XCTAssertEqual(box.lastOverlay?.showCount, 1)
        XCTAssertEqual(box.lastOverlay?.isShown, true)
        XCTAssertEqual(box.lastOverlay?.viewModel.recordingMode, .holdToTalk)
        if case .recording = box.lastOverlay?.viewModel.state {} else {
            XCTFail("Overlay should be in .recording state")
        }
        XCTAssertEqual(leveling.startCount, 1)
    }

    func testEndPreviewHidesOverlayAndStopsMic() {
        let (controller, leveling, box) = makeHarness()
        controller.arm()
        controller.beginPreview(mode: .persistent)

        controller.endPreview()

        XCTAssertFalse(controller.isPreviewing)
        XCTAssertEqual(box.lastOverlay?.isShown, false)
        XCTAssertEqual(box.lastOverlay?.hideCount, 1)
        XCTAssertEqual(leveling.stopCount, 1)
    }

    func testMicLevelUpdatesOverlayAudioLevel() {
        let (controller, leveling, box) = makeHarness()
        controller.arm()
        controller.beginPreview(mode: .holdToTalk)

        leveling.emit(0.42)

        XCTAssertEqual(box.lastOverlay?.viewModel.audioLevel, 0.42)
    }

    func testDisarmWhilePreviewingTearsDownAndResumes() {
        let (controller, leveling, box) = makeHarness()
        controller.arm()
        controller.beginPreview(mode: .persistent)

        controller.disarm()

        XCTAssertFalse(controller.isArmed)
        XCTAssertFalse(controller.isPreviewing)
        XCTAssertEqual(box.lastOverlay?.isShown, false, "Overlay must be hidden on disarm")
        XCTAssertEqual(leveling.stopCount, 1, "Mic must be released on disarm")
        XCTAssertEqual(box.resumeCount, 1, "Production hotkeys must be resumed exactly once")
    }

    func testBeginPreviewWithoutArmIsNoOp() {
        let (controller, leveling, box) = makeHarness()

        controller.beginPreview(mode: .holdToTalk)

        XCTAssertFalse(controller.isPreviewing)
        XCTAssertNil(box.lastOverlay)
        XCTAssertEqual(leveling.startCount, 0)
    }

    func testSecondBeginPreviewWhileActiveIsNoOp() {
        let (controller, leveling, _) = makeHarness()
        controller.arm()
        controller.beginPreview(mode: .holdToTalk)
        controller.beginPreview(mode: .persistent)

        XCTAssertEqual(leveling.startCount, 1, "Re-entrant beginPreview must not restart the mic")
    }
}
