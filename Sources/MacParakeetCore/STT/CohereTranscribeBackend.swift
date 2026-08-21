import Foundation
import NaturalLanguage

struct CohereNativeCapabilities: Sendable, Equatable {
    let runtimeVersion: String
    let runtimeCommit: String
    let architecture: String
    let variant: String
    let computeBackend: String
    let nativeSampleRate: Int
    let maxAudioMilliseconds: Int64
    let supportedLanguages: [String]
    let supportsLanguageDetection: Bool
    let providesTimestamps: Bool
}

struct CohereNativeTranscript: Sendable, Equatable {
    let text: String
    let detectedLanguage: String?
    let wasTruncated: Bool
}

enum CohereNativeBackendError: LocalizedError, Equatable {
    case frameworkUnavailable
    case incompatibleRuntime(expectedVersion: String, actualVersion: String)
    case incompatibleCommit(expectedPrefix: String, actualCommit: String)
    case incompatibleModel(architecture: String, variant: String)
    case languageDetectionUnavailable
    case unsupportedLanguages(expected: [String], actual: [String])
    case unsupportedSampleRate(Int)
    case invalidMaximumAudioMilliseconds(Int64)
    case unexpectedTimestampSupport
    case outputTruncatedAtMinimum(Int)
    case notLoaded
    case nativeFailure(String)

    var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            return
                "The pinned transcribe.cpp framework is unavailable. Install the owned MacParakeet XCFramework before using Cohere Transcribe."
        case .incompatibleRuntime(let expected, let actual):
            return "The transcribe.cpp runtime is \(actual), expected \(expected)."
        case .incompatibleCommit(let expected, let actual):
            return "The transcribe.cpp runtime commit is \(actual), expected prefix \(expected)."
        case .incompatibleModel(let architecture, let variant):
            return "The GGUF identifies as \(architecture)/\(variant), not the pinned Cohere model."
        case .languageDetectionUnavailable:
            return
                "This Cohere adapter cannot provide automatic language metadata. Install the compatible owned MacParakeet transcribe.cpp build."
        case .unsupportedLanguages(let expected, let actual):
            return
                "The Cohere backend languages are \(actual.joined(separator: ", ")), expected \(expected.joined(separator: ", "))."
        case .unsupportedSampleRate(let sampleRate):
            return "The Cohere backend requires 16 kHz audio, but the model reports \(sampleRate) Hz."
        case .invalidMaximumAudioMilliseconds(let milliseconds):
            return "The Cohere backend reported an invalid audio limit of \(milliseconds) ms."
        case .unexpectedTimestampSupport:
            return "The pinned Cohere backend unexpectedly reports timestamp support."
        case .outputTruncatedAtMinimum(let sampleCount):
            return
                "Cohere truncated a \(sampleCount)-sample chunk at the minimum safe size."
        case .notLoaded:
            return "The Cohere native context is not loaded."
        case .nativeFailure(let message):
            return message
        }
    }
}

protocol CohereTranscribeBackend: Sendable {
    func load(
        modelURL: URL,
        computePolicy: CohereTranscribeEngine.ComputePolicy
    ) async throws -> CohereNativeCapabilities

    func transcribe(
        samples: [Float],
        language: String?
    ) async throws -> CohereNativeTranscript

    func unload() async
}

enum CohereTranscriptLanguageDetector {
    static func detect(
        _ text: String,
        supportedLanguages: [String]
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let supported = Set(supportedLanguages.map { primaryCode($0) })
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        if let dominant = recognizer.dominantLanguage.map({ primaryCode($0.rawValue) }),
            supported.contains(dominant)
        {
            return dominant
        }

        return recognizer.languageHypotheses(withMaximum: 20)
            .compactMap { language, confidence -> (String, Double)? in
                let code = primaryCode(language.rawValue)
                return supported.contains(code) ? (code, confidence) : nil
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private static func primaryCode(_ code: String) -> String {
        code.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? code.lowercased()
    }
}

actor UnavailableCohereTranscribeBackend: CohereTranscribeBackend {
    func load(
        modelURL _: URL,
        computePolicy _: CohereTranscribeEngine.ComputePolicy
    ) async throws -> CohereNativeCapabilities {
        throw CohereNativeBackendError.frameworkUnavailable
    }

    func transcribe(
        samples _: [Float],
        language _: String?
    ) async throws -> CohereNativeTranscript {
        throw CohereNativeBackendError.frameworkUnavailable
    }

    func unload() async {}
}

enum CohereTranscribeBackendFactory {
    static var isNativeFrameworkAvailable: Bool {
        #if MACPARAKEET_HAS_TRANSCRIBE_CPP
        true
        #else
        false
        #endif
    }

    static func makeDefault() -> any CohereTranscribeBackend {
        #if MACPARAKEET_HAS_TRANSCRIBE_CPP
        TranscribeCppCohereBackend()
        #else
        UnavailableCohereTranscribeBackend()
        #endif
    }
}
