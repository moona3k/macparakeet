import FluidAudio
@testable import MacParakeetCore
import XCTest

/// Pins the #997 long-file macOS 14 invariant: FluidAudio's default 4-wide
/// chunk pool must not run on the OS where ANE prediction is not reentrant.
///
/// CI is macOS 15+, so these tests inject the serialization flag instead of
/// reading the host OS. They cannot exercise Core ML itself.
final class ParakeetTDTASRConfigTests: XCTestCase {
    func testUsesSingleChunkWorkerWhenANESerializationIsRequired() {
        let config = ParakeetTDTASRConfig.make(serializationRequired: true)
        XCTAssertEqual(
            config.parallelChunkConcurrency,
            1,
            "macOS 14 long-file TDT must not run concurrent Core ML predictions on shared models"
        )
    }

    func testKeepsFluidAudioDefaultChunkConcurrencyWhenANESerializationIsNotRequired() {
        let config = ParakeetTDTASRConfig.make(serializationRequired: false)
        XCTAssertEqual(
            config.parallelChunkConcurrency,
            ASRConfig.default.parallelChunkConcurrency
        )
    }
}
