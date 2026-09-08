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
            0x65B5_0BE2_B5BB_4987
        )
    }

    func testSameUUIDAlwaysProducesTheSameRecipe() throws {
        let id = try XCTUnwrap(UUID(uuidString: "85B4897C-4F5D-4ED1-94EB-C0B5841B1EF5"))

        XCTAssertEqual(
            BranchingRecordingCoverRecipe(recordingID: id),
            BranchingRecordingCoverRecipe(recordingID: id)
        )
    }

    func testRepresentativeUUIDPinsV1PaletteFocalPointAndGeometry() throws {
        let id = try XCTUnwrap(UUID(uuidString: "85B4897C-4F5D-4ED1-94EB-C0B5841B1EF5"))
        let recipe = BranchingRecordingCoverRecipe(recordingID: id)

        XCTAssertEqual(recipe.palette.family, .tidalStone)
        XCTAssertEqual(recipe.palette.variant, 0)
        XCTAssertEqual(quantized(recipe.focalPoint.x), 453_199)
        XCTAssertEqual(quantized(recipe.focalPoint.y), 435_403)
        XCTAssertEqual(recipeDigest(recipe), 0xE13C_E9C0_6B60_0272)
    }

    func testRepresentativeUUIDsProduceDistinctBoundedFiniteGeometry() throws {
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
            XCTAssertLessThanOrEqual(recipe.limbs.count, BranchingRecordingCoverRecipe.maximumLimbCount)
            XCTAssertFalse(recipe.limbs.isEmpty)
            XCTAssertTrue((5...6).contains(recipe.limbs.filter { $0.depth == 0 }.count))
            XCTAssertTrue(recipe.focalPoint.x.isFinite)
            XCTAssertTrue(recipe.focalPoint.y.isFinite)
            XCTAssertTrue(
                recipe.limbs.allSatisfy { limb in
                    [
                        limb.start.x, limb.start.y, limb.control.x, limb.control.y,
                        limb.end.x, limb.end.y, limb.startWidth, limb.endWidth, limb.opacity,
                    ].allSatisfy(\.isFinite)
                })
        }

        for (left, right) in zip(recipes, recipes.dropFirst()) {
            XCTAssertNotEqual(left, right)
        }
    }

    func testUUIDPaletteSelectionCoversTheThreeCuratedFamiliesWithoutQuotas() throws {
        let recipes = try (0..<96).map { value in
            let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value)))
            return BranchingRecordingCoverRecipe(recordingID: id)
        }

        XCTAssertEqual(Set(recipes.map(\.palette.family)), Set(BranchingRecordingCoverPalette.Family.allCases))
        XCTAssertTrue(recipes.allSatisfy { 0..<BranchingRecordingCoverPalette.variantCount ~= $0.palette.variant })
    }

    func testSampledGeometryStaysWithinTheAcceptedClippedCoordinateBound() throws {
        for value in 0..<512 {
            let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value)))
            let recipe = BranchingRecordingCoverRecipe(recordingID: id)
            let coordinates = recipe.limbs.flatMap { limb in
                [
                    limb.start.x, limb.start.y,
                    limb.control.x, limb.control.y,
                    limb.end.x, limb.end.y,
                ]
            }

            XCTAssertTrue(
                coordinates.allSatisfy {
                    abs($0) <= BranchingRecordingCoverRecipe.maximumNormalizedCoordinateMagnitude
                },
                "UUID \(id) exceeded the static Canvas composition bound"
            )
        }
    }

    private func recipeDigest(_ recipe: BranchingRecordingCoverRecipe) -> UInt64 {
        var digest: UInt64 = 0xCBF2_9CE4_8422_2325

        func append(_ value: UInt64) {
            digest ^= value
            digest &*= 0x0000_0100_0000_01B3
        }

        append(UInt64(BranchingRecordingCoverRecipe.version))
        append(UInt64(BranchingRecordingCoverPalette.Family.allCases.firstIndex(of: recipe.palette.family)!))
        append(UInt64(recipe.palette.variant))
        append(UInt64(recipe.limbs.count))
        append(UInt64(bitPattern: quantized(recipe.focalPoint.x)))
        append(UInt64(bitPattern: quantized(recipe.focalPoint.y)))

        for limb in recipe.limbs {
            append(UInt64(bitPattern: quantized(limb.start.x)))
            append(UInt64(bitPattern: quantized(limb.start.y)))
            append(UInt64(bitPattern: quantized(limb.control.x)))
            append(UInt64(bitPattern: quantized(limb.control.y)))
            append(UInt64(bitPattern: quantized(limb.end.x)))
            append(UInt64(bitPattern: quantized(limb.end.y)))
            append(UInt64(bitPattern: quantized(limb.startWidth)))
            append(UInt64(bitPattern: quantized(limb.endWidth)))
            append(UInt64(limb.depth))
            append(UInt64(pigmentIndex(limb.pigment)))
            append(UInt64(bitPattern: quantized(limb.opacity)))
        }

        return digest
    }

    private func quantized(_ value: Double) -> Int64 {
        Int64((value * 1_000_000).rounded())
    }

    private func pigmentIndex(_ pigment: BranchingRecordingCoverPigment) -> Int {
        switch pigment {
        case .field: 0
        case .branch: 1
        case .accent: 2
        }
    }
}
