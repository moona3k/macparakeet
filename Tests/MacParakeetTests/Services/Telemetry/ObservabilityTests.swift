import Testing
@testable import MacParakeetCore

@Suite("Observability")
struct ObservabilityTests {
    @Test("wordCount counts whitespace-delimited words without changing semantics")
    func wordCountWhitespaceSemantics() {
        #expect(Observability.wordCount("") == 0)
        #expect(Observability.wordCount("   \n\t  ") == 0)
        #expect(Observability.wordCount("one two") == 2)
        #expect(Observability.wordCount(" one\t two\nthree ") == 3)
        #expect(Observability.wordCount("hello-world") == 1)
    }
}
