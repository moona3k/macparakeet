import Foundation
import os
import XCTest
@testable import MacParakeetCore

final class PodcastAudioDownloaderTests: XCTestCase {

    func testProgressPercent() {
        XCTAssertEqual(PodcastAudioDownloader.progressPercent(downloaded: 50, total: 100), 50)
        XCTAssertEqual(PodcastAudioDownloader.progressPercent(downloaded: 0, total: 100), 0)
        XCTAssertEqual(PodcastAudioDownloader.progressPercent(downloaded: 100, total: 100), 100)
        XCTAssertEqual(PodcastAudioDownloader.progressPercent(downloaded: 150, total: 100), 100, "clamped to 100")
        XCTAssertEqual(PodcastAudioDownloader.progressPercent(downloaded: 50, total: 0), 0, "unknown total → 0")
    }

    func testSanitizedStem() {
        XCTAssertEqual(PodcastAudioDownloader.sanitizedStem("Ep 1: Hello / World"), "Ep 1 Hello World")
        XCTAssertEqual(PodcastAudioDownloader.sanitizedStem(nil), "Podcast Episode")
        XCTAssertEqual(PodcastAudioDownloader.sanitizedStem("   "), "Podcast Episode")
    }

    func testFileExtensionFromPathThenMime() {
        let mp3URL = URL(string: "https://cdn/x/ep705.mp3")!
        XCTAssertEqual(PodcastAudioDownloader.fileExtension(for: mp3URL, response: URLResponse()), "mp3")

        let noExtURL = URL(string: "https://cdn/x/stream?id=42")!
        let mp3Response = HTTPURLResponse(
            url: noExtURL, mimeType: "audio/mpeg", expectedContentLength: 0, textEncodingName: nil
        )
        XCTAssertEqual(PodcastAudioDownloader.fileExtension(for: noExtURL, response: mp3Response), "mp3")

        let m4aResponse = HTTPURLResponse(
            url: noExtURL, mimeType: "audio/mp4", expectedContentLength: 0, textEncodingName: nil
        )
        XCTAssertEqual(PodcastAudioDownloader.fileExtension(for: noExtURL, response: m4aResponse), "m4a")

        XCTAssertEqual(
            PodcastAudioDownloader.fileExtension(for: noExtURL, response: URLResponse()),
            "mp3",
            "unknown extension + no mime → mp3 default"
        )
    }

    func testUniqueOutputURLDeduplicates() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("podcast-dl-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = PodcastAudioDownloader.uniqueOutputURL(in: dir, suggestedName: "Episode 1", fileExtension: "mp3")
        XCTAssertEqual(first.lastPathComponent, "Episode 1.mp3")
        FileManager.default.createFile(atPath: first.path, contents: Data("x".utf8))

        let second = PodcastAudioDownloader.uniqueOutputURL(in: dir, suggestedName: "Episode 1", fileExtension: "mp3")
        XCTAssertEqual(second.lastPathComponent, "Episode 1 (1).mp3", "dedupes with counter suffix")
    }

    func testFetchEmitsFinalProgressWhenContentLengthIsMissing() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoContentLengthAudioURLProtocol.self]
        let downloader = PodcastAudioDownloader(configuration: configuration)
        let progress = OSAllocatedUnfairLock(initialState: [Int]())

        let output = try await downloader.fetch(
            audioURL: "https://example.com/podcast/episode",
            suggestedName: "No Length Episode"
        ) { percent in
            progress.withLock { $0.append(percent) }
        }
        defer { try? FileManager.default.removeItem(at: output) }

        XCTAssertEqual(progress.withLock { $0.last }, 100)
        XCTAssertEqual(try Data(contentsOf: output), NoContentLengthAudioURLProtocol.body)
    }

    func testFetchSendsConventionalPodcastHeaders() async throws {
        HeaderCapturingAudioURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeaderCapturingAudioURLProtocol.self]
        let downloader = PodcastAudioDownloader(configuration: configuration)

        let output = try await downloader.fetch(
            audioURL: "https://example.com/podcast/headers",
            suggestedName: "Header Episode"
        )
        defer { try? FileManager.default.removeItem(at: output) }

        let headers = try XCTUnwrap(HeaderCapturingAudioURLProtocol.capturedHeaders)
        XCTAssertEqual(
            headers["Accept"],
            "audio/*, application/octet-stream;q=0.9, */*;q=0.8"
        )
        let userAgent = try XCTUnwrap(headers["User-Agent"])
        XCTAssertTrue(userAgent.hasPrefix("MacParakeet/"))
        XCTAssertFalse(userAgent.contains("podcast-fetch"))
    }

    func testFetchLogsPrivacySafeHTTPFailureContext() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForbiddenAudioURLProtocol.self]
        let downloader = PodcastAudioDownloader(configuration: configuration)
        let logURL = AudioCaptureDiagnostics.diagnosticLogURL()
        let existingLog = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""

        do {
            _ = try await downloader.fetch(
                audioURL: "https://example.com/podcast/forbidden",
                suggestedName: "Forbidden Episode"
            )
            XCTFail("Expected an HTTP failure")
        } catch let error as PodcastAudioFetchError {
            XCTAssertEqual(error, .requestFailed("HTTP 403"))
        }

        let fullLog = try String(contentsOf: logURL, encoding: .utf8)
        let appendedLog = fullLog.hasPrefix(existingLog) ? String(fullLog.dropFirst(existingLog.count)) : fullLog
        XCTAssertTrue(appendedLog.contains("podcast_audio_fetch_failed status=403"))
        XCTAssertTrue(appendedLog.contains("server=\"cloudflare\""))
        XCTAssertTrue(appendedLog.contains("retry_after=\"120\""))
        XCTAssertTrue(appendedLog.contains("cf_ray_present=true"))
        XCTAssertTrue(appendedLog.contains("authentication_challenge_present=true"))
        XCTAssertFalse(appendedLog.contains(ForbiddenAudioURLProtocol.cfRay))
        XCTAssertFalse(appendedLog.contains(ForbiddenAudioURLProtocol.authenticationChallenge))
    }
}

private final class NoContentLengthAudioURLProtocol: URLProtocol {
    static let body = Data([0x01, 0x02, 0x03, 0x04])

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/mpeg"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class HeaderCapturingAudioURLProtocol: URLProtocol {
    private static let headers = OSAllocatedUnfairLock<[String: String]?>(initialState: nil)
    static var capturedHeaders: [String: String]? {
        headers.withLock { $0 }
    }

    static func reset() {
        headers.withLock { $0 = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let capturedHeaders = request.allHTTPHeaderFields
        Self.headers.withLock { $0 = capturedHeaders }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/mpeg"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: NoContentLengthAudioURLProtocol.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ForbiddenAudioURLProtocol: URLProtocol {
    static let cfRay = "private-ray-\(UUID().uuidString)"
    static let authenticationChallenge = "Bearer realm=\"private-\(UUID().uuidString)\""

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "text/plain",
                "Server": "cloudflare",
                "Retry-After": "120",
                "CF-RAY": Self.cfRay,
                "WWW-Authenticate": Self.authenticationChallenge,
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("forbidden".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
