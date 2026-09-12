import XCTest

/// Guards the telemetry boundary for voice profiles by reading the source: the
/// feature must emit nothing beyond whether the preference is on.
///
/// A source scan rather than a behavioural test because the invariant is the
/// *absence* of calls. Nothing a runtime test observes can prove a call that
/// was never written, and the cheapest way to break this is to add one.
final class SpeakerVoiceprintTelemetryTests: XCTestCase {
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Diarization
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // MacParakeetTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources")
    }

    /// Enumerated rather than listed. A fixed list fails open: the next
    /// voiceprint file is simply not covered, which is exactly when a review
    /// would rely on this test.
    private func voiceprintSources() throws -> [URL] {
        let names = ["Speaker", "Voiceprint", "VoiceProfile"]
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot, includingPropertiesForKeys: nil
        )
        var found: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard names.contains(where: name.contains) else { continue }
            // Diarization itself predates voice profiles and legitimately
            // reports; only the identity layer is in scope here.
            guard !["SpeakerMerger", "SpeakerAttributionResolver"].contains(name) else { continue }
            found.append(url)
        }
        return found
    }

    func testTheScanFindsTheVoiceprintSources() throws {
        let names = Set(try voiceprintSources().map { $0.deletingPathExtension().lastPathComponent })
        // Sentinels across every layer, so a moved or renamed file is noticed
        // rather than silently dropping out of the scan.
        for expected in [
            "SpeakerVoiceprintService", "SpeakerVoiceprintMatcher", "SpeakerEmbedding",
            "SpeakerProfileRepository", "SpeakerEmbeddingCandidateRepository",
            "VoiceProfilesViewModel",
        ] {
            XCTAssertTrue(names.contains(expected), "\(expected) missing from the scan")
        }
    }

    /// Distances, names, profile ids and sample counts are all identifying once
    /// they leave the machine — a distance joined to a label says who was in the
    /// room. The plan allows counters; none are implemented, and adding one is a
    /// decision to take deliberately rather than by reflex.
    func testTheVoiceprintSourcesEmitNoTelemetry() throws {
        for url in try voiceprintSources() {
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(
                source.contains("Telemetry.send"),
                "\(url.lastPathComponent) sends telemetry; voice profile data must not leave the machine"
            )
        }
    }

    /// The one event the feature does produce carries a bare boolean, through
    /// the same `settingChanged` path every other toggle uses.
    ///
    /// Every call is inspected to its closing parenthesis rather than a fixed
    /// prefix, so a longer or reformatted call cannot hide a second argument.
    func testTheOnlyVoiceprintTelemetryIsThePreferenceItself() throws {
        let settings = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "MacParakeetViewModels/SettingsViewModel.swift"
            ),
            encoding: .utf8
        )

        let calls = telemetryCalls(in: settings)
        XCTAssertFalse(calls.isEmpty, "expected the settings view model to report toggles")
        let voiceprintCalls = calls.filter {
            $0.contains("rememberSpeakers") || $0.lowercased().contains("voiceprint")
        }

        XCTAssertEqual(voiceprintCalls.count, 1, "expected exactly one voice-profile event")
        let event = try XCTUnwrap(voiceprintCalls.first)
        XCTAssertTrue(event.contains(".settingChanged"), event)
        XCTAssertTrue(event.contains("settingValue(rememberSpeakers)"), event)
        // The consent date is a compliance record, not an analytics signal.
        XCTAssertFalse(event.contains("voiceprintConsentAcknowledgedAt"), event)
        XCTAssertFalse(event.contains("Date("), event)
    }

    /// Splits on `Telemetry.send(` and returns each call's full argument list by
    /// balancing parentheses, so call length never truncates what is inspected.
    private func telemetryCalls(in source: String) -> [String] {
        var calls: [String] = []
        var remainder = Substring(source)
        while let start = remainder.range(of: "Telemetry.send(") {
            var depth = 0
            var end: String.Index?
            for index in remainder[start.lowerBound...].indices {
                let character = remainder[index]
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        end = remainder.index(after: index)
                        break
                    }
                }
            }
            guard let end else { break }
            calls.append(String(remainder[start.lowerBound..<end]))
            remainder = remainder[end...]
        }
        return calls
    }

    /// The balancing must survive a call written across many lines with nested
    /// parentheses, which is how the real ones are formatted.
    func testCallExtractionHandlesNestedAndMultilineCalls() {
        let fixture = """
            Telemetry.send(.settingChanged(setting: .a, value: Self.settingValue(flag)))
            Telemetry.send(
                .settingChanged(
                    setting: .rememberSpeakers,
                    value: Self.settingValue(rememberSpeakers)
                )
            )
            """
        let calls = telemetryCalls(in: fixture)

        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[1].contains("settingValue(rememberSpeakers)"), calls[1])
        XCTAssertTrue(calls[1].hasSuffix(")"), calls[1])
    }
}
