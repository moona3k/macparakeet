import ArgumentParser
import XCTest
@testable import CLI

final class LLMConfigCommandTests: XCTestCase {
    func testValidateCustomBaseURLAcceptsAbsoluteHTTPURL() throws {
        let url = try validateBaseURL("http://localhost:8000/v1")
        XCTAssertEqual(url.absoluteString, "http://localhost:8000/v1")
    }

    func testValidateCustomBaseURLAcceptsAbsoluteHTTPSURL() throws {
        let url = try validateBaseURL("https://example.com/openai")
        XCTAssertEqual(url.absoluteString, "https://example.com/openai")
    }

    func testValidateCustomBaseURLRejectsMissingScheme() {
        XCTAssertThrowsError(try validateBaseURL("localhost:8000/v1")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testValidateCustomBaseURLRejectsUnsupportedScheme() {
        XCTAssertThrowsError(try validateBaseURL("ftp://example.com/v1")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testValidateCustomBaseURLRejectsMissingHost() {
        XCTAssertThrowsError(try validateBaseURL("https:///v1")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }
}
