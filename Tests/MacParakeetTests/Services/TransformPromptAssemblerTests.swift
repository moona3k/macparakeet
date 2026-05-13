import XCTest
@testable import MacParakeetCore

final class TransformPromptAssemblerTests: XCTestCase {
    func testAssembleIncludesEnabledRulesAndCustomInstructions() {
        let polish = Prompt.builtInPrompts().first(where: { $0.name == "Polish" })!
        var profile = TransformProfile.defaultProfile(for: polish)
        profile.setEnabledRuleIDs(["polish.concise", "polish.tone"])
        profile.customInstructions = "Keep contractions and do not add exclamation points."

        let assembled = TransformPromptAssembler.assemble(
            prompt: polish,
            profile: profile,
            writingSamples: []
        )

        XCTAssertTrue(assembled.contains(polish.content))
        XCTAssertTrue(assembled.contains("Make the output more concise"))
        XCTAssertTrue(assembled.contains("Preserve the author's register"))
        XCTAssertFalse(assembled.contains("Reword unclear phrases"))
        XCTAssertTrue(assembled.contains("Keep contractions and do not add exclamation points."))
        XCTAssertTrue(assembled.hasSuffix("Return only the transformed text."))
    }

    func testAssembleUsesWritingSamplesOnlyWhenEnabled() {
        let prompt = Prompt(name: "Custom", content: "Rewrite the selected text.", category: .transform)
        let sample = WritingSample(title: "Email", text: "This is how I write in email.")

        var disabled = TransformProfile.defaultProfile(for: prompt)
        disabled.useWritingSamples = false
        XCTAssertFalse(
            TransformPromptAssembler
                .assemble(prompt: prompt, profile: disabled, writingSamples: [sample])
                .contains("Voice reference samples")
        )

        var enabled = disabled
        enabled.useWritingSamples = true
        let assembled = TransformPromptAssembler.assemble(
            prompt: prompt,
            profile: enabled,
            writingSamples: [sample]
        )

        XCTAssertTrue(assembled.contains("Voice reference samples"))
        XCTAssertTrue(assembled.contains("Sample 1 - Email:"))
        XCTAssertTrue(assembled.contains("Email"))
        XCTAssertTrue(assembled.contains("This is how I write in email."))
        XCTAssertFalse(assembled.contains("SQL(elements"))
    }

    func testAssembleLimitsWritingSamples() {
        let prompt = Prompt(name: "Custom", content: "Rewrite.", category: .transform)
        var profile = TransformProfile.defaultProfile(for: prompt)
        profile.useWritingSamples = true
        let longText = String(repeating: "a", count: 1_600)
        let samples = [
            WritingSample(title: "One", text: longText),
            WritingSample(title: "Two", text: "two"),
            WritingSample(title: "Three", text: "three"),
            WritingSample(title: "Four", text: "four"),
        ]

        let assembled = TransformPromptAssembler.assemble(
            prompt: prompt,
            profile: profile,
            writingSamples: samples
        )

        XCTAssertTrue(assembled.contains("One"))
        XCTAssertTrue(assembled.contains("two"))
        XCTAssertTrue(assembled.contains("three"))
        XCTAssertFalse(assembled.contains("four"))
        XCTAssertTrue(assembled.contains(String(repeating: "a", count: 1_500)))
        XCTAssertFalse(assembled.contains(String(repeating: "a", count: 1_501)))
    }
}
