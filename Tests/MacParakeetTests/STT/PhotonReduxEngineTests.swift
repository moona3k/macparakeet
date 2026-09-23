import Foundation
import XCTest
@testable import MacParakeetCore

final class PhotonReduxEngineTests: XCTestCase {
    func testPhotonWordTimestampsBecomeMacParakeetWords() throws {
        let json = """
            {"text":"Hello world.","segments":[{"start":0.1,"end":1.0,"text":"Hello world.","words":[{"word":"Hello","start":0.12,"end":0.45},{"word":"world.","start":0.48,"end":0.98}]}]}
            """
        let result = try PhotonReduxEngine.decodeResponse(Data(json.utf8))

        XCTAssertEqual(result.text, "Hello world.")
        XCTAssertEqual(result.engine, .parakeet)
        XCTAssertEqual(result.engineVariant, "redux")
        XCTAssertEqual(result.words.map(\.word), ["Hello", "world."])
        XCTAssertEqual(result.words.map(\.startMs), [120, 480])
        XCTAssertEqual(result.words.map(\.endMs), [450, 980])
    }

    func testReduxCapabilitiesDoNotPromiseUnsupportedLiveFeatures() {
        let capabilities = SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.redux))
        XCTAssertTrue(capabilities.providesWordTimestamps)
        XCTAssertFalse(capabilities.supportsNativeLiveDictation)
        XCTAssertFalse(capabilities.supportsTailPreview)
        XCTAssertFalse(capabilities.supportsMeetingLivePreview)
        XCTAssertFalse(capabilities.supportsCustomVocabulary)
        XCTAssertNil(ParakeetModelVariant.redux.asrModelVersion)
    }
}
