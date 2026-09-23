import Foundation
import CryptoKit

/// Decides when a saved prompt result no longer matches the transcript the
/// user is reading.
public enum PromptResultFreshness {
    /// Fingerprints the source words used by rich prompt context. Timestamps,
    /// speaker labels, titles, and other recording metadata are excluded.
    public static func sourceTranscriptHash(for transcription: Transcription) -> String {
        if !transcription.isTranscriptEdited {
            let cueText = TranscriptCueBuilder.build(from: transcription)
                .map(\.text)
                .joined(separator: " ")
            if !cueText.isEmpty {
                return sourceTranscriptHash(cleanTranscript: cueText, rawTranscript: nil)
            }

            let cleanText = transcription.cleanTranscript?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if cleanText?.isEmpty ?? true {
                return sourceTranscriptHash(
                    cleanTranscript: nil,
                    rawTranscript: transcription.rawTranscript
                )
            }
        }
        return sourceTranscriptHash(
            cleanTranscript: transcription.cleanTranscript,
            rawTranscript: transcription.rawTranscript
        )
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
