import Foundation

/// Screen edge for the idle dictation pill and the live overlay. Both surfaces
/// share it so recording starts exactly where the idle nub sat.
public enum DictationOverlayPlacement: String, CaseIterable, Hashable, Sendable {
    case bottom
    case top
    case left
    case right

    public var displayTitle: String {
        switch self {
        case .bottom: return "Bottom"
        case .top: return "Top"
        case .left: return "Left"
        case .right: return "Right"
        }
    }

    public var anchorsToTop: Bool { self == .top }

    /// Left and Right run the pill along the edge, top to bottom.
    public var isVertical: Bool { self == .left || self == .right }

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
/// Rects and points use AppKit panel coordinates (origin bottom-left, y-up).
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
        switch placement {
        case .bottom:
            return CGPoint(x: usableFrame.midX - panelSize.width / 2, y: usableFrame.minY + margin)
        case .top:
            return CGPoint(
                x: usableFrame.midX - panelSize.width / 2,
                y: max(usableFrame.minY, usableFrame.maxY - panelSize.height - margin)
            )
        case .left:
            return CGPoint(x: usableFrame.minX + margin, y: usableFrame.midY - panelSize.height / 2)
        case .right:
            return CGPoint(
                x: max(usableFrame.minX, usableFrame.maxX - panelSize.width - margin),
                y: usableFrame.midY - panelSize.height / 2
            )
        }
    }

    /// A rect that hugs the anchored edge of the panel, centered along it.
    /// `length` runs along the edge; `depth` reaches in from the edge.
    public static func edgeRect(
        length: CGFloat,
        depth: CGFloat,
        panelSize: CGSize,
        placement: DictationOverlayPlacement
    ) -> CGRect {
        switch placement {
        case .bottom:
            return CGRect(x: (panelSize.width - length) / 2, y: 0, width: length, height: depth)
        case .top:
            return CGRect(
                x: (panelSize.width - length) / 2,
                y: panelSize.height - depth,
                width: length,
                height: depth
            )
        case .left:
            return CGRect(x: 0, y: (panelSize.height - length) / 2, width: depth, height: length)
        case .right:
            return CGRect(
                x: panelSize.width - depth,
                y: (panelSize.height - length) / 2,
                width: depth,
                height: length
            )
        }
    }

    /// Distance of `point` from the pill's leading end (left on Bottom/Top,
    /// top on Left/Right), measured along a pill of `pillLength` that is
    /// centered on the anchored edge.
    public static func distanceAlongPill(
        from point: CGPoint,
        pillLength: CGFloat,
        panelSize: CGSize,
        placement: DictationOverlayPlacement
    ) -> CGFloat {
        if placement.isVertical {
            return (panelSize.height + pillLength) / 2 - point.y
        }
        return point.x - (panelSize.width - pillLength) / 2
    }
}
