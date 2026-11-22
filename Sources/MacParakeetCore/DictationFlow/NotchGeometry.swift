import CoreGraphics
import Foundation

/// What a display's top-centre camera cutout looks like. Built from the
/// `NSScreen` values Apple documents for the notch (`safeAreaInsets.top`,
/// `auxiliaryTopLeftArea`, `auxiliaryTopRightArea`); no third-party library.
public enum DisplayCutout: Equatable, Sendable {
    /// No camera housing: an external display, an older Mac, or a non-notched Air.
    case none
    /// A notch wide enough to merge a panel with.
    case notch(NotchGeometry)
    /// A cutout too narrow to be a notch (a camera hole such as the Dynamic
    /// Island hardware). We never draw over it.
    case narrowCutout

    /// A real notch is about 180-200 pt wide. Anything under this is a camera
    /// hole / island, not a notch.
    public static let minimumNotchWidth: CGFloat = 120

    public static func classify(
        frame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?,
        isBuiltIn: Bool
    ) -> DisplayCutout {
        guard isBuiltIn, safeAreaTop > 0,
            let left = auxiliaryTopLeft, let right = auxiliaryTopRight,
            !left.isEmpty, !right.isEmpty
        else { return .none }
        let width = right.minX - left.maxX
        guard width > 0 else { return .none }
        guard width >= minimumNotchWidth else { return .narrowCutout }
        let rect = CGRect(x: left.maxX, y: frame.maxY - safeAreaTop, width: width, height: safeAreaTop)
        return .notch(
            NotchGeometry(
                screenFrame: frame,
                notchRect: rect,
                leftAuxiliaryWidth: left.width,
                rightAuxiliaryWidth: right.width
            )
        )
    }
}

/// Pure geometry for a panel merged with the camera notch. Every member is
/// O(1); recompute only when screen parameters change, never per frame.
public struct NotchGeometry: Equatable, Sendable {
    /// Most a panel may extend beyond the notch on each side, so menu titles and
    /// status items stay reachable. Tuned in QA.
    public static let maxSideExtension: CGFloat = 120

    public let screenFrame: CGRect
    /// The camera housing in global screen coordinates (top flush with the screen).
    public let notchRect: CGRect
    public let leftAuxiliaryWidth: CGFloat
    public let rightAuxiliaryWidth: CGFloat

    public init(
        screenFrame: CGRect,
        notchRect: CGRect,
        leftAuxiliaryWidth: CGFloat,
        rightAuxiliaryWidth: CGFloat
    ) {
        self.screenFrame = screenFrame
        self.notchRect = notchRect
        self.leftAuxiliaryWidth = leftAuxiliaryWidth
        self.rightAuxiliaryWidth = rightAuxiliaryWidth
    }

    /// Per-side growth limit: the cap, further bounded by the real room beside the notch.
    public var sideExtensionLimit: CGFloat {
        max(0, min(Self.maxSideExtension, leftAuxiliaryWidth, rightAuxiliaryWidth))
    }

    public var maxExpandedWidth: CGFloat { notchRect.width + 2 * sideExtensionLimit }

    /// Width clamped to [notch width, `maxExpandedWidth`].
    public func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, notchRect.width), maxExpandedWidth)
    }

    /// Panel frame centred on the notch with its top flush to the screen top.
    /// `height` is raised to at least the notch height.
    public func panelFrame(expandedWidth: CGFloat, height: CGFloat) -> CGRect {
        let w = clampedWidth(expandedWidth)
        let h = max(height, notchRect.height)
        return CGRect(x: notchRect.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
    }
}

/// Where the dictation indicator is drawn.
public enum OverlaySurface: Equatable, Sendable {
    /// Black panel merged with the notch of display `displayID`.
    case notchPanel(displayID: UInt32, geometry: NotchGeometry)
    /// The classic edge pill. `displayID` is the display to use (nil = menu-bar/main screen).
    case edgePanel(placement: DictationOverlayPlacement, displayID: UInt32?)
}

/// A display as the resolver sees it; constructed from `NSScreen` in the app target.
public struct OverlayDisplay: Equatable, Sendable {
    public let id: UInt32
    public let cutout: DisplayCutout
    public init(id: UInt32, cutout: DisplayCutout) {
        self.id = id
        self.cutout = cutout
    }
}

/// Pure placement -> surface decision, unit-testable without screens.
public enum OverlaySurfaceResolver {
    /// - Parameters:
    ///   - displays: all attached, active displays.
    ///   - menuBarDisplayID: the display carrying the menu bar (`NSScreen.screens.first`).
    ///
    /// `.bottom` / `.top` always resolve to the edge panel. `.notch` resolves to
    /// the notch panel only when the menu-bar display has a real notch; every
    /// other case (clamshell, external menu-bar display, no notch, Dynamic
    /// Island hardware) falls back to `.top`. Auto-hide does not matter: the
    /// notch is physical.
    public static func resolve(
        placement: DictationOverlayPlacement,
        displays: [OverlayDisplay],
        menuBarDisplayID: UInt32?
    ) -> OverlaySurface {
        guard placement == .notch else {
            return .edgePanel(placement: placement, displayID: menuBarDisplayID)
        }
        if let id = menuBarDisplayID,
            let display = displays.first(where: { $0.id == id }),
            case .notch(let geometry) = display.cutout
        {
            return .notchPanel(displayID: id, geometry: geometry)
        }
        return .edgePanel(placement: .top, displayID: menuBarDisplayID)
    }

    /// True when Settings should offer "Around the notch".
    public static func offersNotch(displays: [OverlayDisplay]) -> Bool {
        displays.contains { if case .notch = $0.cutout { return true } else { return false } }
    }
}
