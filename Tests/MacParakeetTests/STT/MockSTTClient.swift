import Foundation
@testable import MacParakeetCore

public actor MockSTTClient: STTClientProtocol {
    public var transcribeResult: STTResult?
    public var transcribeError: Error?
    public var transcribeCallCount = 0
    public var lastAudioPath: String?
    public var warmUpCalled = false
    public var warmUpError: Error?
    public var warmUpProgressPhases: [String]?
    public var shutdownCalled = false

    public init() {}

    public func configure(result: STTResult) {
        self.transcribeResult = result
        self.transcribeError = nil
    }

    public func configure(error: Error) {
        self.transcribeError = error
        self.transcribeResult = nil
    }

    public func configureWarmUp(error: Error? = nil, progressPhases: [String]? = nil) {
        self.warmUpError = error
        self.warmUpProgressPhases = progressPhases
    }

    public func transcribe(audioPath: String, onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> STTResult {
        transcribeCallCount += 1
        lastAudioPath = audioPath

        if let error = transcribeError {
            throw error
        }

        return transcribeResult ?? STTResult(text: "Mock transcription", words: [])
    }

    public func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        warmUpCalled = true

        if let phases = warmUpProgressPhases {
            for phase in phases {
                onProgress?(phase)
            }
        }

        if let error = warmUpError {
            throw error
        }
    }

    public func wasWarmUpCalled() -> Bool {
        warmUpCalled
    }

    public var ready = true

    public func isReady() async -> Bool {
        return ready
    }

    public func shutdown() async {
        shutdownCalled = true
    }
}
