import Foundation

/// Screen edge for the idle dictation pill and the live overlay. Both surfaces
/// share it so recording starts exactly where the idle nub sat.
public enum DictationOverlayPlacement: String, CaseIterable, Hashable, Sendable {
    case bottom
    case top

    public var displayTitle: String {
        switch self {
        case .bottom: return "Bottom"
        case .top: return "Top"
        }
    }

    public var anchorsToTop: Bool { self == .top }

    public static func current(defaults: UserDefaults = .standard) -> DictationOverlayPlacement {
        guard let raw = defaults.string(forKey: UserDefaultsAppRuntimePreferences.dictationOverlayPlacementKey),
            let placement = DictationOverlayPlacement(rawValue: raw)
        else {
            return .bottom
        }
        return placement
    }
}

/// Geometry for parking a dictation panel centered on the chosen screen edge.
public enum DictationOverlayLayout {
    public static let margin: CGFloat = 12

    /// The region a dictation panel may occupy. `visibleFrame` already clears
    /// the Dock and a shown menu bar, but it reaches the top edge when the menu
    /// bar auto-hides or an app is full screen. The menu bar (or notch) then
    /// slides over a top-anchored pill, so the top always reserves that height.
    public static func usableFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        topInset: CGFloat
    ) -> CGRect {
        let maxY = min(visibleFrame.maxY, screenFrame.maxY - topInset)
        return CGRect(
            x: visibleFrame.minX,
            y: visibleFrame.minY,
            width: visibleFrame.width,
            height: max(0, maxY - visibleFrame.minY)
        )
    }

    public static func origin(
        in usableFrame: CGRect,
        panelSize: CGSize,
        placement: DictationOverlayPlacement,
        margin: CGFloat = margin
    ) -> CGPoint {
        let x = usableFrame.midX - panelSize.width / 2
        let y: CGFloat
        switch placement {
        case .bottom:
            y = usableFrame.minY + margin
        case .top:
            y = max(usableFrame.minY, usableFrame.maxY - panelSize.height - margin)
        }
        return CGPoint(x: x, y: y)
    }
}
