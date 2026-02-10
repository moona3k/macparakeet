import XCTest
@testable import MacParakeetCore

final class JSONRPCTests: XCTestCase {

    // MARK: - Request Encoding

    func testRequestEncoding() throws {
        let request = JSONRPCRequest(
            method: "transcribe",
            params: ["audio_path": .string("/tmp/test.wav")],
            id: 1
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["method"] as? String, "transcribe")
        XCTAssertEqual(json["id"] as? Int, 1)

        let params = json["params"] as? [String: String]
        XCTAssertEqual(params?["audio_path"], "/tmp/test.wav")
    }

    func testPingRequestEncoding() throws {
        let request = JSONRPCRequest(
            method: "ping",
            params: [:],
            id: 42
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["method"] as? String, "ping")
        XCTAssertEqual(json["id"] as? Int, 42)
    }

    // MARK: - Response Decoding

    func testSuccessResponseDecoding() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "result": {
                "text": "Hello world",
                "words": [
                    {"word": "Hello", "start_ms": 0, "end_ms": 500, "confidence": 0.98},
                    {"word": "world", "start_ms": 520, "end_ms": 1000, "confidence": 0.95}
                ]
            },
            "id": 1
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)

        XCTAssertEqual(response.jsonrpc, "2.0")
        XCTAssertEqual(response.id, 1)
        XCTAssertNil(response.error)
        XCTAssertNotNil(response.result)
        XCTAssertEqual(response.result?.text, "Hello world")
        XCTAssertEqual(response.result?.words?.count, 2)
        XCTAssertEqual(response.result?.words?[0].word, "Hello")
        XCTAssertEqual(response.result?.words?[0].startMs, 0)
        XCTAssertEqual(response.result?.words?[0].endMs, 500)
        XCTAssertEqual(response.result?.words?[0].confidence, 0.98)
        XCTAssertEqual(response.result?.words?[1].word, "world")
    }

    func testErrorResponseDecoding() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "error": {
                "code": -32000,
                "message": "Transcription failed",
                "data": {
                    "reason": "Audio file not found"
                }
            },
            "id": 1
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)

        XCTAssertNil(response.result)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, -32000)
        XCTAssertEqual(response.error?.message, "Transcription failed")
        XCTAssertEqual(response.error?.data?.reason, "Audio file not found")
    }

    func testResponseWithNoWords() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "result": {
                "text": "Hello"
            },
            "id": 1
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)

        XCTAssertEqual(response.result?.text, "Hello")
        XCTAssertNil(response.result?.words)
    }

    func testPingResponseDecoding() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "result": "pong",
            "id": 42
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(JSONRPCPingResponse.self, from: data)

        XCTAssertEqual(response.result, "pong")
        XCTAssertEqual(response.id, 42)
    }

    // MARK: - Round-trip

    func testRequestResponseRoundTrip() throws {
        let request = JSONRPCRequest(
            method: "transcribe",
            params: ["audio_path": .string("/tmp/test.wav")],
            id: 7
        )

        let requestData = try JSONEncoder().encode(request)
        let requestJSON = try JSONSerialization.jsonObject(with: requestData) as! [String: Any]

        // Verify the request contains all necessary fields
        XCTAssertEqual(requestJSON["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(requestJSON["method"] as? String, "transcribe")
        XCTAssertEqual(requestJSON["id"] as? Int, 7)

        // Simulate a response
        let responseJSON = """
        {
            "jsonrpc": "2.0",
            "result": {"text": "test result", "words": []},
            "id": 7
        }
        """

        let response = try JSONDecoder().decode(
            JSONRPCResponse.self,
            from: responseJSON.data(using: .utf8)!
        )
        XCTAssertEqual(response.id, 7)
        XCTAssertEqual(response.result?.text, "test result")
    }
}
