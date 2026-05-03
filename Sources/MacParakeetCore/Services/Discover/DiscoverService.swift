import Foundation
import OSLog

// MARK: - Protocol

public protocol DiscoverServiceProtocol: Sendable {
    func loadContent() async -> DiscoverFeed
    func fetchFresh() async -> DiscoverFeed?
}

// MARK: - Implementation

public final class DiscoverService: DiscoverServiceProtocol {
    private static let ioQueue = DispatchQueue(
        label: "com.macparakeet.core.discover-io",
        qos: .utility
    )

    private let feedURL: URL
    private let cachePath: String
    private let fallbackData: Data
    private let session: URLSession
    private let log = Logger(subsystem: "com.macparakeet.app", category: "DiscoverService")

    public init(
        feedURL: URL? = nil,
        cachePath: String? = nil,
        fallbackData: Data,
        session: URLSession = .shared
    ) {
        if let feedURL {
            self.feedURL = feedURL
        } else if let envURL = ProcessInfo.processInfo.environment["MACPARAKEET_DISCOVER_URL"],
                  let url = URL(string: envURL) {
            self.feedURL = url
        } else {
            self.feedURL = URL(string: "https://macparakeet.com/api/discover.json")!
        }
        self.cachePath = cachePath ?? AppPaths.discoverCachePath
        self.fallbackData = fallbackData
        self.session = session
    }

    private var cacheURL: URL { URL(fileURLWithPath: cachePath) }

    public func loadContent() async -> DiscoverFeed {
        let cacheURL = self.cacheURL
        let fallbackData = self.fallbackData

        let (feed, usedFallbackEmptyFeed) = await Self.runIO {
            // Try cache first
            if let data = try? Data(contentsOf: cacheURL),
               let cachedFeed = try? JSONDecoder().decode(DiscoverFeed.self, from: data) {
                return (cachedFeed, false)
            }

            // Fall back to bundled data
            if let fallbackFeed = try? JSONDecoder().decode(DiscoverFeed.self, from: fallbackData) {
                return (fallbackFeed, false)
            }

            return (DiscoverFeed(version: 0, items: []), true)
        }

        if usedFallbackEmptyFeed {
            log.warning("Failed to decode both cache and fallback discover feeds")
        }
        return feed
    }

    public func fetchFresh() async -> DiscoverFeed? {
        do {
            var request = URLRequest(url: feedURL, timeoutInterval: 10)
            request.httpMethod = "GET"
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                log.warning("Discover feed fetch returned non-200 status")
                return nil
            }

            let cacheURL = self.cacheURL
            let decodedFeed = await Self.runIO { () -> DiscoverFeed? in
                guard let feed = try? JSONDecoder().decode(DiscoverFeed.self, from: data) else {
                    return nil
                }
                do {
                    try FileManager.default.createDirectory(
                        at: cacheURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: cacheURL, options: .atomic)
                } catch {
                    // Cache write failure should not block fresh content.
                }
                return feed
            }

            guard let decodedFeed else {
                log.warning("Failed to decode discover feed response")
                return nil
            }

            return decodedFeed
        } catch {
            log.warning("Failed to fetch discover feed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func runIO<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
