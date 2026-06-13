import XCTest
@testable import MacParakeetCore

final class NumberFormattingTests: XCTestCase {

    // MARK: - compactFormatted

    func testCompactFormattedZero() {
        XCTAssertEqual(0.compactFormatted, "0")
    }

    func testCompactFormattedUnderThousand() {
        XCTAssertEqual(1.compactFormatted, "1")
        XCTAssertEqual(999.compactFormatted, "999")
    }

    func testCompactFormattedExactThousand() {
        XCTAssertEqual(1000.compactFormatted, "1K")
    }

    func testCompactFormattedThousands() {
        XCTAssertEqual(1234.compactFormatted, "1.2K")
        XCTAssertEqual(12345.compactFormatted, "12.3K")
    }

    func testCompactFormattedHundredThousands() {
        XCTAssertEqual(100_000.compactFormatted, "100K")
        XCTAssertEqual(999_999.compactFormatted, "999K")
    }

    func testCompactFormattedMillions() {
        XCTAssertEqual(1_000_000.compactFormatted, "1M")
        XCTAssertEqual(2_500_000.compactFormatted, "2.5M")
    }

    // MARK: - friendlyDuration

    func testFriendlyDurationSeconds() {
        XCTAssertEqual(0.friendlyDuration, "0 sec")
        XCTAssertEqual(45_000.friendlyDuration, "45 sec")
        XCTAssertEqual(59_000.friendlyDuration, "59 sec")
    }

    func testFriendlyDurationMinutes() {
        XCTAssertEqual(60_000.friendlyDuration, "1 min")
        XCTAssertEqual(90_000.friendlyDuration, "1.5 min")
        XCTAssertEqual(150_000.friendlyDuration, "2.5 min")
    }

    func testFriendlyDurationHours() {
        XCTAssertEqual(3_600_000.friendlyDuration, "1 hr")
        XCTAssertEqual(8_280_000.friendlyDuration, "2.3 hr")
    }

    // MARK: - formattedWPM

    func testFormattedWPM() {
        XCTAssertEqual(142.7.formattedWPM, "143 WPM")
        XCTAssertEqual(0.0.formattedWPM, "0 WPM")
        XCTAssertEqual(100.0.formattedWPM, "100 WPM")
        XCTAssertEqual(99.4.formattedWPM, "99 WPM")
    }
}
