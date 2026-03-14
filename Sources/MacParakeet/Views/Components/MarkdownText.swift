import SwiftUI

/// A view that renders a markdown string as styled SwiftUI Text.
/// Uses `AttributedString(markdown:)` to parse bold, italic, code, links, etc.
/// Falls back to plain text if parsing fails.
struct MarkdownText: View {
    let content: String
    let font: Font

    init(_ content: String, font: Font = DesignSystem.Typography.body) {
        self.content = content
        self.font = font
    }

    var body: some View {
        Text(attributedContent)
            .font(font)
            .textSelection(.enabled)
            .lineSpacing(4)
    }

    private var attributedContent: AttributedString {
        // AttributedString(markdown:) handles: **bold**, *italic*, `code`, [links](url),
        // ~~strikethrough~~, and inline elements. Block elements (headers, lists) are
        // rendered as styled inline text — good enough for LLM output in a ScrollView.
        guard let attributed = try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(content)
        }
        return attributed
    }
}
