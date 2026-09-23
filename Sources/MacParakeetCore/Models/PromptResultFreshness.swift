import Foundation
import CryptoKit

/// Decides when a saved prompt result no longer matches the transcript the
/// user is reading.
public enum PromptResultFreshness {
    /// Fingerprints only the canonical transcript text. Presentation settings,
    /// speaker labels, titles, and other recording metadata are not source text.
    public static func sourceTranscriptHash(for transcription: Transcription) -> String {
        let cleanText = transcription.cleanTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcription.isTranscriptEdited && (cleanText?.isEmpty ?? true) {
            let rawText = transcription.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rawText, !rawText.isEmpty {
                return sourceTranscriptHash(cleanTranscript: nil, rawTranscript: rawText)
            }
            let cueText = TranscriptCueBuilder.build(from: transcription)
                .map(\.text)
                .joined(separator: " ")
            return sourceTranscriptHash(cleanTranscript: cueText, rawTranscript: nil)
        }
        return sourceTranscriptHash(cleanTranscript: transcription.cleanTranscript, rawTranscript: transcription.rawTranscript)
    }

    public static func sourceTranscriptHash(cleanTranscript: String?, rawTranscript: String?) -> String {
        let text = (cleanTranscript ?? rawTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func summaryNeedsUpdate(
        sourceCorrectionRevision: Int?,
        currentCorrectionRevision: Int,
        sourceTranscriptHash: String? = nil,
        currentTranscriptHash: String? = nil
    ) -> Bool {
        if let sourceTranscriptHash, let currentTranscriptHash,
            sourceTranscriptHash != currentTranscriptHash
        {
            return true
        }
        if sourceTranscriptHash == nil && currentTranscriptHash != nil {
            return true
        }
        if let sourceCorrectionRevision {
            return sourceCorrectionRevision != currentCorrectionRevision
        }
        return currentCorrectionRevision > 0
    }
}
