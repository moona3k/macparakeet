import XCTest
@testable import MacParakeet

/// Guards the lazy/non-lazy decision for the timed transcript body and the
/// DEBUG launch overrides used to bisect the transcript freeze.
final class TranscriptBodyLayoutTests: XCTestCase {

    func testSmallTranscriptsRenderNonLazily() {
        XCTAssertFalse(TranscriptBodyLayout.usesLazyStack(rowCount: 0, environment: [:]))
        XCTAssertFalse(TranscriptBodyLayout.usesLazyStack(rowCount: 12, environment: [:]))
        XCTAssertFalse(
            TranscriptBodyLayout.usesLazyStack(rowCount: TranscriptBodyLayout.nonLazyRowLimit, environment: [:])
        )
    }

    func testReporterScaleTranscriptsStayLazy() {
        // Issue #845: 11,563 words, about 964 segments.
        XCTAssertTrue(
            TranscriptBodyLayout.usesLazyStack(rowCount: TranscriptBodyLayout.nonLazyRowLimit + 1, environment: [:])
        )
        XCTAssertTrue(TranscriptBodyLayout.usesLazyStack(rowCount: 964, environment: [:]))
    }

    func testPendingRowCountStaysLazyUntilDetachedCacheFinishes() {
        XCTAssertTrue(TranscriptBodyLayout.usesLazyStack(rowCount: nil, environment: [:]))
    }

    func testRowTextSelectionIsOnByDefault() {
        XCTAssertTrue(TranscriptBodyLayout.rowTextSelectionEnabled(environment: [:]))
    }

    func testDebugOverrideParsing() {
        let name = "MACPARAKEET_DEBUG_TRANSCRIPT_LAZY"
        #if DEBUG
        XCTAssertEqual(TranscriptBodyLayout.debugOverride(named: name, environment: [name: "1"]), true)
        XCTAssertEqual(TranscriptBodyLayout.debugOverride(named: name, environment: [name: "YES"]), true)
        XCTAssertEqual(TranscriptBodyLayout.debugOverride(named: name, environment: [name: "0"]), false)
        XCTAssertEqual(TranscriptBodyLayout.debugOverride(named: name, environment: [name: "false"]), false)
        XCTAssertNil(TranscriptBodyLayout.debugOverride(named: name, environment: [name: "maybe"]))
        #else
        XCTAssertNil(TranscriptBodyLayout.debugOverride(named: name, environment: [name: "1"]))
        #endif
        XCTAssertNil(TranscriptBodyLayout.debugOverride(named: name, environment: [:]))
    }
}
