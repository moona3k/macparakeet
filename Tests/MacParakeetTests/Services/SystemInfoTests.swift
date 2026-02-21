import XCTest
@testable import MacParakeetCore

final class SystemInfoTests: XCTestCase {
    func testCurrentReturnsNonEmptyFields() {
        let info = SystemInfo.current

        XCTAssertFalse(info.appVersion.isEmpty, "appVersion should not be empty")
        XCTAssertFalse(info.buildNumber.isEmpty, "buildNumber should not be empty")
        XCTAssertFalse(info.macOSVersion.isEmpty, "macOSVersion should not be empty")
        XCTAssertFalse(info.chipType.isEmpty, "chipType should not be empty")
        XCTAssertFalse(info.buildSource.isEmpty, "buildSource should not be empty")
    }

    func testMacOSVersionFormat() {
        let info = SystemInfo.current
        // Should match "major.minor.patch"
        let components = info.macOSVersion.split(separator: ".")
        XCTAssertEqual(components.count, 3, "macOSVersion should have 3 components")
        for component in components {
            XCTAssertNotNil(Int(component), "Each version component should be numeric")
        }
    }

    func testDisplaySummaryContainsLabels() {
        let info = SystemInfo.current
        let summary = info.displaySummary

        XCTAssertTrue(summary.contains("App Version:"), "Summary should contain App Version label")
        XCTAssertTrue(summary.contains("macOS:"), "Summary should contain macOS label")
        XCTAssertTrue(summary.contains("Chip:"), "Summary should contain Chip label")
        XCTAssertTrue(summary.contains("Git Commit:"), "Summary should contain Git Commit label")
        XCTAssertTrue(summary.contains("Build Source:"), "Summary should contain Build Source label")
    }

    func testCodableRoundTrip() throws {
        let info = SystemInfo.current

        // Round-trip without custom key strategies (default Codable)
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(SystemInfo.self, from: data)

        XCTAssertEqual(info.appVersion, decoded.appVersion)
        XCTAssertEqual(info.macOSVersion, decoded.macOSVersion)
        XCTAssertEqual(info.chipType, decoded.chipType)
    }

    func testSnakeCaseEncoding() throws {
        let info = SystemInfo.current
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(info)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["app_version"])
        XCTAssertNotNil(json?["mac_os_version"])
        XCTAssertNotNil(json?["chip_type"])
    }
}
