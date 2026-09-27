import Foundation

/// Separates a growing answer from the reader moving back through the conversation.
struct AskScrollFollowState {
    private(set) var followsLatest = true
    private var previous: CGRect?

    mutating func update(content: CGRect, viewportHeight: CGFloat) -> Bool {
        guard viewportHeight > 0, content.height > 0 else { return false }
        defer { previous = content }
        let isAtBottom = content.maxY <= viewportHeight + 40
        if let previous {
            let movement = content.minY - previous.minY
            if movement > 1, content.height >= previous.height - 1 {
                // Even a small upward gesture belongs to the reader. Do not snap
                // back merely because they are still within the bottom threshold.
                followsLatest = false
            } else if movement < -1, isAtBottom {
                followsLatest = true
            }
        }
        return followsLatest && content.maxY > viewportHeight + 1
    }

    mutating func pause() { followsLatest = false }

    mutating func resume() { followsLatest = true; previous = nil }
}
