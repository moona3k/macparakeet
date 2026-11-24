import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class IdlePillViewModel {
    public var isHovered: Bool = false
    public var placement: DictationOverlayPlacement = .bottom
    public var anchorsToTop: Bool { placement.anchorsToTop }
    public var onStartDictation: (() -> Void)?

    public init() {}
}
