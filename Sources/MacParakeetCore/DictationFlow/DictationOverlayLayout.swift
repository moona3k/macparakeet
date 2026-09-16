import Foundation

/// Screen-edge placement for the idle dictation pill and the live overlay.
/// Both surfaces share this so the recording UI appears where the idle nub sat.
public enum DictationOverlayPlacement: String, CaseIterable, Hashable, Sendable {
    case bottomCenter
    case bottomLeft
    case bottomRight
    case topCenter
    case topLeft
    case topRight

    public var displayTitle: String {
        switch self {
        case .bottomCenter: return "Bottom center"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .topCenter: return "Top center"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        }
    }

    public var anchorsToTop: Bool {
        switch self {
        case .topLeft, .topCenter, .topRight: return true
        case .bottomLeft, .bottomCenter, .bottomRight: return false
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> DictationOverlayPlacement {
        guard let raw = defaults.string(forKey: UserDefaultsAppRuntimePreferences.dictationOverlayPlacementKey),
            let placement = DictationOverlayPlacement(rawValue: raw)
        else {
            return .bottomCenter
        }
        return placement
    }
}

/// Geometry for parking a dictation panel inside `NSScreen.visibleFrame`.
public enum DictationOverlayLayout {
    public static let margin: CGFloat = 12

    public static func origin(
        in visibleFrame: CGRect,
        panelSize: CGSize,
        placement: DictationOverlayPlacement,
        margin: CGFloat = margin
    ) -> CGPoint {
        let minX = visibleFrame.minX
        let maxX = visibleFrame.maxX - panelSize.width
        let minY = visibleFrame.minY
        let maxY = visibleFrame.maxY - panelSize.height

        let unclampedX: CGFloat
        switch placement {
        case .bottomLeft, .topLeft:
            unclampedX = visibleFrame.minX + margin
        case .bottomCenter, .topCenter:
            unclampedX = visibleFrame.midX - panelSize.width / 2
        case .bottomRight, .topRight:
            unclampedX = visibleFrame.maxX - panelSize.width - margin
        }

        let unclampedY: CGFloat
        if placement.anchorsToTop {
            unclampedY = visibleFrame.maxY - panelSize.height - margin
        } else {
            unclampedY = visibleFrame.minY + margin
        }

        return CGPoint(
            x: clamped(unclampedX, lower: minX, upper: max(minX, maxX)),
            y: clamped(unclampedY, lower: minY, upper: max(minY, maxY))
        )
    }

    private static func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
