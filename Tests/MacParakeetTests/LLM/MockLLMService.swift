import Foundation
@testable import MacParakeetCore

actor MockLLMService: LLMServiceProtocol {
    private(set) var requests: [LLMRequest] = []
    private var configuredText: String = "mock-llm-response"
    private var configuredError: Error?
    private var configuredDuration: TimeInterval = 0.05

    func configureResponse(text: String, durationSeconds: TimeInterval = 0.05) {
        configuredText = text
        configuredDuration = durationSeconds
        configuredError = nil
    }

    func configureError(_ error: Error) {
        configuredError = error
    }

    func reset() {
        requests = []
        configuredText = "mock-llm-response"
        configuredDuration = 0.05
        configuredError = nil
    }

    func requestCount() -> Int {
        requests.count
    }

    func generate(request: LLMRequest) async throws -> LLMResponse {
        requests.append(request)
        if let configuredError {
            throw configuredError
        }
        return LLMResponse(
            text: configuredText,
            modelID: "mock-qwen",
            durationSeconds: configuredDuration
        )
    }
}
