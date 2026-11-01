import AppKit
import AVFoundation
import CryptoKit
import SwiftUI
import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

private enum SoundFixture {
    static func wave(seconds: Double = 0.1) -> Data {
        let sampleRate: UInt32 = 8_000
        let byteCount = UInt32(Double(sampleRate) * seconds) * 2
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        text("RIFF")
        u32(36 + byteCount)
        text("WAVEfmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(sampleRate)
        u32(sampleRate * 2)
        u16(2)
        u16(16)
        text("data")
        u32(byteCount)
        data.append(Data(count: Int(byteCount)))
        return data
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DictationSoundTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class DictationSoundConfigurationTests: XCTestCase {
    func testDefaultsPreserveExistingCuesAndVolume() {
        let value = DictationSoundConfiguration()
        XCTAssertEqual(value.style, .system)
        XCTAssertEqual(value.volume, 0.4)
        XCTAssertEqual(DictationSoundCue.start.systemSoundName, "Tink")
        XCTAssertEqual(DictationSoundCue.stop.systemSoundName, "Pop")
    }

    func testVolumeNormalizationIncludesSilenceAndNonfiniteValues() {
        for (input, expected) in [(Double.nan, 0.4), (.infinity, 0.4), (-0.5, 0), (1.7, 1), (0, 0)] {
            XCTAssertEqual(DictationSoundConfiguration(volume: input).normalized.volume, expected)
        }
    }

    func testManagedNamesCannotContainPathsOrUnsupportedExtensions() {
        XCTAssertTrue(DictationSoundConfiguration.isManagedFileName("\(UUID()).wav"))
        for invalid in [
            "../outside.wav", "/tmp/test.wav", "sound.wav", "\(UUID()).exe", "\(UUID()).wav/extra", "\(UUID()).wav.wav",
        ] {
            XCTAssertFalse(DictationSoundConfiguration.isManagedFileName(invalid), invalid)
        }
    }

    func testInvalidCustomReferenceFallsBackSafely() {
        let value = DictationSoundConfiguration(style: .custom, customFileName: "../private.wav").normalized
        XCTAssertEqual(value.style, .system)
        XCTAssertNil(value.customFileName)
    }

    func testIndependentSettingsRoundTripAndZeroVolume() throws {
        let suite = "DictationSoundTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = DictationSoundConfiguration(style: .bloom, volume: 0)
        let stop = DictationSoundConfiguration(style: .bloom, volume: 0.73)
        start.save(for: .start, defaults: defaults)
        stop.save(for: .stop, defaults: defaults)
        XCTAssertEqual(DictationSoundConfiguration.load(for: .start, defaults: defaults), start)
        XCTAssertEqual(DictationSoundConfiguration.load(for: .stop, defaults: defaults), stop)
    }

    func testLegacyPresetsMigrateWithoutResettingVolumeOrRetainedImport() throws {
        let suite = "DictationSoundTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fileName = "\(UUID()).wav"
        let aliases: [(String, DictationSoundStyle)] = [
            ("handyPop", .bloom), ("handyMarimba", .bloom), ("pebble", .bloom), ("gong", .gong),
        ]
        for enabled in [false, true] {
            defaults.set(enabled, forKey: "playDictationCaptureSounds")
            for cue in DictationSoundCue.allCases {
                for (legacyName, style) in aliases {
                    for volume in [0.0, 0.73] {
                        let data = try JSONSerialization.data(withJSONObject: [
                            "style": legacyName, "volume": volume,
                            "customFileName": fileName, "customDisplayName": "My sound.wav",
                        ])
                        defaults.set(data, forKey: DictationSoundConfiguration.preferenceKey(for: cue))
                        let value = DictationSoundConfiguration.load(for: cue, defaults: defaults)
                        XCTAssertEqual(
                            value,
                            DictationSoundConfiguration(
                                style: style, volume: volume, customFileName: fileName,
                                customDisplayName: "My sound.wav"))
                        XCTAssertEqual(defaults.bool(forKey: "playDictationCaptureSounds"), enabled)
                        value.save(for: cue, defaults: defaults)
                        let saved = try XCTUnwrap(
                            defaults.data(forKey: DictationSoundConfiguration.preferenceKey(for: cue)))
                        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
                        XCTAssertEqual(json["style"] as? String, style.rawValue)
                    }
                }
            }
        }
    }

    func testEveryCurrentStyleRoundTripsWithoutChangingSilenceOrCustomSelection() throws {
        let suite = "DictationSoundTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for cue in DictationSoundCue.allCases {
            for style in DictationSoundStyle.allCases {
                let value = DictationSoundConfiguration(
                    style: style, volume: 0,
                    customFileName: "\(UUID()).wav", customDisplayName: "Retained sound.wav")
                value.save(for: cue, defaults: defaults)
                XCTAssertEqual(DictationSoundConfiguration.load(for: cue, defaults: defaults), value)
            }
        }
    }

    func testCorruptAndUnknownPreferencesFallBackWithoutTouchingOtherSettings() throws {
        let suite = "DictationSoundTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "playDictationCaptureSounds")
        for data in [Data("not json".utf8), Data(#"{"style":"futureStyle","volume":0.5}"#.utf8)] {
            defaults.set(data, forKey: DictationSoundConfiguration.preferenceKey(for: .start))
            XCTAssertEqual(
                DictationSoundConfiguration.load(for: .start, defaults: defaults), DictationSoundConfiguration())
        }
        XCTAssertTrue(defaults.bool(forKey: "playDictationCaptureSounds"))
    }

    func testPresetResourcesAreDistinctForEachCue() {
        let names = DictationSoundStyle.allCases.flatMap { style in
            DictationSoundCue.allCases.compactMap { style.resourceName(for: $0) }
        }
        XCTAssertEqual(names.count, 4)
        XCTAssertEqual(Set(names).count, 4)
    }
}

final class DictationSoundLibraryTests: XCTestCase {
    func testImportCopiesAudioAndSurvivesDeletingOriginal() async throws {
        let root = try SoundFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("nice cue.WAV")
        let data = SoundFixture.wave()
        try data.write(to: source)
        let library = DictationSoundLibrary(directory: root.appendingPathComponent("owned"))
        let imported = try await library.importSound(from: source)
        XCTAssertEqual(imported.displayName, "nice cue.WAV")
        XCTAssertTrue(DictationSoundConfiguration.isManagedFileName(imported.fileName))
        try FileManager.default.removeItem(at: source)
        let stored = try await library.data(for: imported.fileName)
        XCTAssertEqual(stored, data)
    }

    func testInvalidAudioAndLongAudioLeaveNoOwnedFiles() async throws {
        let root = try SoundFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = root.appendingPathComponent("owned")
        let library = DictationSoundLibrary(directory: owned)
        let source = root.appendingPathComponent("test.wav")
        for data in [Data(), Data("not audio".utf8), SoundFixture.wave(seconds: 6)] {
            try data.write(to: source)
            do {
                _ = try await library.importSound(from: source)
                XCTFail("Invalid cue was imported")
            } catch {
                XCTAssertTrue(error is DictationSoundLibrary.ImportError)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    }

    func testOversizedFileIsRejectedBeforeDecode() async throws {
        let root = try SoundFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("huge.wav")
        try Data(count: DictationSoundLibrary.maximumBytes + 1).write(to: source)
        let library = DictationSoundLibrary(directory: root.appendingPathComponent("owned"))
        do {
            _ = try await library.importSound(from: source)
            XCTFail("Oversized file was imported")
        } catch DictationSoundLibrary.ImportError.tooLarge {}
    }

    func testRemoteURLAndUnsupportedExtensionsAreRejected() async throws {
        let library = DictationSoundLibrary(directory: FileManager.default.temporaryDirectory)
        for url in [URL(string: "https://example.invalid/cue.wav")!, URL(fileURLWithPath: "/tmp/cue.exe")] {
            do {
                _ = try await library.importSound(from: url)
                XCTFail("Unsupported source accepted")
            } catch DictationSoundLibrary.ImportError.unsupportedFile {}
        }
    }

    func testTraversalAndSymlinkCannotReadOrDeleteExternalFile() async throws {
        let root = try SoundFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("outside.wav")
        try SoundFixture.wave().write(to: source)
        let owned = root.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let library = DictationSoundLibrary(directory: owned)
        let link = "\(UUID()).wav"
        try FileManager.default.createSymbolicLink(at: owned.appendingPathComponent(link), withDestinationURL: source)
        for name in ["../outside.wav", source.path, link] {
            do {
                _ = try await library.data(for: name)
                XCTFail("Unsafe read accepted")
            } catch DictationSoundLibrary.ImportError.unsafeFileName {}
            do {
                try await library.remove(name)
                XCTFail("Unsafe removal accepted")
            } catch DictationSoundLibrary.ImportError.unsafeFileName {}
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testCancelledImportLeavesNoOwnedFile() async throws {
        let root = try SoundFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("cue.wav")
        try SoundFixture.wave().write(to: source)
        let owned = root.appendingPathComponent("owned")
        let library = DictationSoundLibrary(directory: owned)
        let task = Task { try await library.importSound(from: source) }
        task.cancel()  // inherited main actor cannot begin the task before this line
        do {
            _ = try await task.value
            XCTFail("Cancelled import succeeded")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    }
}

@MainActor
private final class CueSpy: DictationCuePlaying {
    var isPlaying = false
    var plays: [Float] = []
    var stops = 0
    var playSucceeds = true
    func play(volume: Float) -> Bool {
        isPlaying = playSucceeds
        plays.append(volume)
        return playSucceeds
    }
    func stop() {
        isPlaying = false
        stops += 1
    }
}

@MainActor
private final class PendingSoundRestore {
    let started = XCTestExpectation(description: "Saved sound read started")
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?

    func read() async throws -> Data {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func complete(with result: Result<Data, Error>) {
        self.result = result
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

@MainActor
private final class SoundHarness {
    let suite = "DictationSoundTests.\(UUID())"
    let defaults: UserDefaults
    let root: URL
    let library: DictationSoundLibrary
    let systems: [DictationSoundCue: CueSpy] = [.start: CueSpy(), .stop: CueSpy()]
    var audioPlayers: [CueSpy] = []
    var previewSystems: [CueSpy] = []
    var systemSoundEnabled = true
    var controller: DictationSoundController!

    init(includeAssets: Bool = true) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = try SoundFixture.directory()
        library = DictationSoundLibrary(directory: root.appendingPathComponent("owned"))
        var systemCalls = 0
        controller = DictationSoundController(
            defaults: defaults, library: library,
            makePlayer: { [unowned self] _ in
                let spy = CueSpy()
                audioPlayers.append(spy)
                return spy
            },
            makeSystemPlayer: { [unowned self] cue in
                systemCalls += 1
                if systemCalls <= 2 { return systems[cue] }
                let spy = CueSpy()
                previewSystems.append(spy)
                return spy
            },
            resourceData: { _ in includeAssets ? SoundFixture.wave() : nil },
            soundEffectsEnabled: { [unowned self] in systemSoundEnabled }
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

final class DictationSoundControllerTests: XCTestCase {
    @MainActor
    func testRapidCuesRestartAndDoNotOverlap() async throws {
        let h = try SoundHarness()
        defer { h.cleanup() }
        h.controller.setVolume(0.2, for: .start)
        h.controller.setVolume(0.7, for: .stop)
        h.controller.play(.start)
        h.controller.play(.stop)
        h.controller.play(.start)
        XCTAssertEqual(h.systems[.start]?.plays, [0.2, 0.2])
        XCTAssertEqual(h.systems[.stop]?.plays, [0.7])
        XCTAssertEqual(h.systems[.stop]?.isPlaying, false)
        XCTAssertEqual(h.systems[.start]?.isPlaying, true)
    }

    @MainActor
    func testSilentAndZeroVolumeNeverFallBackToSystem() async throws {
        let h = try SoundHarness()
        defer { h.cleanup() }
        h.controller.play(.start)
        h.controller.setStyle(.silent, for: .stop)
        h.controller.play(.stop)
        XCTAssertEqual(h.systems[.start]?.isPlaying, false)
        XCTAssertEqual(h.systems[.stop]?.plays, [])
        h.controller.setVolume(0, for: .start)
        h.controller.play(.start)
        XCTAssertEqual(h.systems[.start]?.plays.count, 1)
    }

    @MainActor
    func testSystemMuteAppliesToPlaybackAndPreview() async throws {
        let h = try SoundHarness()
        defer { h.cleanup() }
        h.systemSoundEnabled = false
        h.controller.setStyle(.bloom, for: .start)
        h.controller.play(.start)
        XCTAssertTrue(h.audioPlayers.allSatisfy { $0.plays.isEmpty })
        XCTAssertEqual(h.controller.preview(.start), .mutedBySystem)
    }

    @MainActor
    func testMissingPresetFallsBackWithWarning() async throws {
        let h = try SoundHarness(includeAssets: false)
        defer { h.cleanup() }
        h.controller.setStyle(.bloom, for: .start)
        h.controller.play(.start)
        XCTAssertEqual(h.systems[.start]?.plays.count, 1)
        XCTAssertNotNil(h.controller.warnings[.start])
    }

    @MainActor
    func testFailedPresetUsesMatchingSystemFallbackAtConfiguredVolume() throws {
        let h = try SoundHarness()
        defer { h.cleanup() }
        h.controller.setStyle(.bloom, for: .stop)
        h.controller.setVolume(0.7, for: .stop)
        h.audioPlayers.forEach { $0.playSucceeds = false }

        h.controller.play(.stop)

        XCTAssertEqual(h.audioPlayers.flatMap(\.plays), [0.7])
        XCTAssertTrue(h.audioPlayers.allSatisfy { !$0.isPlaying })
        XCTAssertEqual(h.systems[.stop]?.plays, [0.7])
        XCTAssertEqual(h.systems[.start]?.plays, [])
        XCTAssertEqual(h.controller.warnings[.stop], "This sound could not be played. Using Pop instead.")
        XCTAssertEqual(h.controller.preview(.start), .captureCuePlaying)
    }

    @MainActor
    func testFailedCustomSoundUsesSystemFallback() async throws {
        let h = try SoundHarness(includeAssets: false)
        defer { h.cleanup() }
        let source = h.root.appendingPathComponent("cue.wav")
        try SoundFixture.wave().write(to: source)
        try await h.controller.importSound(from: source, for: .start)
        let custom = try XCTUnwrap(h.audioPlayers.last)
        custom.playSucceeds = false

        h.controller.play(.start)

        XCTAssertEqual(custom.plays, [0.4])
        XCTAssertEqual(custom.stops, 1)
        XCTAssertEqual(h.systems[.start]?.plays, [0.4])
        XCTAssertEqual(h.controller.configuration(for: .start).style, .custom)
    }

    @MainActor
    func testFailedCueAndFallbackReportUnavailableAndClearWarningAfterRecovery() throws {
        let h = try SoundHarness()
        defer { h.cleanup() }
        h.controller.setStyle(.bloom, for: .start)
        h.audioPlayers.forEach { $0.playSucceeds = false }
        h.systems[.start]?.playSucceeds = false

        h.controller.play(.start)

        XCTAssertEqual(h.audioPlayers.flatMap(\.plays), [0.4])
        XCTAssertEqual(h.systems[.start]?.plays, [0.4])
        XCTAssertEqual(h.controller.warnings[.start], "This sound could not be played. Choose another sound.")
        XCTAssertEqual(h.controller.preview(.stop), .played, "Failed playback must not own the capture player")

        h.audioPlayers.forEach { $0.playSucceeds = true }
        h.controller.play(.start)
        XCTAssertNil(h.controller.warnings[.start])
        XCTAssertEqual(h.systems[.start]?.plays, [0.4], "Successful selected playback must not use fallback")
    }

    @MainActor
    func testFailedSystemCueIsNotRetriedAsItsOwnFallback() throws {
        let h = try SoundHarness()
        defer { h.cleanup() }
        h.systems[.start]?.playSucceeds = false

        h.controller.play(.start)

        XCTAssertEqual(h.systems[.start]?.plays, [0.4])
        XCTAssertEqual(h.systems[.start]?.stops, 1)
        XCTAssertNotNil(h.controller.warnings[.start])
        XCTAssertEqual(h.controller.preview(.stop), .played)
    }

    @MainActor
    func testOriginalPresetsArePreparedOnceNotOnEachCapture() async throws {
        let h = try SoundHarness()
        defer { h.cleanup() }
        XCTAssertEqual(h.audioPlayers.count, 4)
        h.controller.setStyle(.bloom, for: .start)
        h.controller.play(.start)
        h.controller.play(.start)
        XCTAssertEqual(h.audioPlayers.count, 4)
        XCTAssertEqual(h.audioPlayers.reduce(0) { $0 + $1.plays.count }, 2)
        XCTAssertTrue(h.systems.values.allSatisfy { $0.plays.isEmpty })
    }

    @MainActor
    func testEveryOriginalCueUsesItsOwnCaptureAndPreviewAssetWithoutSystemFallback() throws {
        let h = try SoundHarness(includeAssets: false)
        defer { h.cleanup() }
        let styles: [DictationSoundStyle] = [.bloom, .gong]
        var assets: [String: Data] = [:]
        for style in styles {
            for cue in DictationSoundCue.allCases {
                let name = try XCTUnwrap(style.resourceName(for: cue))
                assets[name] = SoundFixture.wave(seconds: Double(assets.count + 1) / 100)
            }
        }
        var players: [Data: [CueSpy]] = [:]
        let controller = DictationSoundController(
            defaults: h.defaults, library: h.library,
            makePlayer: { data in
                let player = CueSpy()
                players[data, default: []].append(player)
                return player
            },
            makeSystemPlayer: { h.systems[$0] }, resourceData: { assets[$0] },
            soundEffectsEnabled: { true }
        )
        for style in styles {
            for cue in DictationSoundCue.allCases {
                let name = try XCTUnwrap(style.resourceName(for: cue))
                let data = try XCTUnwrap(assets[name])
                let capture = try XCTUnwrap(players[data]?.first)
                let volume = cue == .start ? 0.29 : 0.63
                controller.setStyle(style, for: cue)
                controller.setVolume(volume, for: cue)
                controller.play(cue)
                XCTAssertEqual(capture.plays, [Float(volume)])
                XCTAssertNil(controller.warnings[cue])
                XCTAssertEqual(players[data]?.count, 1, "Capture must reuse its prepared player")

                capture.isPlaying = false  // Simulate playback finishing before preview.
                XCTAssertEqual(controller.preview(cue), .played)
                let preview = try XCTUnwrap(players[data]?.last)
                XCTAssertEqual(players[data]?.count, 2)
                XCTAssertFalse(preview === capture)
                XCTAssertEqual(preview.plays, [Float(volume)])
            }
        }
        XCTAssertTrue(h.systems.values.allSatisfy { $0.plays.isEmpty })
    }

    @MainActor
    func testPreviewIsSeparateAndStoppedByCapture() async throws {
        let h = try SoundHarness()
        defer { h.cleanup() }
        XCTAssertEqual(h.controller.preview(.start), .played)
        XCTAssertEqual(h.previewSystems.count, 1)
        h.controller.play(.start)
        XCTAssertFalse(h.previewSystems[0].isPlaying)
        XCTAssertEqual(h.controller.preview(.stop), .captureCuePlaying)
        XCTAssertTrue(h.systems[.start]!.isPlaying)
    }

    @MainActor
    func testPreviewReportsPlaybackFailureAndCanRetry() async throws {
        let h = try SoundHarness()
        defer { h.cleanup() }
        let failed = CueSpy()
        failed.playSucceeds = false
        var shouldFail = true
        let controller = DictationSoundController(
            defaults: h.defaults, library: h.library,
            makeSystemPlayer: { _ in shouldFail ? failed : CueSpy() },
            resourceData: { _ in nil }, soundEffectsEnabled: { true }
        )
        XCTAssertEqual(controller.preview(.start), .unavailable)
        XCTAssertFalse(failed.isPlaying)
        XCTAssertEqual(failed.stops, 1)
        shouldFail = false
        XCTAssertEqual(controller.preview(.start), .played)
    }

    @MainActor
    func testCustomImportPersistsAndReplacementRemovesOnlyOwnedCopy() async throws {
        let h = try SoundHarness()
        defer { h.cleanup() }
        let source = h.root.appendingPathComponent("cue.wav")
        try SoundFixture.wave().write(to: source)
        try await h.controller.importSound(from: source, for: .start)
        let first = try XCTUnwrap(h.controller.configuration(for: .start).customFileName)
        h.controller.setVolume(0.62, for: .start)
        try await h.controller.importSound(from: source, for: .start)
        let next = h.controller.configuration(for: .start)
        XCTAssertNotEqual(next.customFileName, first)
        XCTAssertEqual(next.volume, 0.62)
        XCTAssertEqual(next.style, .custom)
        XCTAssertEqual(DictationSoundConfiguration.load(for: .start, defaults: h.defaults), next)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("owned/\(first)").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        await h.controller.reset(.start)
        XCTAssertEqual(h.controller.configuration(for: .start), DictationSoundConfiguration())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testFailedImportKeepsPreviousSelectionAndVolume() async throws {
        let h = try SoundHarness()
        defer { h.cleanup() }
        h.controller.setStyle(.bloom, for: .start)
        h.controller.setVolume(0.71, for: .start)
        let before = h.controller.configuration(for: .start)
        let source = h.root.appendingPathComponent("invalid.wav")
        try Data("not audio".utf8).write(to: source)
        do {
            try await h.controller.importSound(from: source, for: .start)
            XCTFail("Invalid import succeeded")
        } catch {}
        XCTAssertEqual(h.controller.configuration(for: .start), before)
        XCTAssertTrue(h.controller.importing.isEmpty)
    }

    @MainActor
    func testSavedMissingCustomSoundFallsBackWithoutErasingPreference() async throws {
        let h = try SoundHarness()
        defer { h.cleanup() }
        let saved = DictationSoundConfiguration(style: .custom, customFileName: "\(UUID()).wav")
        saved.save(for: .start, defaults: h.defaults)
        let controller = DictationSoundController(
            defaults: h.defaults, library: h.library,
            makePlayer: { _ in CueSpy() }, makeSystemPlayer: { h.systems[$0] },
            resourceData: { _ in nil }, soundEffectsEnabled: { true }
        )
        await controller.prepareCustomSounds()
        controller.play(.start)
        XCTAssertNotNil(controller.warnings[.start])
        XCTAssertEqual(controller.configuration(for: .start).customFileName, saved.customFileName)
        XCTAssertEqual(h.systems[.start]?.plays.count, 1)
    }

    @MainActor
    func testImportedSoundPlaysAfterFreshControllerRestoresOwnedCopy() async throws {
        let h = try SoundHarness(includeAssets: false)
        defer { h.cleanup() }
        let source = h.root.appendingPathComponent("cue.wav")
        let data = SoundFixture.wave()
        try data.write(to: source)
        try await h.controller.importSound(from: source, for: .start)
        h.controller.setVolume(0.62, for: .start)
        let saved = h.controller.configuration(for: .start)
        try FileManager.default.removeItem(at: source)
        let restored = CueSpy()
        var loadedData: [Data] = []
        let controller = DictationSoundController(
            defaults: h.defaults, library: h.library,
            makePlayer: { data in
                loadedData.append(data); return restored
            },
            makeSystemPlayer: { h.systems[$0] }, resourceData: { _ in nil },
            soundEffectsEnabled: { true }
        )

        await controller.prepareCustomSounds()
        controller.play(.start)

        XCTAssertEqual(controller.configuration(for: .start), saved)
        XCTAssertEqual(loadedData, [data])
        XCTAssertEqual(restored.plays, [0.62])
        XCTAssertNil(controller.warnings[.start])
        XCTAssertTrue(h.systems.values.allSatisfy { $0.plays.isEmpty })
    }

    @MainActor
    func testLateRestoreCannotReplaceNewImportOrClearItOnFailure() async throws {
        for fails in [false, true] {
            let h = try SoundHarness(includeAssets: false)
            defer { h.cleanup() }
            let source = h.root.appendingPathComponent("cue.wav")
            let oldData = SoundFixture.wave()
            let newData = SoundFixture.wave(seconds: 0.2)
            try oldData.write(to: source)
            try await h.controller.importSound(from: source, for: .start)
            let previous = try XCTUnwrap(h.controller.configuration(for: .start).customFileName)
            let pending = PendingSoundRestore()
            var loadedData: [Data] = []
            let replacement = CueSpy()
            let controller = DictationSoundController(
                defaults: h.defaults, library: h.library,
                loadCustomData: { name in
                    XCTAssertEqual(name, previous)
                    return try await pending.read()
                },
                makePlayer: { data in
                    loadedData.append(data); return replacement
                },
                makeSystemPlayer: { h.systems[$0] }, resourceData: { _ in nil },
                soundEffectsEnabled: { true }
            )
            let restore = Task { await controller.prepareCustomSounds() }
            defer { pending.complete(with: .failure(CancellationError())); restore.cancel() }
            await fulfillment(of: [pending.started], timeout: 2)
            try newData.write(to: source)
            try await controller.importSound(from: source, for: .start)
            let current = try XCTUnwrap(controller.configuration(for: .start).customFileName)
            pending.complete(with: fails ? .failure(DictationSoundLibrary.ImportError.invalidAudio) : .success(oldData))
            await restore.value
            controller.play(.start)

            XCTAssertNotEqual(current, previous)
            XCTAssertEqual(controller.configuration(for: .start).customFileName, current)
            XCTAssertEqual(loadedData, [newData], "A stale successful read must not prepare the old player")
            XCTAssertEqual(replacement.plays, [0.4], "A stale failure must not erase the new player")
            XCTAssertNil(controller.warnings[.start])
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: h.root.appendingPathComponent("owned/\(previous)").path))
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: h.root.appendingPathComponent("owned/\(current)").path))
        }
    }

    @MainActor
    func testLateRestoreCannotUndoResetOrRestoreItsWarning() async throws {
        for fails in [false, true] {
            let h = try SoundHarness(includeAssets: false)
            defer { h.cleanup() }
            let source = h.root.appendingPathComponent("cue.wav")
            let data = SoundFixture.wave()
            try data.write(to: source)
            try await h.controller.importSound(from: source, for: .start)
            let previous = try XCTUnwrap(h.controller.configuration(for: .start).customFileName)
            let pending = PendingSoundRestore()
            var preparedPlayers = 0
            let controller = DictationSoundController(
                defaults: h.defaults, library: h.library,
                loadCustomData: { _ in try await pending.read() },
                makePlayer: { _ in
                    preparedPlayers += 1; return CueSpy()
                },
                makeSystemPlayer: { h.systems[$0] }, resourceData: { _ in nil },
                soundEffectsEnabled: { true }
            )
            let restore = Task { await controller.prepareCustomSounds() }
            defer { pending.complete(with: .failure(CancellationError())); restore.cancel() }
            await fulfillment(of: [pending.started], timeout: 2)
            await controller.reset(.start)
            pending.complete(with: fails ? .failure(DictationSoundLibrary.ImportError.invalidAudio) : .success(data))
            await restore.value
            controller.play(.start)

            XCTAssertEqual(controller.configuration(for: .start), DictationSoundConfiguration())
            XCTAssertEqual(
                DictationSoundConfiguration.load(for: .start, defaults: h.defaults), DictationSoundConfiguration())
            XCTAssertEqual(preparedPlayers, 0)
            XCTAssertEqual(h.systems[.start]?.plays, [0.4])
            XCTAssertNil(controller.warnings[.start])
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: h.root.appendingPathComponent("owned/\(previous)").path))
        }
    }

    @MainActor
    func testActualBundledPresetFilesLoadThroughProductionResourceResolver() async throws {
        let h = try SoundHarness()
        defer { h.cleanup() }
        let expected: [(DictationSoundStyle, DictationSoundCue, String, TimeInterval)] = [
            (.bloom, .start, "c59dc2829470c65c37a864d1fc0125f0898378738fdf29aeaf91f35616d6a410", 0.660),
            (.bloom, .stop, "e56b0fc90c77130ae3ac928d06d6ceedf76a5774393991db475329a2aafaca83", 0.860),
            (.gong, .start, "2411a8b858e6b79994acc0f6a939c492cce121242786187e68d00c4e72c98a42", 0.800),
            (.gong, .stop, "131f0d4d80f3c1dbd93845766e1f252fb6fa0b3e0437f960804bcac5d128b78d", 0.950),
        ]
        var players: [String: CueSpy] = [:]
        let controller = DictationSoundController(
            defaults: h.defaults, library: h.library,
            makePlayer: { data in
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let asset = try XCTUnwrap(expected.first { $0.2 == hash }, "Unexpected bundled audio")
                let audio = try AVAudioPlayer(data: data)
                XCTAssertEqual(audio.duration, asset.3, accuracy: 1 / 48_000)
                XCTAssertEqual(audio.format.sampleRate, 48_000)
                XCTAssertEqual(audio.numberOfChannels, 2)
                let player = CueSpy()
                players[hash] = player
                return player
            },
            makeSystemPlayer: { h.systems[$0] }, soundEffectsEnabled: { true }
        )
        XCTAssertEqual(players.count, expected.count)
        for (style, cue, hash, _) in expected {
            let player = try XCTUnwrap(players[hash])
            controller.setStyle(style, for: cue)
            controller.play(cue)
            XCTAssertEqual(player.plays, [0.4], "Each cue must play its own approved asset, not a swapped file")
            XCTAssertNil(controller.warnings[cue])
        }
        XCTAssertTrue(h.systems.values.allSatisfy { $0.plays.isEmpty })
    }

    @MainActor
    func testSettingsSectionLaysOutAtSettingsWidth() async throws {
        let h = try SoundHarness()
        defer { h.cleanup() }
        let view = NSHostingView(rootView: DictationSoundSettingsSection(controller: h.controller).frame(width: 500))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize.width, 500, accuracy: 1)
        XCTAssertGreaterThan(view.fittingSize.height, 100)
    }
}
