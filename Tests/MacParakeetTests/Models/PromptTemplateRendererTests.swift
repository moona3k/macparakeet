import XCTest
@testable import MacParakeetCore

final class PromptTemplateRendererTests: XCTestCase {
    func testNoTokensReturnsTemplateUnchanged() {
        let template = "Just a sentence with no template tokens at all."
        XCTAssertEqual(
            PromptTemplateRenderer.render(template, substitutions: [.userNotes: "ignored"]),
            template
        )
    }

    func testSubstitutesUserNotesToken() {
        let rendered = PromptTemplateRenderer.render(
            "USER NOTES:\n{{userNotes}}\nEND",
            substitutions: [.userNotes: "buy milk\nfix the bug"]
        )
        XCTAssertEqual(rendered, "USER NOTES:\nbuy milk\nfix the bug\nEND")
    }

    func testSubstitutesTranscriptToken() {
        let rendered = PromptTemplateRenderer.render(
            "T:{{transcript}}",
            substitutions: [.transcript: "hello world"]
        )
        XCTAssertEqual(rendered, "T:hello world")
    }

    func testMissingKeyFallsBackToEmptyString() {
        // Template uses both variables; substitutions only supplies one.
        let rendered = PromptTemplateRenderer.render(
            "Notes: [{{userNotes}}] Transcript: [{{transcript}}]",
            substitutions: [.userNotes: "abc"]
        )
        XCTAssertEqual(rendered, "Notes: [abc] Transcript: []")
    }

    func testEmptyValueRendersEmpty() {
        let rendered = PromptTemplateRenderer.render(
            "before [{{userNotes}}] after",
            substitutions: [.userNotes: ""]
        )
        XCTAssertEqual(rendered, "before [] after")
    }

    func testUnknownVariableNameRendersEmpty() {
        // Typos like {{Usernotes}} (capital U) are not recognized — case-sensitive
        // canonical lowercase per ADR-020 §4. Unknown variables do NOT leave the
        // literal token in the output; they fall through to empty so a typo is a
        // visible bug rather than an invisible passthrough.
        let rendered = PromptTemplateRenderer.render(
            "[{{Usernotes}}]",
            substitutions: [.userNotes: "value"]
        )
        XCTAssertEqual(rendered, "[]")
    }

    func testSinglePassDoesNotInterpretValueAsTemplate() {
        // The killer test (ADR-020 §4): user pastes `{{transcript}}` literally
        // into their notes. The renderer must NOT, on a second pass, substitute
        // the literal `{{transcript}}` from inside the userNotes value with the
        // transcript text. The literal must survive unchanged.
        let userNotesContainingLiteral = "I noted: {{transcript}}"
        let rendered = PromptTemplateRenderer.render(
            "Notes:\n{{userNotes}}\nTranscript:\n{{transcript}}",
            substitutions: [
                .userNotes: userNotesContainingLiteral,
                .transcript: "REAL_TRANSCRIPT_TEXT"
            ]
        )
        XCTAssertEqual(
            rendered,
            "Notes:\nI noted: {{transcript}}\nTranscript:\nREAL_TRANSCRIPT_TEXT"
        )
        // Ensure the literal really survives — REAL_TRANSCRIPT_TEXT must appear
        // exactly once, not twice.
        let occurrences = rendered.components(separatedBy: "REAL_TRANSCRIPT_TEXT").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testSubstitutesEachOccurrence() {
        let rendered = PromptTemplateRenderer.render(
            "{{userNotes}} and again {{userNotes}}",
            substitutions: [.userNotes: "X"]
        )
        XCTAssertEqual(rendered, "X and again X")
    }

    func testUnterminatedOpeningTokenSurvivesLiterally() {
        // Defensive: a stray `{{` with no closing `}}` should not eat the rest
        // of the template. We emit the literal markers and continue scanning.
        let rendered = PromptTemplateRenderer.render(
            "before {{ never closes",
            substitutions: [.userNotes: "X"]
        )
        XCTAssertEqual(rendered, "before {{ never closes")
    }

    func testCaseSensitiveVariableNames() {
        // Both lowercase canonical names work.
        let lower = PromptTemplateRenderer.render(
            "{{userNotes}}|{{transcript}}",
            substitutions: [.userNotes: "a", .transcript: "b"]
        )
        XCTAssertEqual(lower, "a|b")

        // Unknown casings produce empty output (not the literal token).
        let mixed = PromptTemplateRenderer.render(
            "{{UserNotes}}|{{Transcript}}|{{USERNOTES}}",
            substitutions: [.userNotes: "a", .transcript: "b"]
        )
        XCTAssertEqual(mixed, "||")
    }

    /// Symmetric to `testSinglePassDoesNotInterpretValueAsTemplate`: ensures
    /// the single-pass invariant holds the OTHER direction too — a transcript
    /// value containing a literal `{{userNotes}}` token must NOT be re-
    /// interpreted on a second pass. Pinned by Codex fresh-eye review of PR
    /// #143 to prevent a silent regression to a naïve sequential renderer.
    func testTranscriptValueContainingUserNotesTokenIsNotReinterpreted() {
        let result = PromptTemplateRenderer.render(
            "T={{transcript}};U={{userNotes}}",
            substitutions: [
                .transcript: "[{{userNotes}}]",
                .userNotes: "SECRET",
            ]
        )
        XCTAssertEqual(
            result,
            "T=[{{userNotes}}];U=SECRET",
            "Substituted transcript value must not be re-scanned for further `{{...}}` tokens — the literal `{{userNotes}}` inside the transcript must survive verbatim."
        )
    }

    /// Partial / malformed markers must not be silently consumed. A single
    /// closing brace with no matching opener should appear verbatim in output.
    func testPartialClosingMarkerSurvivesLiterally() {
        let result = PromptTemplateRenderer.render(
            "before } after",
            substitutions: [.userNotes: "ignored"]
        )
        XCTAssertEqual(result, "before } after")
    }

    /// `}}` with no preceding `{{` must survive literally — the scanner
    /// only triggers on `{{` openings.
    func testStandaloneClosingMarkerSurvivesLiterally() {
        let result = PromptTemplateRenderer.render(
            "before }} after",
            substitutions: [.userNotes: "ignored"]
        )
        XCTAssertEqual(result, "before }} after")
    }

    /// Empty token `{{}}` resolves to the empty-string fallback (per the
    /// renderer's "unknown key → empty" contract). Pinned so a future change
    /// to "leave literal on empty key" doesn't slip through.
    func testEmptyTokenRendersAsEmptyString() {
        let result = PromptTemplateRenderer.render(
            "before{{}}after",
            substitutions: [.userNotes: "ignored"]
        )
        XCTAssertEqual(result, "beforeafter")
    }
}
