import Foundation

public struct LLMFormatterResult: Sendable, Equatable {
    public let result: LLMResult
    public let operationID: String
    public let inputChars: Int
    public let outputChars: Int
    public let inputTruncated: Bool
    public let defaultPromptUsed: Bool
    public let messageCount: Int

    public init(
        result: LLMResult,
        operationID: String,
        inputChars: Int,
        outputChars: Int,
        inputTruncated: Bool,
        defaultPromptUsed: Bool,
        messageCount: Int
    ) {
        self.result = result
        self.operationID = operationID
        self.inputChars = inputChars
        self.outputChars = outputChars
        self.inputTruncated = inputTruncated
        self.defaultPromptUsed = defaultPromptUsed
        self.messageCount = messageCount
    }

    public var output: String {
        result.output
    }
}
