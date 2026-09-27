import Foundation
import XCTest

extension XCTestCase {
    /// Returns a unique suite name so UserDefaults and CFPreferences can share the same test domain.
    /// Duplicated in CLITests to avoid adding a test-support package target for this small helper.
    func makeIsolatedDefaultsSuite(_ prefix: String) -> String {
        let suiteName = "\(prefix)\(UUID().uuidString)"
        addTeardownBlock {
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            // Flush the cleared domain before unlinking, or cfprefsd can recreate its empty plist.
            XCTAssertTrue(defaults.synchronize(), "Could not synchronize test defaults: \(suiteName)")
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences", isDirectory: true)
                .appendingPathComponent("\(suiteName).plist")
            do {
                try FileManager.default.removeItem(at: plist)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Suites that were never written may have no plist.
            }
        }
        return suiteName
    }
}
