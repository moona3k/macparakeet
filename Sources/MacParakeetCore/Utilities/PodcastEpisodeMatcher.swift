import Foundation

/// Episode selection from a parsed feed. Swift port of `podcast-fetch`'s
/// `find_episode_by_title` / `find_episode_by_index` plus the CLI's
/// `parse_freetext_query` / `find_episode_by_hints` heuristics.
public enum PodcastEpisodeMatcher {
    private static let episodeMarkers = ["episode", "ep", "ep.", "#"]

    /// Split a freetext query like `"Everyday AI episode 705 train your team"`
    /// into a podcast-name query and a list of episode hints.
    ///
    /// Mirrors `parse_freetext_query`: words before an episode marker / number
    /// form the show name; the marker's digits and everything after become
    /// hints. If no marker is found, the first up-to-3 words are the show name
    /// and the rest are hints.
    public static func parseFreetextQuery(_ query: String) -> (showQuery: String, episodeHints: [String]) {
        let words = query.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        var podcastWords: [String] = []
        var episodeHints: [String] = []
        var inEpisodeSection = false

        for word in words {
            // Strip surrounding punctuation so "400.", "#705", or "AI," still
            // register as numbers / markers / clean hints.
            let cleanWord = word.trimmingCharacters(in: .punctuationCharacters)
            let lower = cleanWord.lowercased()

            if episodeMarkers.contains(where: { lower == $0 || lower.hasPrefix($0) }) {
                inEpisodeSection = true
                let digits = lower.filter(\.isNumber)
                if !digits.isEmpty {
                    episodeHints.append(digits)
                }
                continue
            }

            if !cleanWord.isEmpty, cleanWord.allSatisfy(\.isNumber) {
                episodeHints.append(cleanWord)
                inEpisodeSection = true
                continue
            }

            if inEpisodeSection {
                if !cleanWord.isEmpty { episodeHints.append(cleanWord) }
            } else {
                podcastWords.append(cleanWord.isEmpty ? word : cleanWord)
            }
        }

        if podcastWords.isEmpty, !words.isEmpty {
            let splitPoint = min(3, words.count)
            podcastWords = Array(words[..<splitPoint])
            if words.count > splitPoint {
                episodeHints = Array(words[splitPoint...])
            }
        }

        return (podcastWords.joined(separator: " "), episodeHints)
    }

    /// Find an episode by title — exact (case-insensitive) match first, then a
    /// substring match. Mirrors `find_episode_by_title`.
    public static func findByTitle(_ episodes: [PodcastFeedEpisode], query: String) -> PodcastFeedEpisode? {
        let queryLower = query.lowercased()
        if let exact = episodes.first(where: { $0.title.lowercased() == queryLower }) {
            return exact
        }
        return episodes.first(where: { $0.title.lowercased().contains(queryLower) })
    }

    /// Find an episode by feed index (0 = latest/first). Mirrors
    /// `find_episode_by_index`.
    public static func findByIndex(_ episodes: [PodcastFeedEpisode], index: Int) -> PodcastFeedEpisode? {
        guard index >= 0, index < episodes.count else { return nil }
        return episodes[index]
    }

    /// Score episodes against hints and return the best match. A numeric hint
    /// matching the title as an episode number scores strongly (+10); other
    /// keyword substring hits score +1. Mirrors `find_episode_by_hints`.
    public static func findByHints(_ episodes: [PodcastFeedEpisode], hints: [String]) -> PodcastFeedEpisode? {
        var best: (episode: PodcastFeedEpisode, score: Int)?

        for episode in episodes {
            let titleLower = episode.title.lowercased()
            var score = 0

            for hint in hints {
                let hintLower = hint.lowercased()
                if !hint.isEmpty, hint.allSatisfy(\.isNumber) {
                    if titleLower.contains(" \(hintLower)")
                        || titleLower.contains(":\(hintLower)")
                        || titleLower.contains("#\(hintLower)")
                        || titleLower.hasPrefix("ep \(hintLower)")
                        || titleLower.hasPrefix("ep\(hintLower)")
                        || titleLower.hasPrefix("episode \(hintLower)") {
                        score += 10
                    }
                } else if titleLower.contains(hintLower) {
                    score += 1
                }
            }

            if score > 0, score > (best?.score ?? 0) {
                best = (episode, score)
            }
        }

        return best?.episode
    }

    /// Select an episode given parsed hints: hint-scored best, else the latest.
    public static func selectEpisode(_ episodes: [PodcastFeedEpisode], hints: [String]) -> PodcastFeedEpisode? {
        guard !episodes.isEmpty else { return nil }
        if hints.isEmpty {
            return episodes.first
        }
        return findByHints(episodes, hints: hints) ?? episodes.first
    }
}
