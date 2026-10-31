import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

final class CloudSpeechCatalogStateTests: XCTestCase {
    func testEndpointChangeDropsPreviousCatalogAndLateSuccess() {
        var state = CloudSpeechCatalogState()
        let first = state.beginRequest(endpoint: "https://first.invalid/v1")
        state.finish(first, result: .success(catalog("first")))
        XCTAssertEqual(state.catalog.fileModels, ["first"])
        let oldRefresh = state.beginRequest(endpoint: "https://first.invalid/v1")
        state.endpointChanged("https://second.invalid/v1")
        XCTAssertEqual(state.catalog, .fallback)
        XCTAssertFalse(state.isLoading)
        state.finish(oldRefresh, result: .success(catalog("stale")))
        XCTAssertEqual(state.catalog, .fallback)
        XCTAssertNil(state.note)
    }

    func testOldErrorsAndRoundTripEndpointsCannotCompleteNewRequest() {
        var state = CloudSpeechCatalogState()
        let old = state.beginRequest(endpoint: "https://first.invalid/v1")
        state.endpointChanged("https://second.invalid/v1")
        let current = state.beginRequest(endpoint: "https://first.invalid/v1")
        state.finish(old, result: .failure(CatalogFailure()))
        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.note)
        state.finish(old, result: .success(catalog("old")))
        XCTAssertEqual(state.catalog, .fallback)
        state.finish(current, result: .success(catalog("current")))
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.catalog.fileModels, ["current"])
    }

    private func catalog(_ name: String) -> CloudSTTModelCatalog {
        CloudSTTModelCatalog(fileModels: [name], realtimeModels: [], isFromServer: true)
    }
}

private struct CatalogFailure: Error {}
