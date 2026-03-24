import SwiftUI

/// Block-level element parsed from a markdown string.
private enum MarkdownBlock {
    case heading(level: Int, content: String)
    case paragraph(content: String)
    case unorderedList(items: [String])
    case orderedList(items: [String])
    case codeBlock(language: String?, code: String)
    case blockquote(content: String)
    case thematicBreak
}

/// Renders markdown with full block-level support: headings, lists, code blocks, blockquotes.
/// Inline formatting (bold, italic, code, links, strikethrough) is handled within each block
/// via `AttributedString(markdown:)`.
struct MarkdownContentView: View {
    let content: String
    let baseFont: Font

    init(_ content: String, font: Font = DesignSystem.Typography.body) {
        self.content = content
        self.baseFont = font
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.parse(content).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inlineAttributedString(text))
                .font(headingFont(level: level))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .padding(.top, level <= 2 ? 4 : 2)

        case let .paragraph(text):
            Text(inlineAttributedString(text))
                .font(baseFont)
                .lineSpacing(4)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{2022}")
                            .font(baseFont)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                        Text(inlineAttributedString(item))
                            .font(baseFont)
                            .lineSpacing(3)
                    }
                }
            }
            .padding(.leading, 4)

        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).")
                            .font(baseFont)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                            .frame(minWidth: 20, alignment: .trailing)
                        Text(inlineAttributedString(item))
                            .font(baseFont)
                            .lineSpacing(3)
                    }
                }
            }
            .padding(.leading, 4)

        case let .codeBlock(_, code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(DesignSystem.Spacing.sm + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
            )

        case let .blockquote(text):
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(DesignSystem.Colors.accent.opacity(0.4))
                    .frame(width: 3)

                Text(inlineAttributedString(text))
                    .font(baseFont)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineSpacing(3)
                    .padding(.leading, 12)
            }

        case .thematicBreak:
            Divider().padding(.vertical, 2)
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return DesignSystem.Typography.pageTitle
        case 2: return DesignSystem.Typography.sectionTitle
        case 3: return .system(size: 15, weight: .semibold)
        default: return .system(size: 14, weight: .semibold)
        }
    }

    // MARK: - Inline Markdown

    private func inlineAttributedString(_ source: String) -> AttributedString {
        guard let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(source)
        }
        return attributed
    }

    // MARK: - Block Parser

    /// Parses a markdown string into block-level elements. Handles headings, lists,
    /// code blocks, blockquotes, thematic breaks, and paragraphs. Designed for
    /// structured LLM output — handles all common patterns without external dependencies.
    private static func parse(_ content: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line — skip
            if trimmed.isEmpty {
                index += 1
                continue
            }

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.codeBlock(
                    language: lang.isEmpty ? nil : lang,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            // Thematic break (---, ***, ___) — check before lists to avoid false positives
            if isThematicBreak(trimmed) {
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            // Heading
            if let heading = parseHeading(trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            // Unordered list
            if isUnorderedListItem(trimmed) {
                var items: [String] = []
                while index < lines.count {
                    let l = lines[index].trimmingCharacters(in: .whitespaces)
                    if isUnorderedListItem(l) {
                        items.append(String(l.dropFirst(2)))
                        index += 1
                    } else if l.isEmpty {
                        break
                    } else {
                        // Continuation line — append to current item
                        if !items.isEmpty {
                            items[items.count - 1] += " " + l
                        }
                        index += 1
                    }
                }
                blocks.append(.unorderedList(items: items))
                continue
            }

            // Ordered list
            if isOrderedListItem(trimmed) {
                var items: [String] = []
                while index < lines.count {
                    let l = lines[index].trimmingCharacters(in: .whitespaces)
                    if isOrderedListItem(l) {
                        items.append(stripOrderedMarker(l))
                        index += 1
                    } else if l.isEmpty {
                        break
                    } else {
                        if !items.isEmpty {
                            items[items.count - 1] += " " + l
                        }
                        index += 1
                    }
                }
                blocks.append(.orderedList(items: items))
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let l = lines[index].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    let dropCount = l.hasPrefix("> ") ? 2 : 1
                    quoteLines.append(String(l.dropFirst(dropCount)))
                    index += 1
                }
                blocks.append(.blockquote(content: quoteLines.joined(separator: "\n")))
                continue
            }

            // Paragraph — collect lines until next block element or blank line
            var paraLines: [String] = []
            while index < lines.count {
                let t = lines[index].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("```") || isThematicBreak(t) ||
                   parseHeading(t) != nil || isUnorderedListItem(t) ||
                   isOrderedListItem(t) || t.hasPrefix(">") {
                    break
                }
                paraLines.append(t)
                index += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(content: paraLines.joined(separator: " ")))
            }
        }

        return blocks
    }

    // MARK: - Parser Helpers

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        for char in line {
            if char == "#" { level += 1 }
            else { break }
        }
        guard level >= 1, level <= 6,
              line.count > level,
              line[line.index(line.startIndex, offsetBy: level)] == " " else {
            return nil
        }
        return .heading(level: level, content: String(line.dropFirst(level + 1)))
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        return stripped.count >= 3 && (
            stripped.allSatisfy { $0 == "-" } ||
            stripped.allSatisfy { $0 == "*" } ||
            stripped.allSatisfy { $0 == "_" }
        )
    }

    private static func isUnorderedListItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func isOrderedListItem(_ line: String) -> Bool {
        guard let dotIndex = line.firstIndex(of: ".") else { return false }
        let prefix = line[line.startIndex..<dotIndex]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isWholeNumber) else { return false }
        let afterDot = line.index(after: dotIndex)
        return afterDot < line.endIndex && line[afterDot] == " "
    }

    private static func stripOrderedMarker(_ line: String) -> String {
        guard let dotIndex = line.firstIndex(of: "."),
              line.index(after: dotIndex) < line.endIndex else { return line }
        return String(line[line.index(dotIndex, offsetBy: 2)...])
    }
}
