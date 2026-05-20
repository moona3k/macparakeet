import Foundation

enum MenuPreviewFormatter {
    private static let dictationPreviewLength = 40
    private static let transformPreviewLength = 48

    static func dictationTitle(text: String) -> String {
        preview(text, maxLength: dictationPreviewLength, stripMarkdownPresentation: false)
    }

    static func transformTitle(outputText: String) -> String {
        let outputPreview = preview(
            outputText,
            maxLength: transformPreviewLength,
            stripMarkdownPresentation: true
        )

        return outputPreview.isEmpty ? "Transform result" : outputPreview
    }

    private static func preview(
        _ text: String,
        maxLength: Int,
        stripMarkdownPresentation: Bool
    ) -> String {
        var value = collapseWhitespace(text)
        if stripMarkdownPresentation {
            value = plainTextMarkdownPreview(value)
        }
        return truncate(value, maxLength: maxLength)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plainTextMarkdownPreview(_ text: String) -> String {
        var value = stripLeadingMarkdownMarkers(text)
        for (target, replacement) in [
            ("`", ""),
            ("**", ""),
            ("__", ""),
            ("*", "")
        ] {
            value = value.replacingOccurrences(of: target, with: replacement)
        }
        return stripLeadingMarkdownMarkers(collapseWhitespace(value))
    }

    private static func stripLeadingMarkdownMarkers(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var didStrip = true

        while didStrip {
            didStrip = false

            while value.hasPrefix("#") {
                value.removeFirst()
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                didStrip = true
            }

            for marker in [">", "•", "-", "+", "*"] where value.hasPrefix(marker + " ") {
                value.removeFirst()
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                didStrip = true
                break
            }

            if let markerEnd = orderedListMarkerEnd(in: value) {
                value = String(value[markerEnd...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                didStrip = true
            }
        }

        return value
    }

    private static func orderedListMarkerEnd(in text: String) -> String.Index? {
        var index = text.startIndex
        var sawDigit = false

        while index < text.endIndex, text[index].isNumber {
            sawDigit = true
            index = text.index(after: index)
        }

        guard sawDigit,
              index < text.endIndex,
              text[index] == "." || text[index] == ")" else {
            return nil
        }

        let markerEnd = text.index(after: index)
        guard markerEnd < text.endIndex, text[markerEnd] == " " else {
            return nil
        }

        return text.index(after: markerEnd)
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        guard text.count > maxLength else { return text }
        return String(text.prefix(max(0, maxLength - 1))) + "…"
    }
}
