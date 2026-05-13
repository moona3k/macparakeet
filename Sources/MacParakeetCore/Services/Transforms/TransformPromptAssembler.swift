import Foundation

public enum TransformPromptAssembler {
    private static let maxSamples = 3
    private static let maxSampleCharacters = 1_500

    public static func assemble(
        prompt: Prompt,
        profile: TransformProfile?,
        writingSamples: [WritingSample]
    ) -> String {
        let profile = profile ?? .defaultProfile(for: prompt)
        var sections = [prompt.content.trimmingCharacters(in: .whitespacesAndNewlines)]

        let rules = TransformRule
            .rules(for: prompt)
            .filter { profile.enabledRuleIDs.contains($0.id) }
        if !rules.isEmpty {
            sections.append("""
                User-selected rules:
                \(rules.map { "- \($0.instruction)" }.joined(separator: "\n"))
                """)
        }

        if let custom = profile.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            sections.append("""
                Additional user instructions:
                \(custom)
                """)
        }

        if profile.useWritingSamples {
            let usableSamples = writingSamples
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .prefix(maxSamples)
            if !usableSamples.isEmpty {
                let sampleText: String = usableSamples.enumerated().map { index, sample -> String in
                    let trimmed = sample.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let clipped = String(trimmed.prefix(maxSampleCharacters))
                    return """
                        Sample \(index + 1) - \(sample.title):
                        \(clipped)
                        """
                }.joined(separator: "\n\n")
                sections.append("""
                    Voice reference samples:
                    Use these samples only to understand the author's natural voice, pacing, and word choice. Do not quote them, summarize them, or introduce facts from them.

                    \(sampleText)
                    """)
            }
        }

        sections.append("Return only the transformed text.")
        return sections.joined(separator: "\n\n")
    }
}
