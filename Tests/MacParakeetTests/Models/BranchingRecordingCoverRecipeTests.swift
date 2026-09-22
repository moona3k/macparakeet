import Foundation
import XCTest
@testable import MacParakeetCore

final class BranchingRecordingCoverRecipeTests: XCTestCase {
    func testStableUUIDBytesUseCanonicalRFC4122Order() throws {
        let id = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))

        XCTAssertEqual(
            BranchingRecordingCoverRecipe.uuidBytes(id),
            [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        )
        XCTAssertEqual(
            BranchingRecordingCoverRecipe.stableSeed(for: id, domain: "geometry"),
            0x3044_DA66_0D98_BF10
        )
    }

    func testSameUUIDAlwaysProducesTheSameRecipe() throws {
        let id = try XCTUnwrap(UUID(uuidString: "85B4897C-4F5D-4ED1-94EB-C0B5841B1EF5"))

        XCTAssertEqual(
            BranchingRecordingCoverRecipe(recordingID: id),
            BranchingRecordingCoverRecipe(recordingID: id)
        )
    }

    func testRepresentativeUUIDPinsV2SeedGeometryAndInk() throws {
        let id = try XCTUnwrap(UUID(uuidString: "85B4897C-4F5D-4ED1-94EB-C0B5841B1EF5"))
        let recipe = BranchingRecordingCoverRecipe(recordingID: id)

        XCTAssertEqual(BranchingRecordingCoverRecipe.version, 2)
        XCTAssertEqual(quantized(recipe.center.x), 499_299)
        XCTAssertEqual(quantized(recipe.center.y), 398_408)
        XCTAssertEqual(quantized(recipe.radius), 136_002)
        XCTAssertEqual(quantized(recipe.rotation), 390_388)
        XCTAssertEqual(recipe.litRingIndexes, [5, 6])
        XCTAssertEqual(quantized(recipe.hueShiftDegrees), 11_053_110)
        XCTAssertEqual(recipeDigest(recipe), 0x449C_A376_7EE5_1680)
    }

    func testRepresentativeUUIDsProduceDistinctBoundedSeedGeometry() throws {
        let recipes = try [
            "00112233-4455-6677-8899-AABBCCDDEEFF",
            "11112233-4455-6677-8899-AABBCCDDEEFF",
            "22212233-4455-6677-8899-AABBCCDDEEFF",
            "33312233-4455-6677-8899-AABBCCDDEEFF",
            "44412233-4455-6677-8899-AABBCCDDEEFF",
            "55512233-4455-6677-8899-AABBCCDDEEFF",
        ].map { value in
            BranchingRecordingCoverRecipe(recordingID: try XCTUnwrap(UUID(uuidString: value)))
        }

        for recipe in recipes {
            XCTAssertTrue((0.49...0.51).contains(recipe.center.x))
            XCTAssertTrue((0.39...0.41).contains(recipe.center.y))
            XCTAssertTrue((0.127...0.137).contains(recipe.radius))
            XCTAssertTrue((0..<(Double.pi / 3)).contains(recipe.rotation) || recipe.rotation == Double.pi / 3)
            XCTAssertTrue((1...2).contains(recipe.litRingIndexes.count))
            XCTAssertEqual(recipe.litRingIndexes, recipe.litRingIndexes.sorted())
            XCTAssertTrue(
                recipe.litRingIndexes.allSatisfy { (0..<BranchingRecordingCoverRecipe.ringCount).contains($0) })
            XCTAssertLessThanOrEqual(
                abs(recipe.hueShiftDegrees),
                BranchingRecordingCoverRecipe.maximumHueShiftDegrees + 0.000_001
            )
            XCTAssertTrue(
                [
                    recipe.center.x, recipe.center.y, recipe.radius, recipe.rotation,
                    recipe.hueShiftDegrees, recipe.ink.red, recipe.ink.green, recipe.ink.blue,
                    recipe.pale.red, recipe.pale.green, recipe.pale.blue,
                ].allSatisfy(\.isFinite)
            )
        }

        for (left, right) in zip(recipes, recipes.dropFirst()) {
            XCTAssertNotEqual(left, right)
        }
    }

    func testSampledCoversStayOnOneNightFieldWithoutASecondBrand() throws {
        var litCounts: Set<Int> = []
        var hueShifts: [Double] = []

        for value in 0..<512 {
            let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value)))
            let recipe = BranchingRecordingCoverRecipe(recordingID: id)
            litCounts.insert(recipe.litRingIndexes.count)
            hueShifts.append(recipe.hueShiftDegrees)

            XCTAssertTrue((0.49...0.51).contains(recipe.center.x))
            XCTAssertTrue((0.39...0.41).contains(recipe.center.y))
            XCTAssertTrue((0.127...0.137).contains(recipe.radius))
            XCTAssertLessThanOrEqual(abs(recipe.hueShiftDegrees), 12.000_001)
            XCTAssertNotEqual(recipe.ink.red, recipe.pale.red)
        }

        XCTAssertEqual(litCounts, [1, 2])
        XCTAssertLessThan(hueShifts.min() ?? 0, -4)
        XCTAssertGreaterThan(hueShifts.max() ?? 0, 4)
    }

    private func recipeDigest(_ recipe: BranchingRecordingCoverRecipe) -> UInt64 {
        var digest: UInt64 = 0xCBF2_9CE4_8422_2325

        func append(_ value: UInt64) {
            digest ^= value
            digest &*= 0x0000_0100_0000_01B3
        }

        append(UInt64(BranchingRecordingCoverRecipe.version))
        append(UInt64(bitPattern: quantized(recipe.center.x)))
        append(UInt64(bitPattern: quantized(recipe.center.y)))
        append(UInt64(bitPattern: quantized(recipe.radius)))
        append(UInt64(bitPattern: quantized(recipe.rotation)))
        append(UInt64(recipe.litRingIndexes.count))
        for index in recipe.litRingIndexes {
            append(UInt64(index))
        }
        append(UInt64(bitPattern: quantized(recipe.hueShiftDegrees)))
        append(UInt64(bitPattern: quantized(recipe.ink.red)))
        append(UInt64(bitPattern: quantized(recipe.ink.green)))
        append(UInt64(bitPattern: quantized(recipe.ink.blue)))
        append(UInt64(bitPattern: quantized(recipe.pale.red)))
        append(UInt64(bitPattern: quantized(recipe.pale.green)))
        append(UInt64(bitPattern: quantized(recipe.pale.blue)))
        return digest
    }

    private func quantized(_ value: Double) -> Int64 {
        Int64((value * 1_000_000).rounded())
    }
}
