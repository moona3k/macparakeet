import Foundation
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

    func testAdaptiveReferenceDelayDefaultsOnAndParsesEnvironment() {
        XCTAssertTrue(
            MeetingEchoSuppressionConfiguration().adaptiveReferenceDelay,
            "adaptive delay recovery is on by default")

        let disabled = MeetingEchoSuppressionConfiguration.fromEnvironment([
            MeetingEchoSuppressionConfiguration.adaptiveReferenceDelayEnvironmentKey: " OFF "
        ])
        XCTAssertFalse(disabled.adaptiveReferenceDelay)

        let enabled = MeetingEchoSuppressionConfiguration.fromEnvironment([
            MeetingEchoSuppressionConfiguration.adaptiveReferenceDelayEnvironmentKey: "1"
        ])
        XCTAssertTrue(enabled.adaptiveReferenceDelay)
    }

    func testReferenceDelayDefaultsToZeroAndClampsNegative() {
        XCTAssertEqual(MeetingEchoSuppressionConfiguration().referenceDelayMs, 0)
        XCTAssertEqual(
            MeetingEchoSuppressionConfiguration(referenceDelayMs: -50).referenceDelayMs,
            0
        )
    }

    func testReferenceDelaySampleBoundsStayFinite() {
        XCTAssertEqual(
            MeetingEchoSuppressionFactory.adaptiveReferenceDelaySearchCeiling(sampleRate: 16_000),
            3_200
        )
        XCTAssertEqual(
            MeetingEchoSuppressionFactory.boundedReferenceDelaySamples(referenceDelayMs: 75, sampleRate: 16_000),
            1_200
        )
        XCTAssertFalse(
            MeetingEchoSuppressionFactory.referenceDelayExceedsSearchCeiling(
                referenceDelayMs: 200,
                sampleRate: 16_000
            )
        )
        XCTAssertEqual(
            MeetingEchoSuppressionFactory.boundedReferenceDelaySamples(
                referenceDelayMs: 10_000,
                sampleRate: 16_000
            ),
            3_200
        )
        XCTAssertTrue(
            MeetingEchoSuppressionFactory.referenceDelayExceedsSearchCeiling(
                referenceDelayMs: 10_000,
                sampleRate: 16_000
            )
        )
    }

    func testDefaultFrameSizeMatchesLocalVQEHopLengthFallback() {
        let configuration = MeetingEchoSuppressionConfiguration()

        XCTAssertEqual(configuration.frameSize, 256)
    }

    func testDefaultModelNameUsesSelectedV14EchoOnlyModel() {
        XCTAssertEqual(
            MeetingEchoSuppressionFactory.defaultModelName,
            "localvqe-v1.4-aec-200K-f32.gguf"
        )
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

    func testBundledModelCandidatesPreferKnownEchoModelsAndDiscoverUnknownSingleModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("EchoAssets.bundle", isDirectory: true)
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let modelDirectory = resourcesURL
            .appendingPathComponent(
                MeetingEchoSuppressionFactory.defaultModelDirectoryName,
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleIdentifier</key>
          <string>com.macparakeet.tests.EchoAssets</string>
          <key>CFBundlePackageType</key>
          <string>BNDL</string>
        </dict>
        </plist>
        """.write(
            to: bundleURL.appendingPathComponent("Contents/Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        try Data("v14".utf8).write(
            to: modelDirectory.appendingPathComponent(
                MeetingEchoSuppressionFactory.defaultModelName
            )
        )
        try Data("v12".utf8).write(
            to: modelDirectory.appendingPathComponent(
                MeetingEchoSuppressionFactory.legacyJointModelName
            )
        )
        try Data("custom".utf8).write(
            to: modelDirectory.appendingPathComponent("custom-localvqe-test.gguf")
        )
        let nonModelURL = modelDirectory.appendingPathComponent("not-a-model.txt")
        try Data("not a model".utf8).write(to: nonModelURL)
        try FileManager.default.createSymbolicLink(
            at: modelDirectory.appendingPathComponent("linked-localvqe-test.gguf"),
            withDestinationURL: nonModelURL
        )

        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let candidateURLs = MeetingEchoSuppressionFactory.bundledModelCandidates(
            configuration: MeetingEchoSuppressionConfiguration(),
            bundle: bundle,
            fileManager: .default
        )
        let candidates = candidateURLs.compactMap { $0?.lastPathComponent }

        let firstCandidate = try XCTUnwrap(candidateURLs.first)
        XCTAssertNil(firstCandidate)
        XCTAssertEqual(candidates[0], MeetingEchoSuppressionFactory.defaultModelName)
        XCTAssertTrue(candidates.contains(MeetingEchoSuppressionFactory.legacyJointModelName))
        XCTAssertEqual(candidates.last, "custom-localvqe-test.gguf")
        XCTAssertFalse(candidates.contains("linked-localvqe-test.gguf"))
    }

    func testDynamicModeLoadsABICompatibleRuntimeAndProcessesInsteadOfPassthrough() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let libraryURL = root.appendingPathComponent("liblocalvqe.dylib")
        let modelURL = root.appendingPathComponent("localvqe-v1.4-aec-200K-f32.gguf")
        try Self.writeLocalVQEDylib(to: libraryURL)
        try Data("stub model".utf8).write(to: modelURL)

        let conditioner = MeetingEchoSuppressionFactory.makeConditioner(
            configuration: MeetingEchoSuppressionConfiguration(
                mode: .dynamicLibrary,
                libraryURL: libraryURL,
                modelURL: modelURL,
                modelSHA256: try MeetingEchoSuppressionFactory.sha256Hex(for: modelURL)
            ),
            bundle: Bundle(for: Self.self)
        )

        let microphone = [Float](repeating: 1.0, count: 256)
        let speaker = [Float](repeating: 0.25, count: 256)
        let output = conditioner.condition(
            microphone: microphone,
            speaker: speaker,
            hasSpeakerReference: true
        )

        XCTAssertEqual(conditioner.diagnostics.processorName, "localvqe")
        XCTAssertTrue(conditioner.diagnostics.loaded)
        XCTAssertEqual(output.count, microphone.count)
        XCTAssertEqual(output.first ?? .nan, 0.75, accuracy: 0.0001)
        XCTAssertEqual(conditioner.diagnostics.processedFrames, 1)
    }

    func testRealLocalVQERuntimeLoadsWhenTestAssetsAreProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let libraryPath = environment["MACPARAKEET_TEST_LOCALVQE_LIBRARY"],
              let modelPath = environment["MACPARAKEET_TEST_LOCALVQE_MODEL"]
        else {
            throw XCTSkip(
                "Set MACPARAKEET_TEST_LOCALVQE_LIBRARY and MACPARAKEET_TEST_LOCALVQE_MODEL to run real LocalVQE load verification."
            )
        }

        let conditioner = MeetingEchoSuppressionFactory.makeConditioner(
            configuration: MeetingEchoSuppressionConfiguration(
                mode: .dynamicLibrary,
                libraryURL: URL(fileURLWithPath: libraryPath),
                modelURL: URL(fileURLWithPath: modelPath),
                modelSHA256: environment["MACPARAKEET_TEST_LOCALVQE_MODEL_SHA256"]
            ),
            bundle: Bundle(for: Self.self)
        )

        let microphone = (0..<256).map { Float($0 % 17) / 17.0 }
        let speaker = (0..<256).map { Float(($0 + 3) % 19) / 38.0 }
        let output = conditioner.condition(
            microphone: microphone,
            speaker: speaker,
            hasSpeakerReference: true
        )

        XCTAssertEqual(conditioner.diagnostics.processorName, "localvqe")
        XCTAssertTrue(conditioner.diagnostics.loaded)
        XCTAssertEqual(output.count, microphone.count)
        XCTAssertEqual(conditioner.diagnostics.processedFrames, 1)
    }

    func testDistributionVerifierAcceptsSelectedModelNameWithValidRuntime() throws {
        let appURL = try Self.makeEchoAssetAppBundle(
            modelName: "localvqe-v1.4-aec-200K-f32.gguf",
            modelData: Data("model".utf8),
            includeLibrary: true
        )
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let modelURL = appURL.appendingPathComponent(
            "Contents/Resources/MeetingEchoSuppression/localvqe-v1.4-aec-200K-f32.gguf"
        )

        let result = try Self.runVerifier(
            appURL: appURL,
            environment: [
                "REQUIRE_MEETING_ECHO_ASSETS": "1",
                "MACPARAKEET_MEETING_ECHO_MODEL_NAME": "localvqe-v1.4-aec-200K-f32.gguf",
                "MACPARAKEET_MEETING_ECHO_MODEL_SHA256": try MeetingEchoSuppressionFactory.sha256Hex(
                    for: modelURL
                ).uppercased(),
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Meeting echo assets verified"))
    }

    func testDistributionVerifierAcceptsDefaultModelWithExplicitMatchingChecksum() throws {
        let appURL = try Self.makeEchoAssetAppBundle(
            modelName: MeetingEchoSuppressionFactory.defaultModelName,
            modelData: Data("model".utf8),
            includeLibrary: true
        )
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let modelURL = appURL.appendingPathComponent(
            "Contents/Resources/MeetingEchoSuppression/" +
                MeetingEchoSuppressionFactory.defaultModelName
        )

        let result = try Self.runVerifier(
            appURL: appURL,
            environment: [
                "REQUIRE_MEETING_ECHO_ASSETS": "1",
                "MACPARAKEET_MEETING_ECHO_MODEL_SHA256": try MeetingEchoSuppressionFactory.sha256Hex(
                    for: modelURL
                ),
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Meeting echo assets verified"))
    }

    func testDistributionVerifierFailsWhenRequiredAssetsAreMissing() throws {
        let appURL = try Self.makeEmptyAppBundle()
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let result = try Self.runVerifier(
            appURL: appURL,
            environment: ["REQUIRE_MEETING_ECHO_ASSETS": "1"]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("meeting echo assets are required"))
    }

    func testDistributionVerifierFailsWhenOnlyOneAssetExists() throws {
        let appURL = try Self.makeEchoAssetAppBundle(
            modelName: "localvqe-v1.4-aec-200K-f32.gguf",
            modelData: Data("model".utf8),
            includeLibrary: false
        )
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let result = try Self.runVerifier(
            appURL: appURL,
            environment: ["REQUIRE_MEETING_ECHO_ASSETS": "1"]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("must be bundled together"))
    }

    func testDistributionVerifierRejectsAmbiguousBundledModelsEvenWithSelectedName() throws {
        let appURL = try Self.makeEchoAssetAppBundle(
            modelName: "localvqe-v1.4-aec-200K-f32.gguf",
            modelData: Data("model".utf8),
            includeLibrary: true
        )
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let secondModelURL = appURL.appendingPathComponent(
            "Contents/Resources/MeetingEchoSuppression/" +
                MeetingEchoSuppressionFactory.legacyJointModelName
        )
        try Data("second model".utf8).write(to: secondModelURL)

        let result = try Self.runVerifier(
            appURL: appURL,
            environment: [
                "REQUIRE_MEETING_ECHO_ASSETS": "1",
                "MACPARAKEET_MEETING_ECHO_MODEL_NAME": "localvqe-v1.4-aec-200K-f32.gguf",
            ]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("exactly one meeting echo model must be bundled"))
    }

    func testDistributionVerifierRejectsDefaultModelChecksumMismatchWithoutEnv() throws {
        let appURL = try Self.makeEchoAssetAppBundle(
            modelName: MeetingEchoSuppressionFactory.defaultModelName,
            modelData: Data("model".utf8),
            includeLibrary: true
        )
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let result = try Self.runVerifier(appURL: appURL)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("SHA256 mismatch"))
    }

    func testDistributionVerifierRejectsExplicitChecksumMismatch() throws {
        let appURL = try Self.makeEchoAssetAppBundle(
            modelName: MeetingEchoSuppressionFactory.defaultModelName,
            modelData: Data("model".utf8),
            includeLibrary: true
        )
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let result = try Self.runVerifier(
            appURL: appURL,
            environment: [
                "REQUIRE_MEETING_ECHO_ASSETS": "1",
                "MACPARAKEET_MEETING_ECHO_MODEL_SHA256": String(repeating: "0", count: 64),
            ]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("SHA256 mismatch"))
    }

    func testDistributionVerifierRejectsStrictCustomModelWithoutChecksum() throws {
        let appURL = try Self.makeEchoAssetAppBundle(
            modelName: "custom-aec-model.gguf",
            modelData: Data("model".utf8),
            includeLibrary: true
        )
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let result = try Self.runVerifier(
            appURL: appURL,
            environment: ["REQUIRE_MEETING_ECHO_ASSETS": "1"]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains("requires MACPARAKEET_MEETING_ECHO_MODEL_SHA256"),
            result.output
        )
    }

    func testDistributionVerifierRejectsRuntimeMissingRequiredSymbols() throws {
        let appURL = try Self.makeEchoAssetAppBundle(
            modelName: MeetingEchoSuppressionFactory.defaultModelName,
            modelData: Data("model".utf8),
            includeLibrary: true,
            includeRequiredSymbols: false
        )
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let result = try Self.runVerifier(
            appURL: appURL,
            environment: ["REQUIRE_MEETING_ECHO_ASSETS": "1"]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("missing required LocalVQE symbols"))
    }

    func testDistributionVerifierAcceptsUniversalRuntime() throws {
        let appURL = try Self.makeEchoAssetAppBundle(
            modelName: "localvqe-v1.4-aec-200K-f32.gguf",
            modelData: Data("model".utf8),
            includeLibrary: true,
            universalLibrary: true
        )
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let modelURL = appURL.appendingPathComponent(
            "Contents/Resources/MeetingEchoSuppression/localvqe-v1.4-aec-200K-f32.gguf"
        )
        let result = try Self.runVerifier(
            appURL: appURL,
            environment: [
                "REQUIRE_MEETING_ECHO_ASSETS": "1",
                "MACPARAKEET_MEETING_ECHO_MODEL_SHA256": try MeetingEchoSuppressionFactory.sha256Hex(
                    for: modelURL
                ),
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Meeting echo assets verified"))
    }

    private static func makeEmptyAppBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = root.appendingPathComponent("MacParakeet.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        return appURL
    }

    private static func makeEchoAssetAppBundle(
        modelName: String,
        modelData: Data,
        includeLibrary: Bool,
        includeRequiredSymbols: Bool = true,
        universalLibrary: Bool = false
    ) throws -> URL {
        let appURL = try makeEmptyAppBundle()
        let frameworksURL = appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let modelDirectory = appURL.appendingPathComponent(
            "Contents/Resources/MeetingEchoSuppression",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: frameworksURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        try modelData.write(to: modelDirectory.appendingPathComponent(modelName))
        if includeLibrary {
            try writeLocalVQEDylib(
                to: frameworksURL.appendingPathComponent("liblocalvqe.dylib"),
                includeRequiredSymbols: includeRequiredSymbols,
                universal: universalLibrary
            )
        }
        return appURL
    }

    private static func writeLocalVQEDylib(
        to libraryURL: URL,
        includeRequiredSymbols: Bool = true,
        universal: Bool = false
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/clang") else {
            throw XCTSkip("clang is required to compile the LocalVQE ABI test runtime.")
        }

        let sourceURL = libraryURL.deletingLastPathComponent()
            .appendingPathComponent("localvqe_stub.c")
        let source: String
        if includeRequiredSymbols {
            source = """
            #include <stdint.h>
            uintptr_t localvqe_new(const char *path) { return path ? 1 : 0; }
            int32_t localvqe_process_frame_f32(
              uintptr_t ctx,
              const float *mic,
              const float *ref,
              int32_t n,
              float *out
            ) {
              if (!ctx || !mic || !ref || !out) { return -1; }
              for (int32_t i = 0; i < n; i++) { out[i] = mic[i] - ref[i]; }
              return 0;
            }
            void localvqe_reset(uintptr_t ctx) { (void)ctx; }
            void localvqe_free(uintptr_t ctx) { (void)ctx; }
            """
        } else {
            source = "int localvqe_unrelated_symbol(void) { return 1; }\n"
        }
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        var arguments = ["-dynamiclib", sourceURL.path]
        if universal {
            arguments += ["-arch", "arm64", "-arch", "x86_64"]
        }
        arguments += ["-install_name", "@rpath/liblocalvqe.dylib", "-o", libraryURL.path]
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        if universal && process.terminationStatus != 0 {
            throw XCTSkip("Universal (arm64+x86_64) cross-compile unavailable: \(output)")
        }
        XCTAssertEqual(process.terminationStatus, 0, output)
    }

    private static func runVerifier(
        appURL: URL,
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        let verifierURL = try repoRoot()
            .appendingPathComponent("scripts/dist/verify_meeting_echo_assets.sh")
        process.arguments = [
            verifierURL.path,
            appURL.path,
        ]
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
        ].merging(environment) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (process.terminationStatus, output)
    }

    private static func repoRoot(filePath: String = #filePath) throws -> URL {
        var url = URL(fileURLWithPath: filePath)
        if !url.hasDirectoryPath {
            url.deleteLastPathComponent()
        }
        while true {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path
            ) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else {
                throw NSError(
                    domain: "MeetingEchoSuppressionRuntimeTests",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not find Package.swift from test file path: \(filePath)"
                    ]
                )
            }
            url = parent
        }
    }
}
