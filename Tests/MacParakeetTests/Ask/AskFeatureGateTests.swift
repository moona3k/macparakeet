import XCTest
@testable import MacParakeetCore

final class AskFeatureGateTests: XCTestCase {
    func testWorkspaceIsDisabledByDefault() {
        XCTAssertFalse(AppFeatures.askWorkspaceEnabled)
        XCTAssertFalse(AppFeatures.isAskWorkspaceAvailable(arguments: []))
        XCTAssertFalse(AppFeatures.isAskWorkspaceAvailable(arguments: ["--enable-ask-workspace=false"]))
    }

    func testOnlyDebugBuildsAcceptExplicitDeveloperOptIn() {
        let arguments = [AppFeatures.askWorkspaceDeveloperLaunchArgument]
        #if DEBUG
        XCTAssertTrue(AppFeatures.isAskWorkspaceAvailable(arguments: arguments))
        #else
        XCTAssertFalse(AppFeatures.isAskWorkspaceAvailable(arguments: arguments))
        #endif
    }
}
