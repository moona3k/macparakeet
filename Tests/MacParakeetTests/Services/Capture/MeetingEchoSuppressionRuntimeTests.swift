import XCTest
@testable import MacParakeetCore

final class MeetingEchoSuppressionRuntimeTests: XCTestCase {
    func testConfigurationParsesEnvironmentAliases() {
        let configuration = MeetingEchoSuppressionConfiguration.fromEnvironment([
            MeetingEchoSuppressionConfiguration.modeEnvironmentKey: "localvqe",
            MeetingEchoSuppressionConfiguration.libraryPathEnvironmentKey: "/tmp/libecho.dylib",
            MeetingEchoSuppressionConfiguration.modelPathEnvironmentKey: "file:///tmp/model.gguf",
            MeetingEchoSuppressionConfiguration.modelSHA256EnvironmentKey: " ABC123 ",
            MeetingEchoSuppressionConfiguration.sampleRateEnvironmentKey: " 48000 ",
            MeetingEchoSuppressionConfiguration.frameSizeEnvironmentKey: " 256 ",
            MeetingEchoSuppressionConfiguration.referenceDelayMsEnvironmentKey: " 120 ",
        ])

        XCTAssertEqual(configuration.mode, .dynamicLibrary)
        XCTAssertEqual(configuration.libraryURL?.path, "/tmp/libecho.dylib")
        XCTAssertEqual(configuration.modelURL?.path, "/tmp/model.gguf")
        XCTAssertEqual(configuration.modelSHA256, "abc123")
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.frameSize, 256)
        XCTAssertEqual(configuration.referenceDelayMs, 120)
    }

    func testReferenceDelayDefaultsToZeroAndClampsNegative() {
        XCTAssertEqual(MeetingEchoSuppressionConfiguration().referenceDelayMs, 0)
        XCTAssertEqual(
            MeetingEchoSuppressionConfiguration(referenceDelayMs: -50).referenceDelayMs,
            0
        )
    }

    func testDefaultFrameSizeMatchesLocalVQEHopLengthFallback() {
        let configuration = MeetingEchoSuppressionConfiguration()

        XCTAssertEqual(configuration.frameSize, 256)
    }

    func testConfigurationParsesUnescapedFileURLWithSpaces() {
        let configuration = MeetingEchoSuppressionConfiguration.fromEnvironment([
            MeetingEchoSuppressionConfiguration.modelPathEnvironmentKey:
                "file:///tmp/meeting echo/local model.gguf",
        ])

        XCTAssertEqual(configuration.modelURL?.path, "/tmp/meeting echo/local model.gguf")
    }

    func testAutomaticWithoutAssetsUsesLoadedPassthrough() {
        let conditioner = MeetingEchoSuppressionFactory.makeConditioner(
            configuration: MeetingEchoSuppressionConfiguration(mode: .automatic),
            bundle: Bundle(for: Self.self)
        )

        XCTAssertEqual(conditioner.condition(microphone: [0.1, 0.2], speaker: [0.5]), [0.1, 0.2])
        XCTAssertEqual(conditioner.diagnostics.processorName, "passthrough")
        XCTAssertTrue(conditioner.diagnostics.loaded)
    }

    func testDynamicModeWithoutAssetsUsesUnavailableDiagnostic() {
        let conditioner = MeetingEchoSuppressionFactory.makeConditioner(
            configuration: MeetingEchoSuppressionConfiguration(
                mode: .dynamicLibrary,
                libraryURL: URL(fileURLWithPath: "/tmp/missing-echo-runtime.dylib"),
                modelURL: URL(fileURLWithPath: "/tmp/missing-echo-model.gguf")
            ),
            bundle: Bundle(for: Self.self)
        )

        XCTAssertEqual(conditioner.condition(microphone: [0.1, 0.2], speaker: [0.5]), [0.1, 0.2])
        XCTAssertEqual(conditioner.diagnostics.processorName, "localvqe")
        XCTAssertFalse(conditioner.diagnostics.loaded)
    }

    func testFactoryRejectsChecksumMismatchBeforeLoadingLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let libraryURL = root.appendingPathComponent("liblocalvqe.dylib")
        let modelURL = root.appendingPathComponent("localvqe-v1.2-1.3M-f32.gguf")
        try Data("not-a-real-dylib".utf8).write(to: libraryURL)
        try Data("model".utf8).write(to: modelURL)

        let conditioner = MeetingEchoSuppressionFactory.makeConditioner(
            configuration: MeetingEchoSuppressionConfiguration(
                mode: .dynamicLibrary,
                libraryURL: libraryURL,
                modelURL: modelURL,
                modelSHA256: "0000"
            ),
            bundle: Bundle(for: Self.self)
        )

        XCTAssertEqual(conditioner.diagnostics.processorName, "localvqe")
        XCTAssertFalse(conditioner.diagnostics.loaded)
    }

    func testSHA256HexIsStable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("fixture.txt")
        try Data("abc".utf8).write(to: fileURL)

        XCTAssertEqual(
            try MeetingEchoSuppressionFactory.sha256Hex(for: fileURL),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
