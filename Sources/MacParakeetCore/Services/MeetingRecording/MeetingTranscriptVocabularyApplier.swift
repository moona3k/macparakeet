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
    static func apply(
        rawTranscript: String,
        words: [WordTimestamp],
        customWords: [CustomWord]
    ) -> (rawTranscript: String, words: [WordTimestamp]) {
        let replacer = CustomWordReplacer(words: customWords)
        guard !replacer.isEmpty else { return (rawTranscript, words) }

        let correctedTranscript = replacer.apply(to: rawTranscript)
        let correctedWords = words.map { word -> WordTimestamp in
            var corrected = word
            corrected.word = replacer.apply(to: word.word)
            return corrected
        }
        return (correctedTranscript, correctedWords)
    }
}
