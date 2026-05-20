import Foundation
import GRDB

public struct LLMRunSource: Sendable, Equatable {
    public var dictationId: UUID?
    public var transcriptionId: UUID?
    public var promptResultId: UUID?
    public var chatConversationId: UUID?
    public var transformHistoryId: UUID?

    public init(
        dictationId: UUID? = nil,
        transcriptionId: UUID? = nil,
        promptResultId: UUID? = nil,
        chatConversationId: UUID? = nil,
        transformHistoryId: UUID? = nil
    ) {
        self.dictationId = dictationId
        self.transcriptionId = transcriptionId
        self.promptResultId = promptResultId
        self.chatConversationId = chatConversationId
        self.transformHistoryId = transformHistoryId
    }
}

public struct LLMRun: Codable, Identifiable, Sendable, Equatable {
    public enum Feature: String, Codable, Sendable {
        case formatterDictation = "formatter_dictation"
        case formatterTranscription = "formatter_transcription"
        case promptResult = "prompt_result"
        case chat
        case transform
    }

    public enum Status: String, Codable, Sendable {
        case succeeded
        case failed
        case cancelled
    }

    public var id: UUID
    public var operationID: String?
    public var feature: Feature
    public var status: Status
    public var dictationId: UUID?
    public var transcriptionId: UUID?
    public var promptResultId: UUID?
    public var chatConversationId: UUID?
    public var transformHistoryId: UUID?
    public var provider: String?
    public var model: String?
    public var errorType: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var latencyMs: Int?
    public var inputChars: Int
    public var outputChars: Int?
    public var stopReason: String?
    public var inputTruncated: Bool
    public var defaultPromptUsed: Bool?
    public var messageCount: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        operationID: String? = nil,
        feature: Feature,
        status: Status,
        source: LLMRunSource = LLMRunSource(),
        provider: String? = nil,
        model: String? = nil,
        errorType: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        latencyMs: Int? = nil,
        inputChars: Int,
        outputChars: Int? = nil,
        stopReason: String? = nil,
        inputTruncated: Bool = false,
        defaultPromptUsed: Bool? = nil,
        messageCount: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.operationID = operationID
        self.feature = feature
        self.status = status
        self.dictationId = source.dictationId
        self.transcriptionId = source.transcriptionId
        self.promptResultId = source.promptResultId
        self.chatConversationId = source.chatConversationId
        self.transformHistoryId = source.transformHistoryId
        self.provider = provider
        self.model = model
        self.errorType = errorType
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.latencyMs = latencyMs
        self.inputChars = inputChars
        self.outputChars = outputChars
        self.stopReason = stopReason
        self.inputTruncated = inputTruncated
        self.defaultPromptUsed = defaultPromptUsed
        self.messageCount = messageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public extension LLMRun {
    init(
        formatterResult: LLMFormatterResult,
        source: LLMRunSource,
        feature: Feature
    ) {
        self.init(
            operationID: formatterResult.operationID,
            feature: feature,
            status: .succeeded,
            source: source,
            provider: formatterResult.result.provider,
            model: formatterResult.result.model,
            promptTokens: formatterResult.result.usage?.promptTokens,
            completionTokens: formatterResult.result.usage?.completionTokens,
            totalTokens: formatterResult.result.usage?.totalTokens,
            latencyMs: formatterResult.result.latencyMs,
            inputChars: formatterResult.inputChars,
            outputChars: formatterResult.outputChars,
            stopReason: formatterResult.result.stopReason,
            inputTruncated: formatterResult.inputTruncated,
            defaultPromptUsed: formatterResult.defaultPromptUsed,
            messageCount: formatterResult.messageCount
        )
    }

    static func failedFormatterRun(
        source: LLMRunSource,
        feature: Feature,
        errorType: String,
        inputChars: Int,
        defaultPromptUsed: Bool,
        startedAt: Date
    ) -> LLMRun {
        LLMRun(
            feature: feature,
            status: .failed,
            source: source,
            errorType: errorType,
            latencyMs: Int((Date().timeIntervalSince(startedAt) * 1000).rounded()),
            inputChars: inputChars,
            outputChars: 0,
            defaultPromptUsed: defaultPromptUsed,
            messageCount: 2
        )
    }
}

extension LLMRun: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "llm_runs"

    public enum Columns: String, ColumnExpression {
        case id
        case operationID
        case feature
        case status
        case dictationId
        case transcriptionId
        case promptResultId
        case chatConversationId
        case transformHistoryId
        case provider
        case model
        case errorType
        case promptTokens
        case completionTokens
        case totalTokens
        case latencyMs
        case inputChars
        case outputChars
        case stopReason
        case inputTruncated
        case defaultPromptUsed
        case messageCount
        case createdAt
        case updatedAt
    }
}
