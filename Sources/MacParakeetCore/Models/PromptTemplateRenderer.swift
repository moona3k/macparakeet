import Foundation

/// Single-pass simultaneous template substitution for prompt content.
///
/// Replaces `{{key}}` tokens in a prompt with the corresponding values from
/// the supplied substitutions dictionary. Substitution is single-pass: all
/// replacements are computed against the original text and applied atomically
/// in one scan. User-supplied values that themselves contain `{{...}}` tokens
/// are NOT interpreted as templates in a later pass — this eliminates an
/// injection vector where pasted content could smuggle other variables into
/// the prompt.
///
/// Variable names are case-sensitive; canonical casing is lowercase
/// (`{{userNotes}}`, `{{transcript}}`). Unknown keys fall through to an
/// empty-string substitution rather than leaving the literal `{{...}}` token
/// in the rendered output.
///
/// See ADR-020 §4.
public enum PromptTemplateRenderer {
    public enum Variable: String, CaseIterable, Sendable {
        case userNotes
        case transcript
    }

    /// Render `template`, replacing every recognized `{{key}}` token with the
    /// value supplied for that key. Tokens whose key is not present in
    /// `substitutions` are replaced with the empty string.
    public static func render(
        _ template: String,
        substitutions: [Variable: String]
    ) -> String {
        guard template.contains("{{") else { return template }

        var output = ""
        output.reserveCapacity(template.count)

        var index = template.startIndex
        let end = template.endIndex
        let openMarker = "{{"
        let closeMarker = "}}"

        while index < end {
            guard let openRange = template.range(of: openMarker, range: index..<end) else {
                output.append(contentsOf: template[index..<end])
                break
            }

            // Append literal text up to the opening marker.
            output.append(contentsOf: template[index..<openRange.lowerBound])

            let afterOpen = openRange.upperBound
            guard let closeRange = template.range(of: closeMarker, range: afterOpen..<end) else {
                // Unterminated `{{` — emit the marker literally and keep scanning past it.
                output.append(contentsOf: template[openRange])
                index = openRange.upperBound
                continue
            }

            let key = String(template[afterOpen..<closeRange.lowerBound])
            if let variable = Variable(rawValue: key) {
                output.append(substitutions[variable] ?? "")
            } else {
                // Unknown variable → empty-string fallback (per ADR §4).
                // Typos like `{{Usernotes}}` produce empty rather than the literal token.
            }

            index = closeRange.upperBound
        }

        return output
    }
}
