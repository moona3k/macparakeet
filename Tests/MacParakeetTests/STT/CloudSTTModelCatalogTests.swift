import XCTest

@testable import MacParakeetCore

final class CloudSTTModelCatalogTests: XCTestCase {
    private func response(_ status: Int, _ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testClassifyKeepsOnlySpeechModelsAndSplitsRealtime() {
        let catalog = CloudSTTModelCatalog.classify([
            "gpt-4o", "whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-tts", "text-embedding-3-small",
            "gpt-realtime-whisper", "gpt-live-transcribe", "gpt-realtime-2.1", "whisper-1",
        ])

        XCTAssertEqual(catalog.fileModels, ["gpt-4o-transcribe", "whisper-1"])
        XCTAssertEqual(catalog.realtimeModels, ["gpt-live-transcribe", "gpt-realtime-whisper"])
        XCTAssertTrue(catalog.isFromServer)
    }

    func testLoadRequestsModelsWithTheKeyAndParsesOpenAIShape() async throws {
        let config = CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1", apiKey: "sk-test")
        let seen = RequestBox()

        let catalog = try await CloudSTTModelCatalog.load(config: config) { request in
            await seen.set(request)
            let body = #"{"object":"list","data":[{"id":"whisper-1"},{"id":"gpt-realtime-whisper"},{"id":"gpt-4o"}]}"#
            return (Data(body.utf8), self.response(200, request.url!))
        }

        let request = await seen.value
        XCTAssertEqual(request?.url?.absoluteString, "https://example.com/v1/models")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(catalog.fileModels, ["whisper-1"])
        XCTAssertEqual(catalog.realtimeModels, ["gpt-realtime-whisper"])
    }

    func testLoadReportsRejectedKeyAndServerErrors() async {
        let config = CloudSTTConfig(baseURL: "https://example.com/v1", model: "whisper-1", apiKey: "bad")
        do {
            _ = try await CloudSTTModelCatalog.load(config: config) { request in
                (Data("{}".utf8), self.response(401, request.url!))
            }
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? CloudSTTError, .unauthorized)
        }
        do {
            _ = try await CloudSTTModelCatalog.load(config: config) { request in
                (
                    Data(#"{"error":{"message":"temporarily unavailable"}}"#.utf8),
                    self.response(503, request.url!)
                )
            }
            XCTFail("Expected server status and message")
        } catch {
            XCTAssertEqual(error as? CloudSTTError, .server(status: 503, message: "temporarily unavailable"))
        }
        do {
            _ = try await CloudSTTModelCatalog.load(config: config) { request in
                (Data("<html>".utf8), self.response(200, request.url!))
            }
            XCTFail("Expected invalidResponse")
        } catch {
            XCTAssertEqual(error as? CloudSTTError, .invalidResponse)
        }
    }

    func testFallbackOffersCommonModels() {
        XCTAssertTrue(CloudSTTModelCatalog.fallback.fileModels.contains("whisper-1"))
        XCTAssertTrue(CloudSTTModelCatalog.fallback.realtimeModels.contains("gpt-realtime-whisper"))
        XCTAssertFalse(CloudSTTModelCatalog.fallback.isFromServer)
    }
}

private actor RequestBox {
    private(set) var value: URLRequest?
    func set(_ request: URLRequest) { value = request }
}
