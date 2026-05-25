import XCTest
@testable import MacParakeetCore

/// Pins the bundled fallback catalog (`ModelProfileService.bundledCatalogJSON`)
/// against the on-disk `Resources/model-profiles.json`. The two are
/// expected to be byte-equivalent in content — the on-disk file is the
/// remote-hosted version, the Swift literal is the offline safety net.
/// Drift between them means users on stale builds would get different
/// behavior than what the docs / repo claim.
final class ModelProfileCatalogTests: XCTestCase {

    func testBundledCatalogMatchesRepoFile() throws {
        // Walk from this test file up to the repo root, then into Resources/.
        // #filePath = .../Tests/MacParakeetTests/Services/ModelProfileCatalogTests.swift
        let repoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Services/
            .deletingLastPathComponent()  // MacParakeetTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Resources/model-profiles.json")

        let repoData = try Data(contentsOf: repoURL)
        let repoCatalog = try JSONDecoder().decode(RemoteProfileCatalog.self, from: repoData)

        let bundledData = try XCTUnwrap(
            ModelProfileService.bundledCatalogJSON.data(using: .utf8),
            "bundled catalog must be valid UTF-8"
        )
        let bundledCatalog = try JSONDecoder().decode(RemoteProfileCatalog.self, from: bundledData)

        XCTAssertEqual(
            repoCatalog, bundledCatalog,
            "Resources/model-profiles.json and ModelProfileService.bundledCatalogJSON have drifted. Update both."
        )
    }

    /// Quick self-check: every profile in the bundled catalog has at least
    /// one pattern (otherwise the matcher would never select it) and a
    /// `batchSizes` map that covers every `SizeClass` raw value.
    func testBundledCatalogProfilesAreWellFormed() throws {
        let bundledData = try XCTUnwrap(ModelProfileService.bundledCatalogJSON.data(using: .utf8))
        let catalog = try JSONDecoder().decode(RemoteProfileCatalog.self, from: bundledData)
        XCTAssertFalse(catalog.profiles.isEmpty)
        let expectedSizeKeys: Set<String> = ["small", "medium", "large", "unknown"]
        for profile in catalog.profiles {
            XCTAssertFalse(profile.patterns.isEmpty, "profile \(profile.displayName) has no patterns")
            XCTAssertFalse(profile.displayName.isEmpty)
            // batchSizes can be a superset — the matcher takes whichever
            // SizeClass.rawValue is current — but the four canonical keys
            // must be present so a missing field never produces a 0 batch.
            XCTAssertTrue(
                expectedSizeKeys.isSubset(of: Set(profile.batchSizes.keys)),
                "profile \(profile.displayName) missing one of \(expectedSizeKeys); has \(profile.batchSizes.keys)"
            )
            for (_, value) in profile.batchSizes {
                XCTAssertGreaterThanOrEqual(value, 1)
                XCTAssertLessThanOrEqual(value, 10)
            }
        }
    }
}
