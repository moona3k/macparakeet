// MacParakeetCore - Shared library for MacParakeet
// This file is a placeholder to allow the package to build.

import Foundation

/// MacParakeetCore version
public let macParakeetCoreVersion = "0.1.0"

/// Placeholder for future TranscriptionService
public struct TranscriptionService {
    public init() {}

    public func transcribe(audioURL: URL) async throws -> String {
        // TODO: Implement Parakeet STT integration
        fatalError("Not implemented")
    }
}
