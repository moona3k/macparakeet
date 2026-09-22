import XCTest
import MacParakeetCore
@testable import MacParakeet

final class MeetingLabelTintTests: XCTestCase {
    func testAutomaticColorUsesLabelIdentityAcrossRenameAndReordering() throws {
        let id = try XCTUnwrap(UUID(uuidString: "10000000-0000-0000-0000-000000000001"))
        let planning = MeetingLabel(id: id, name: "Planning")
        let renamed = MeetingLabel(id: id, name: "Customer planning")

        XCTAssertEqual(
            MeetingLabelTint.colorKey(for: planning),
            MeetingLabelTint.colorKey(for: renamed)
        )

        let other = MeetingLabel(
            id: try XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000002")),
            name: "Research"
        )
        let reordered = [other, planning].map(MeetingLabelTint.colorKey(for:))

        XCTAssertEqual(reordered[1], MeetingLabelTint.colorKey(for: planning))
    }

    func testExplicitTokensTakePrecedenceIncludingBlue() throws {
        let id = try XCTUnwrap(UUID(uuidString: "30000000-0000-0000-0000-000000000003"))

        XCTAssertEqual(
            MeetingLabelTint.colorKey(for: MeetingLabel(id: id, name: "Blue", colorToken: "blue")),
            .blue
        )
        XCTAssertEqual(
            MeetingLabelTint.colorKey(for: MeetingLabel(id: id, name: "Coral", colorToken: "orange")),
            .coral
        )
    }

    func testUnknownTokenKeepsTheIdentityFallbackWithoutChangingStoredValue() throws {
        let id = try XCTUnwrap(UUID(uuidString: "40000000-0000-0000-0000-000000000004"))
        let missingToken = MeetingLabel(id: id, name: "Research")
        let unsupportedToken = MeetingLabel(id: id, name: "Research", colorToken: "magenta")

        XCTAssertEqual(
            MeetingLabelTint.colorKey(for: missingToken),
            MeetingLabelTint.colorKey(for: unsupportedToken)
        )
        XCTAssertEqual(unsupportedToken.colorToken, "magenta")
    }
}
