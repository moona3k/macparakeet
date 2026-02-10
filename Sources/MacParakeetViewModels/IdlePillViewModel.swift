import Foundation

@MainActor
@Observable
public final class IdlePillViewModel {
    public var isHovered: Bool = false
    public var onStartDictation: (() -> Void)?

    public init() {}
}
