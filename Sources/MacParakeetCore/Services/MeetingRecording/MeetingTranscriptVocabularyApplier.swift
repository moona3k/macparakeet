import Foundation

/// Applies the user's Vocabulary (custom-word) corrections to a finalized
/// meeting transcript.
///
/// Meetings historically bypassed Vocabulary entirely: the deterministic
/// pipeline only ran for dictation and file/URL transcripts, and the meeting
/// finalizer assembled word tokens straight from raw STT. So a company,
/// product, or person name the user had already corrected elsewhere still came
/// through raw in meetings — re-corrected by hand every time (issue #550).
///
/// This corrects both representations the user actually sees:
/// - `rawTranscript` — the plain-text transcript, and
/// - `words` — the `WordTimestamp` tokens that drive the speaker-segmented
///   transcript view and the SRT/VTT/speaker-paragraph exports.
///
/// Only the *custom-word* stage of the dictation pipeline is reused here — not
/// filler removal, snippet expansion, or insertion styling, which are
/// dictation-paste concerns that would corrupt a verbatim meeting record.
/// Timestamps, confidence, and speaker IDs are preserved exactly; corrections
/// are spelling-only.
///
/// Multi-token rules (e.g. "mac parakeet" → "MacParakeet") still rewrite the
/// contiguous plain text, but the per-word pass corrects tokens individually,
/// so a phrase spanning separate tokens is corrected in `rawTranscript` only.
/// Single-token rules — the common case for names and jargon — are corrected
/// consistently across both.
struct MeetingTranscriptVocabularyApplier {
    private static let tokenWordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    private static let tokenTrimCharacters = tokenWordCharacters.inverted

    static func apply(
        rawTranscript: String,
        words: [WordTimestamp],
        customWords: [CustomWord]
    ) -> (rawTranscript: String, words: [WordTimestamp]) {
        let replacer = CustomWordReplacer(words: customWords)
        guard !replacer.isEmpty else { return (rawTranscript, words) }

        let correctedTranscript = replacer.apply(to: rawTranscript)
        let tokenLookup = tokenVocabularyLookup(from: customWords)
        let correctedWords = words.map { word -> WordTimestamp in
            guard shouldScanToken(word.word, tokenLookup: tokenLookup) else {
                return word
            }
            var corrected = word
            corrected.word = replacer.apply(to: word.word)
            return corrected
        }
        return (correctedTranscript, correctedWords)
    }

    private static func tokenVocabularyLookup(from customWords: [CustomWord]) -> Set<String>? {
        var keys: Set<String> = []
        for customWord in customWords where customWord.isEnabled {
            guard let key = tokenLookupKey(for: customWord.word) else {
                return nil
            }
            keys.insert(key)
        }
        return keys
    }

    private static func shouldScanToken(_ text: String, tokenLookup: Set<String>?) -> Bool {
        guard let tokenLookup else { return true }
        guard !tokenLookup.isEmpty else { return false }
        return !tokenCandidateKeys(for: text).isDisjoint(with: tokenLookup)
    }

    private static func tokenCandidateKeys(for text: String) -> Set<String> {
        guard let key = tokenLookupKey(for: text) else { return [] }

        var keys: Set<String> = [key]
        for component in key.split(whereSeparator: { !isTokenWordCharacter($0) }) {
            keys.insert(String(component))
        }
        return keys
    }

    private static func tokenLookupKey(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: tokenTrimCharacters)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private static func isTokenWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { tokenWordCharacters.contains($0) }
    }
}
