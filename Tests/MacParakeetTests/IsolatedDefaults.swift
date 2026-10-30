import Foundation
import XCTest

extension XCTestCase {
    /// Returns a unique suite name so UserDefaults and CFPreferences can share the same test domain.
    /// Kept identical in both test targets to avoid a test-support package target for this small helper.
    func makeIsolatedDefaultsSuite(_ prefix: String) -> String {
        let suiteName = "\(prefix)\(UUID().uuidString)"
        addTeardownBlock {
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            XCTAssertTrue(defaults.synchronize(), "Could not synchronize test defaults: \(suiteName)")
            // synchronize() alone can leave a delayed cfprefsd disk write. The defaults utility
            // flushes it synchronously, so it cannot recreate the empty plist after we unlink it.
            let flush = Process()
            flush.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            flush.arguments = ["delete", suiteName]
            flush.standardOutput = FileHandle.nullDevice
            flush.standardError = FileHandle.nullDevice
            try flush.run()
            flush.waitUntilExit()
            // Exit 1 means the domain was already cleared by removePersistentDomain above.
            XCTAssertEqual(flush.terminationReason, .exit)
            XCTAssertTrue([0, 1].contains(flush.terminationStatus), "Could not flush test defaults: \(suiteName)")
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
