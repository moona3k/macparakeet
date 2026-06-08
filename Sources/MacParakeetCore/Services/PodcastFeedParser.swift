import Foundation

/// A single episode parsed from a podcast RSS feed.
///
/// Swift port of `podcast-fetch`'s `Episode`. Only items that carry a playable
/// audio enclosure are surfaced.
public struct PodcastFeedEpisode: Sendable, Equatable {
    public let title: String
    public let description: String?
    /// Direct URL to the audio enclosure (MP3, M4A, …).
    public let audioURL: String
    /// Episode length in seconds, parsed from `<itunes:duration>` when present.
    public let durationSeconds: Int?
    /// Raw `<pubDate>` (RFC-822) string, if present.
    public let published: String?

    public init(
        title: String,
        description: String? = nil,
        audioURL: String,
        durationSeconds: Int? = nil,
        published: String? = nil
    ) {
        self.title = title
        self.description = description
        self.audioURL = audioURL
        self.durationSeconds = durationSeconds
        self.published = published
    }
}

public enum PodcastFeedError: Error, LocalizedError, Equatable {
    case parseFailed(String)
    case noEpisodes

    public var errorDescription: String? {
        switch self {
        case .parseFailed(let reason): return "Could not parse the podcast feed: \(reason)"
        case .noEpisodes: return "The podcast feed has no playable episodes"
        }
    }
}

/// Parses a podcast RSS feed (XML) into episodes. Swift/`XMLParser` port of
/// `podcast-fetch`'s `parse_feed` — episodes preserve feed order (typically
/// newest first) and only those with an audio enclosure are included.
public enum PodcastFeedParser {
    private static let audioExtensions: [String] = [
        ".mp3", ".m4a", ".mp4", ".ogg", ".opus", ".aac", ".wav", ".flac", ".wma", ".webm",
    ]

    /// Heuristic mirror of `podcast-fetch`'s `is_audio_url`: a URL whose path
    /// carries a known audio extension or an `/audio` segment.
    static func isAudioURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.contains("/audio") { return true }
        return audioExtensions.contains { lower.contains($0) }
    }

    /// Parse `<itunes:duration>` which may be `HH:MM:SS`, `MM:SS`, or a raw
    /// seconds count. Returns nil for empty/garbage.
    static func parseDuration(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.contains(":") {
            let parts = raw.split(separator: ":").map { Int($0) }
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            let values = parts.compactMap { $0 }
            let seconds: Int
            switch values.count {
            case 3: seconds = values[0] * 3600 + values[1] * 60 + values[2]
            case 2: seconds = values[0] * 60 + values[1]
            case 1: seconds = values[0]
            default: return nil
            }
            return seconds > 0 ? seconds : nil
        }
        guard let seconds = Int(raw), seconds > 0 else { return nil }
        return seconds
    }

    public static func parse(_ data: Data) throws -> [PodcastFeedEpisode] {
        let parser = XMLParser(data: data)
        let delegate = FeedDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "malformed XML"
            throw PodcastFeedError.parseFailed(reason)
        }
        return delegate.episodes
    }

    // MARK: - XMLParser delegate

    private final class FeedDelegate: NSObject, XMLParserDelegate {
        private(set) var episodes: [PodcastFeedEpisode] = []

        private var inItem = false
        // Stack of open element names within the current <item>. Using a stack
        // rather than a single "current element" means text inside a field that
        // contains nested tags (e.g. `<description>a <b>b</b> c</description>`)
        // is still attributed to the field, instead of being dropped once the
        // inner tag closes.
        private var elementStack: [String] = []
        private var title = ""
        private var itemDescription = ""
        private var itunesSummary = ""
        private var duration = ""
        private var pubDate = ""
        private var enclosureURL: String?
        private var enclosureIsAudio = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            let name = elementName.lowercased()

            if name == "item" {
                inItem = true
                elementStack = []
                title = ""
                itemDescription = ""
                itunesSummary = ""
                duration = ""
                pubDate = ""
                enclosureURL = nil
                enclosureIsAudio = false
                return
            }

            guard inItem else { return }
            elementStack.append(name)
            if name == "enclosure" {
                // Accept lowercase or original-cased attribute keys.
                let url = attributeDict["url"] ?? attributeDict["URL"]
                let type = (attributeDict["type"] ?? "").lowercased()
                if let url, !url.isEmpty {
                    if type.hasPrefix("audio") || PodcastFeedParser.isAudioURL(url) {
                        enclosureURL = url
                        enclosureIsAudio = true
                    } else if enclosureURL == nil {
                        // Keep as a weak fallback; only used if nothing better.
                        enclosureURL = url
                    }
                }
            }
        }

        private func appendText(_ text: String) {
            guard inItem else { return }
            if elementStack.contains("title") {
                title += text
            } else if elementStack.contains("description") {
                itemDescription += text
            } else if elementStack.contains("itunes:summary") || elementStack.contains("summary") {
                itunesSummary += text
            } else if elementStack.contains("itunes:duration") || elementStack.contains("duration") {
                duration += text
            } else if elementStack.contains("pubdate") {
                pubDate += text
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            appendText(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let text = String(data: CDATABlock, encoding: .utf8) else { return }
            appendText(text)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = elementName.lowercased()
            guard name == "item" else {
                if inItem, let last = elementStack.last, last == name {
                    elementStack.removeLast()
                } else if inItem, let idx = elementStack.lastIndex(of: name) {
                    // Tolerate minor nesting irregularities without losing the stack.
                    elementStack.remove(at: idx)
                }
                return
            }
            inItem = false

            guard let audioURL = enclosureURL, enclosureIsAudio || PodcastFeedParser.isAudioURL(audioURL) else {
                return
            }

            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let desc = PodcastFeedParser.firstNonEmpty(itemDescription, itunesSummary)
            episodes.append(PodcastFeedEpisode(
                title: trimmedTitle.isEmpty ? "Untitled" : trimmedTitle,
                description: desc,
                audioURL: audioURL.trimmingCharacters(in: .whitespacesAndNewlines),
                durationSeconds: PodcastFeedParser.parseDuration(duration),
                published: PodcastFeedParser.firstNonEmpty(pubDate)
            ))
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}
