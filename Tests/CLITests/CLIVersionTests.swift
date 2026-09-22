import XCTest
@testable import CLI

/// The CLI's `--version` and `spec --json` output are a public automation
/// contract. These tests pin `CLI.cliVersion` to the latest *released* section
/// header in `Sources/CLI/CHANGELOG.md`, so a forgotten bump can't silently
/// ship a binary that reports a stale version (the `2.9.0`-while-`2.10.0`-shipped
/// drift caught in the 2026-06-21 audit).
final class CLIVersionTests: XCTestCase {
    func testCLIVersionMatchesLatestReleasedChangelogEntry() throws {
        let changelog = try String(contentsOf: Self.changelogURL, encoding: .utf8)
        let latestReleased = try XCTUnwrap(
            Self.firstReleasedVersion(in: changelog),
            "Could not find a released `## [x.y.z] -- date` header in CHANGELOG.md"
        )

        XCTAssertEqual(
            CLI.cliVersion,
            latestReleased,
            """
            CLI.cliVersion (\(CLI.cliVersion)) must equal the latest released \
            CHANGELOG header ([\(latestReleased)]). Bump \
            `MacParakeetCLI.cliVersion` in lockstep with Sources/CLI/CHANGELOG.md.
            """
        )
    }

    func testCLIVersionIsSemver() {
        let components = CLI.cliVersion.split(separator: ".")
        XCTAssertEqual(components.count, 3, "cliVersion must be MAJOR.MINOR.PATCH")
        XCTAssertTrue(
            components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) },
            "cliVersion components must be numeric: \(CLI.cliVersion)"
        )
    }

    // MARK: - Helpers

    /// `Sources/CLI/CHANGELOG.md`, located relative to this test file so the
    /// check is independent of the working directory or checkout location.
    private static var changelogURL: URL {
        URL(fileURLWithPath: #filePath)   // Tests/CLITests/CLIVersionTests.swift
            .deletingLastPathComponent()  // Tests/CLITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/CLI/CHANGELOG.md")
    }

    /// Version string of the first `## [x.y.z] -- ...` header, skipping the
    /// `## [Unreleased]` section (whose bracket token is non-numeric).
    private static func firstReleasedVersion(in changelog: String) -> String? {
        for rawLine in changelog.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("## ["),
                  let open = line.firstIndex(of: "["),
                  let close = line.firstIndex(of: "]"),
                  open < close else { continue }
            let token = String(line[line.index(after: open)..<close])
            if token.first?.isNumber == true { return token }
        }
        return nil
    }
}
