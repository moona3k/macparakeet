import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMSummarizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summarize",
        abstract: "Summarize text from a file or stdin using the configured LLM provider."
    )

    @Argument(help: "Path to text file to summarize. Use '-' for stdin.")
    var input: String

    @Flag(name: .long, help: "Stream the response token by token.")
    var stream: Bool = false

    func run() async throws {
        let text = try readInput(input)

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("Input is empty.")
            throw ExitCode.failure
        }

        let service = LLMService()

        if stream {
            let tokenStream = service.summarizeStream(transcript: text)
            for try await token in tokenStream {
                print(token, terminator: "")
            }
            print() // final newline
        } else {
            let summary = try await service.summarize(transcript: text)
            print(summary)
        }
    }
}

func readInput(_ path: String) throws -> String {
    if path == "-" {
        var lines: [String] = []
        while let line = readLine(strippingNewline: false) {
            lines.append(line)
        }
        return lines.joined()
    } else {
        let url = URL(fileURLWithPath: path)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
