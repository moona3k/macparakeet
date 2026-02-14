import Foundation
@testable import MacParakeetCore

actor MockLLMService: LLMServiceProtocol {
    private(set) var requests: [LLMRequest] = []
    private var configuredText: String = "mock-llm-response"
    private var configuredError: Error?
    private var configuredDuration: TimeInterval = 0.05
    private var ready = false
    private var warmUpCalls = 0
    private var warmUpFailuresBeforeSuccess = 0

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
        ready = false
        warmUpCalls = 0
        warmUpFailuresBeforeSuccess = 0
    }

    func requestCount() -> Int {
        requests.count
    }

    func lastRequest() -> LLMRequest? {
        requests.last
    }

    func configureWarmUp(failuresBeforeSuccess: Int = 0) {
        warmUpFailuresBeforeSuccess = max(0, failuresBeforeSuccess)
    }

    func warmUpCallCount() -> Int {
        warmUpCalls
    }

    func setReady(_ value: Bool) {
        ready = value
    }

    func generate(request: LLMRequest) async throws -> LLMResponse {
        requests.append(request)
        if let configuredError {
            throw configuredError
        }
        ready = true
        return LLMResponse(
            text: configuredText,
            modelID: "mock-qwen",
            durationSeconds: configuredDuration
        )
    }

    func warmUp() async throws {
        warmUpCalls += 1

        if warmUpFailuresBeforeSuccess > 0 {
            warmUpFailuresBeforeSuccess -= 1
            throw LLMServiceError.generationFailed("warm-up failed")
        }

        if let configuredError {
            throw configuredError
        }

        ready = true
    }

    func isReady() async -> Bool {
        ready
    }
}
