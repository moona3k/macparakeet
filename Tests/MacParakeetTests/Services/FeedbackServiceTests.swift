import XCTest
@testable import MacParakeetCore

// MARK: - Mock URL Protocol

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class FeedbackServiceTests: XCTestCase {
    var service: FeedbackService!
    var session: URLSession!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        service = FeedbackService(
            baseURL: URL(string: "https://test.example.com/api")!,
            session: session
        )
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
    }

    // MARK: - Tests

    func testSubmitFeedbackPostsToCorrectURL() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.handler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{\"success\":true}".utf8))
        }

        let payload = FeedbackPayload(
            category: .bug,
            message: "App crashes on launch",
            email: "user@example.com",
            screenshotBase64: nil,
            screenshotFilename: nil,
            systemInfo: SystemInfo(
                appVersion: "1.0",
                buildNumber: "1",
                gitCommit: "abc123",
                buildSource: "test",
                macOSVersion: "15.0.0",
                chipType: "Apple M1"
            )
        )

        try await service.submitFeedback(payload)

        XCTAssertNotNil(capturedRequest)
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://test.example.com/api/feedback")
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testSubmitFeedbackEncodesSnakeCase() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.handler = { request in
            // URLProtocol may nil-out httpBody; read from httpBodyStream instead
            var bodyData: Data?
            if let body = request.httpBody {
                bodyData = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 65536)
                var collected = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count > 0 { collected.append(buffer, count: count) }
                    else { break }
                }
                stream.close()
                bodyData = collected
            }
            if let data = bodyData {
                capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{\"success\":true}".utf8))
        }

        let payload = FeedbackPayload(
            category: .featureRequest,
            message: "Please add dark mode",
            email: nil,
            screenshotBase64: nil,
            screenshotFilename: nil,
            systemInfo: SystemInfo(
                appVersion: "1.0",
                buildNumber: "1",
                gitCommit: "abc123",
                buildSource: "test",
                macOSVersion: "15.0.0",
                chipType: "Apple M1"
            )
        )

        try await service.submitFeedback(payload)

        XCTAssertNotNil(capturedBody)
        XCTAssertEqual(capturedBody?["category"] as? String, "featureRequest")
        XCTAssertEqual(capturedBody?["message"] as? String, "Please add dark mode")

        // Verify snake_case keys
        let sysInfo = capturedBody?["system_info"] as? [String: Any]
        XCTAssertNotNil(sysInfo)
        XCTAssertEqual(sysInfo?["app_version"] as? String, "1.0")
        XCTAssertEqual(sysInfo?["mac_os_version"] as? String, "15.0.0")
        XCTAssertEqual(sysInfo?["chip_type"] as? String, "Apple M1")
    }

    func testEmptyMessageThrowsError() async {
        let payload = FeedbackPayload(
            category: .bug,
            message: "   ",
            email: nil,
            screenshotBase64: nil,
            screenshotFilename: nil,
            systemInfo: SystemInfo(
                appVersion: "1.0",
                buildNumber: "1",
                gitCommit: "abc123",
                buildSource: "test",
                macOSVersion: "15.0.0",
                chipType: "Apple M1"
            )
        )

        do {
            try await service.submitFeedback(payload)
            XCTFail("Expected FeedbackError.emptyMessage")
        } catch let error as FeedbackError {
            XCTAssertEqual(error, .emptyMessage)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testServerErrorThrows() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{\"error\":\"Internal Server Error\"}".utf8))
        }

        let payload = FeedbackPayload(
            category: .bug,
            message: "Test message",
            email: nil,
            screenshotBase64: nil,
            screenshotFilename: nil,
            systemInfo: SystemInfo(
                appVersion: "1.0",
                buildNumber: "1",
                gitCommit: "abc123",
                buildSource: "test",
                macOSVersion: "15.0.0",
                chipType: "Apple M1"
            )
        )

        do {
            try await service.submitFeedback(payload)
            XCTFail("Expected FeedbackError.serverError")
        } catch let error as FeedbackError {
            if case .serverError(let code, _) = error {
                XCTAssertEqual(code, 500)
            } else {
                XCTFail("Expected serverError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testFeedbackCategoryDisplayNames() {
        XCTAssertEqual(FeedbackCategory.bug.displayName, "Bug Report")
        XCTAssertEqual(FeedbackCategory.featureRequest.displayName, "Feature Request")
        XCTAssertEqual(FeedbackCategory.other.displayName, "Other")
    }

    func testFeedbackCategoryCaseIterable() {
        XCTAssertEqual(FeedbackCategory.allCases.count, 3)
    }
}
