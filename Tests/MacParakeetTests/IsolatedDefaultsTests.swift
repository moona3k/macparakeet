import CoreFoundation
import Foundation
import XCTest

final class IsolatedDefaultsTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDownWithError() throws {
        // XCTest runs registered teardown blocks before tearDownWithError.
        for suiteName in suiteNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL(for: suiteName).path))
            XCTAssertTrue(UserDefaults.standard.persistentDomain(forName: suiteName)?.isEmpty ?? true)
        }
        try super.tearDownWithError()
    }

    func testWrittenSuiteIsRemovedAfterReopening() throws {
        let suiteName = makeIsolatedDefaultsSuite("isolated-defaults-tests.")
        suiteNames.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set("value", forKey: "key")
        XCTAssertTrue(defaults.synchronize())
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL(for: suiteName).path))
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(reopened.string(forKey: "key"), "value")

        let otherSuite = makeIsolatedDefaultsSuite("isolated-defaults-tests.")
        suiteNames.append(otherSuite)
        XCTAssertNotEqual(suiteName, otherSuite)
        XCTAssertNil(UserDefaults(suiteName: otherSuite)?.string(forKey: "key"))
    }

    func testCFPreferencesDomainIsRemoved() {
        let suiteName = makeIsolatedDefaultsSuite("isolated-cfpreferences-tests.")
        suiteNames.append(suiteName)
        CFPreferencesSetAppValue("key" as CFString, "value" as CFString, suiteName as CFString)
        XCTAssertTrue(CFPreferencesAppSynchronize(suiteName as CFString))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL(for: suiteName).path))
    }

    func testUnwrittenSuiteNeedsNoPlist() {
        let suiteName = makeIsolatedDefaultsSuite("isolated-unwritten-defaults-tests.")
        suiteNames.append(suiteName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL(for: suiteName).path))
    }

    private func plistURL(for suiteName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(suiteName).plist")
    }
}
