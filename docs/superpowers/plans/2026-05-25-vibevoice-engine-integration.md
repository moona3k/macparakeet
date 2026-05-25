# VibeVoice Engine Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Microsoft VibeVoice-ASR a real, user-selectable speech engine in MacParakeet — pickable per-feature (dictation / file transcription / meeting recording) with a single global default, downloadable from inside Settings, and routable via the existing `STTScheduler` / `STTRuntime` per ADR-016 and ADR-021.

**Architecture:** Build on top of Phase 2.1's `VibeVoiceCore` (the Swift wrapper around the `vibevoice.cpp` C ABI). Add a `VibeVoiceEngine` actor that conforms to the same shape `STTRuntime` already owns for Parakeet and Whisper. Introduce a `SpeechEnginePreferences` container with per-feature overrides (`.global` or `.specific(...)`). Extend `STTScheduler` to resolve engine per job and add guardrails so VibeVoice never claims the reserved dictation slot and only one VibeVoice job runs at a time. Mirror Whisper's existing model-download UX for the ~10 GB VibeVoice model. Replace the single engine picker in Settings with a 4-selector card.

**Tech Stack:** Swift 6.0, SwiftPM, SwiftUI (Settings UI), XCTest, GRDB (no schema changes), no new third-party dependencies. Builds on the existing `VibeVoiceCore` target from Phase 2.1.

**Branch:** Start from `feat/vibevoice-swift-wrapper` (Phase 2.1's branch — not yet merged to main as of plan-writing). New branch name: `feat/vibevoice-engine-integration`.

**Key non-goals (deferred to Phase 2.3 / 2.5):**
- Native diarization handoff for meetings (VibeVoice's speakers replacing FluidAudio's diarizer) — Phase 2.3
- LLM subtitle refinement on VibeVoice output (needs word-level alignment) — Phase 2.3
- Production library bundling (still uses spike paths from Phase 2.1) — Phase 2.5
- Hardware compatibility detection for ggml-Metal kernel gaps — waiting on upstream fix in flight

---

## File Structure

**New files:**
- `Sources/MacParakeetCore/STT/SpeechEnginePreferences.swift` — the new `SpeechEnginePreferences` container + `FeatureEngineSelection` enum + persistence + migration helper
- `Sources/MacParakeetCore/STT/VibeVoiceEngine.swift` — actor wrapping `VibeVoiceASR` behind `STTRuntime`'s engine shape
- `Sources/MacParakeetCore/STT/VibeVoiceModelDownloader.swift` — model download + SHA-256 verify + resumable HTTP + progress
- `Sources/MacParakeet/Views/Settings/SpeechEngineCard.swift` — the 4-picker UI
- `Sources/MacParakeet/Views/Settings/EngineModelStatusRow.swift` — per-engine status row + Download button
- `Sources/CLI/Commands/STTDownloadModelCommand.swift` — `stt download-model` CLI subcommand
- `Tests/MacParakeetTests/STT/SpeechEnginePreferencesTests.swift`
- `Tests/MacParakeetTests/STT/VibeVoiceEngineTests.swift`
- `Tests/MacParakeetTests/STT/VibeVoiceModelDownloaderTests.swift`
- `Tests/MacParakeetTests/STT/STTSchedulerVibeVoiceTests.swift`
- `Tests/CLITests/STTDownloadModelCommandTests.swift`

**Modified files:**
- `Sources/MacParakeetCore/SpeechEnginePreference.swift` — add `.vibevoice` case + update `displayName` / `alternative` exhaustive switches
- `Sources/MacParakeetCore/STT/STTResult.swift` — add `speakerId: Int?` to `STTSegment` (default nil)
- `Sources/MacParakeetCore/STT/STTRuntime.swift` — add `vibevoiceEngine: VibeVoiceEngine?` lazy slot + warm-up plumbing
- `Sources/MacParakeetCore/STT/STTScheduler.swift` — engine resolution per job from `SpeechEnginePreferences` + VibeVoice slot routing rules + in-flight tracking
- `Sources/MacParakeetViewModels/SettingsViewModel.swift` — bind 4 pickers to `SpeechEnginePreferences` (replace single `speechEnginePreference` binding)
- `Sources/MacParakeet/Views/Settings/SettingsView.swift` — replace single engine picker block (~lines 1660-1745) with new `SpeechEngineCard` invocation
- `Sources/CLI/Commands/TranscribeCommand.swift` — accept `--engine vibevoice`, warn when paired with `--language`
- `Sources/CLI/Commands/HealthCommand.swift` — report VibeVoice model availability alongside Parakeet/Whisper
- `Sources/CLI/CHANGELOG.md` — semver entry per CLI public-contract policy
- `spec/06-stt-engine.md` — extend narrative to cover the third engine + per-feature selection

---

## Task 1: Add `.vibevoice` case to `SpeechEnginePreference`

**Files:**
- Modify: `Sources/MacParakeetCore/SpeechEnginePreference.swift`
- Test: write failing test in this task; passes after the case is added

- [ ] **Step 1: Write the failing test**

Append to `Tests/MacParakeetTests/STT/SpeechEnginePreferencesTests.swift` (create the file with this content — it'll grow in Task 3):

```swift
import XCTest
@testable import MacParakeetCore

final class SpeechEnginePreferencesTests: XCTestCase {

    func testVibeVoiceCaseExistsAndHasDisplayName() {
        let pref: SpeechEnginePreference = .vibevoice
        XCTAssertEqual(pref.rawValue, "vibevoice")
        XCTAssertEqual(pref.displayName, "VibeVoice")
    }

    func testAllCasesIncludesVibeVoice() {
        let all = SpeechEnginePreference.allCases
        XCTAssertTrue(all.contains(.vibevoice))
        XCTAssertEqual(all.count, 3)
    }
}
```

- [ ] **Step 2: Run to confirm it fails**

```bash
swift test --filter SpeechEnginePreferencesTests 2>&1 | tail -5
```

Expected: FAIL with `cannot find '.vibevoice' in scope` or similar.

- [ ] **Step 3: Add the case to the enum**

In `Sources/MacParakeetCore/SpeechEnginePreference.swift`, find the enum declaration (lines 3-6 currently):

```swift
public enum SpeechEnginePreference: String, CaseIterable, Codable, Sendable {
    case parakeet
    case whisper
}
```

Change to:

```swift
public enum SpeechEnginePreference: String, CaseIterable, Codable, Sendable {
    case parakeet
    case whisper
    case vibevoice
}
```

- [ ] **Step 4: Update the `displayName` switch**

Find the `displayName` property (currently lines 21-28). Change to:

```swift
public var displayName: String {
    switch self {
    case .parakeet:
        "Parakeet"
    case .whisper:
        "Whisper"
    case .vibevoice:
        "VibeVoice"
    }
}
```

- [ ] **Step 5: Update the `alternative` switch (or remove it)**

Find the `alternative` property (currently lines 30-37). The two-engine binary "switch to the other" semantic doesn't fit with three engines.

Replace with a deprecated fallback that keeps source compatibility for any current caller:

```swift
/// Deprecated: only meaningful with two engines. Returns Parakeet for any
/// non-Parakeet input. Phase 2.2+ callers should use `SpeechEnginePreferences`
/// per-feature resolution instead.
@available(*, deprecated, message: "Use SpeechEnginePreferences per-feature resolution")
public var alternative: SpeechEnginePreference {
    switch self {
    case .parakeet: return .whisper
    case .whisper: return .parakeet
    case .vibevoice: return .parakeet
    }
}
```

- [ ] **Step 6: Run tests to verify**

```bash
swift test --filter SpeechEnginePreferencesTests 2>&1 | tail -5
swift build 2>&1 | grep -E "error:" | head -5
```

Expected: Tests pass. Build may show deprecation warnings on existing callers of `.alternative` — that's intentional and they'll be cleaned up by Task 11 when the UI switches away from binary toggle.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacParakeetCore/SpeechEnginePreference.swift \
        Tests/MacParakeetTests/STT/SpeechEnginePreferencesTests.swift
git commit -m "feat(stt): add .vibevoice case to SpeechEnginePreference"
```

---

## Task 2: Add `speakerId` to `STTSegment`

**Files:**
- Modify: `Sources/MacParakeetCore/STT/STTResult.swift`
- Test: append to existing test file or create `Tests/MacParakeetTests/STT/STTSegmentTests.swift`

`STTSegment` currently holds `startMs`, `endMs`, `text`. VibeVoice's output includes per-segment speaker labels. Extend the struct with an optional `speakerId: Int?` (default nil). Whisper's existing call sites pass nothing → speakerId defaults to nil → behavior unchanged.

- [ ] **Step 1: Write failing test**

Create `Tests/MacParakeetTests/STT/STTSegmentTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore

final class STTSegmentTests: XCTestCase {

    func testSegmentWithoutSpeakerHasNilSpeakerId() {
        let seg = STTSegment(startMs: 0, endMs: 1500, text: "Hello.")
        XCTAssertNil(seg.speakerId)
    }

    func testSegmentWithSpeakerCarriesSpeakerId() {
        let seg = STTSegment(startMs: 0, endMs: 1500, text: "Hello.", speakerId: 2)
        XCTAssertEqual(seg.speakerId, 2)
    }

    func testEqualityIncludesSpeakerId() {
        let a = STTSegment(startMs: 0, endMs: 1500, text: "Hi.", speakerId: 0)
        let b = STTSegment(startMs: 0, endMs: 1500, text: "Hi.", speakerId: 1)
        XCTAssertNotEqual(a, b)
    }

    func testCodableRoundTripPreservesSpeakerId() throws {
        let original = STTSegment(startMs: 100, endMs: 2500, text: "Test", speakerId: 3)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(STTSegment.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableDecodesLegacyJSONWithoutSpeakerId() throws {
        // Old persisted segments without speakerId must still decode (key missing → nil).
        let legacyJSON = #"{"startMs":0,"endMs":1500,"text":"Legacy"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(STTSegment.self, from: legacyJSON)
        XCTAssertEqual(decoded.text, "Legacy")
        XCTAssertNil(decoded.speakerId)
    }
}
```

- [ ] **Step 2: Run to confirm it fails**

```bash
swift test --filter STTSegmentTests 2>&1 | tail -5
```

Expected: FAIL — `speakerId` is not a member of `STTSegment`.

- [ ] **Step 3: Extend the struct**

In `Sources/MacParakeetCore/STT/STTResult.swift`, find `STTSegment` (lines 45-55). Replace with:

```swift
public struct STTSegment: Sendable, Codable, Equatable {
    public let startMs: Int
    public let endMs: Int
    public let text: String
    /// Speaker label when the engine performs diarization natively (VibeVoice).
    /// `nil` for engines that don't provide this (Whisper, Parakeet).
    public let speakerId: Int?

    public init(startMs: Int, endMs: Int, text: String, speakerId: Int? = nil) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speakerId = speakerId
    }
}
```

The optional + default `nil` parameter means existing call sites (Whisper's segment construction) compile unchanged.

- [ ] **Step 4: Run tests to verify**

```bash
swift test --filter STTSegmentTests 2>&1 | tail -5
swift build 2>&1 | grep -E "error:" | head -5
```

Expected: All 5 tests pass. No new build errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/STT/STTResult.swift \
        Tests/MacParakeetTests/STT/STTSegmentTests.swift
git commit -m "feat(stt): add optional speakerId to STTSegment for diarized engines"
```

---

## Task 3: Define `SpeechEnginePreferences` container

**Files:**
- Create: `Sources/MacParakeetCore/STT/SpeechEnginePreferences.swift`
- Modify: `Tests/MacParakeetTests/STT/SpeechEnginePreferencesTests.swift` (created in Task 1)

The new persisted container holds the global default + three per-feature overrides. Each override is either `.global` (follow the global default) or `.specific(...)` (override).

- [ ] **Step 1: Append failing tests to the existing test file**

In `Tests/MacParakeetTests/STT/SpeechEnginePreferencesTests.swift`, append:

```swift
    // MARK: - FeatureEngineSelection

    func testFeatureSelectionGlobalEquality() {
        XCTAssertEqual(FeatureEngineSelection.global, FeatureEngineSelection.global)
    }

    func testFeatureSelectionSpecificEquality() {
        XCTAssertEqual(
            FeatureEngineSelection.specific(.whisper),
            FeatureEngineSelection.specific(.whisper)
        )
        XCTAssertNotEqual(
            FeatureEngineSelection.specific(.whisper),
            FeatureEngineSelection.specific(.parakeet)
        )
    }

    func testFeatureSelectionCodableRoundTrip() throws {
        let cases: [FeatureEngineSelection] = [.global, .specific(.parakeet), .specific(.vibevoice)]
        for selection in cases {
            let data = try JSONEncoder().encode(selection)
            let decoded = try JSONDecoder().decode(FeatureEngineSelection.self, from: data)
            XCTAssertEqual(decoded, selection)
        }
    }

    // MARK: - SpeechEnginePreferences resolution

    func testDefaultPreferencesAllFollowParakeet() {
        let prefs = SpeechEnginePreferences()
        XCTAssertEqual(prefs.global, .parakeet)
        XCTAssertEqual(prefs.dictation, .global)
        XCTAssertEqual(prefs.fileTranscription, .global)
        XCTAssertEqual(prefs.meetingRecording, .global)
        XCTAssertEqual(prefs.engine(for: .dictation), .parakeet)
        XCTAssertEqual(prefs.engine(for: .fileTranscription), .parakeet)
        XCTAssertEqual(prefs.engine(for: .meetingFinalize), .parakeet)
        XCTAssertEqual(prefs.engine(for: .meetingLiveChunk), .parakeet)
    }

    func testGlobalWhisperResolvesAllJobsToWhisper() {
        var prefs = SpeechEnginePreferences()
        prefs.global = .whisper
        XCTAssertEqual(prefs.engine(for: .dictation), .whisper)
        XCTAssertEqual(prefs.engine(for: .fileTranscription), .whisper)
        XCTAssertEqual(prefs.engine(for: .meetingFinalize), .whisper)
    }

    func testPerFeatureOverrideTrumpsGlobal() {
        var prefs = SpeechEnginePreferences()
        prefs.global = .whisper
        prefs.dictation = .specific(.parakeet)
        prefs.meetingRecording = .specific(.vibevoice)
        XCTAssertEqual(prefs.engine(for: .dictation), .parakeet)
        XCTAssertEqual(prefs.engine(for: .fileTranscription), .whisper)
        XCTAssertEqual(prefs.engine(for: .meetingFinalize), .vibevoice)
        XCTAssertEqual(prefs.engine(for: .meetingLiveChunk), .vibevoice)
    }

    // MARK: - Persistence and migration

    func testRoundTripPersistsAllFields() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        var prefs = SpeechEnginePreferences()
        prefs.global = .whisper
        prefs.dictation = .specific(.parakeet)
        prefs.meetingRecording = .specific(.vibevoice)
        prefs.save(to: defaults)

        let loaded = SpeechEnginePreferences.current(defaults: defaults)
        XCTAssertEqual(loaded, prefs)
    }

    func testMigratesFromLegacySingleEnginePreference() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        // Simulate a pre-Phase-2.2 user: only the old single key is set
        defaults.set("whisper", forKey: SpeechEnginePreference.defaultsKey)

        let loaded = SpeechEnginePreferences.current(defaults: defaults)

        // Migration: global = old value, every per-feature = .global
        XCTAssertEqual(loaded.global, .whisper)
        XCTAssertEqual(loaded.dictation, .global)
        XCTAssertEqual(loaded.fileTranscription, .global)
        XCTAssertEqual(loaded.meetingRecording, .global)
    }

    func testMigrationDefaultsToParakeetWhenLegacyKeyMissing() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        // No keys set at all
        let loaded = SpeechEnginePreferences.current(defaults: defaults)
        XCTAssertEqual(loaded.global, .parakeet)
        XCTAssertEqual(loaded.dictation, .global)
    }
```

- [ ] **Step 2: Run to confirm tests fail**

```bash
swift test --filter SpeechEnginePreferencesTests 2>&1 | tail -10
```

Expected: FAIL — `FeatureEngineSelection` and `SpeechEnginePreferences` undefined.

- [ ] **Step 3: Implement the types and persistence**

Create `Sources/MacParakeetCore/STT/SpeechEnginePreferences.swift`:

```swift
import Foundation

/// One feature's engine choice: either follow the global default, or
/// override with a specific engine. Used in `SpeechEnginePreferences`.
public enum FeatureEngineSelection: Codable, Sendable, Equatable {
    case global
    case specific(SpeechEnginePreference)
}

/// User's persisted speech-engine configuration. One global default plus
/// per-feature overrides for dictation, file transcription, and meeting
/// recording. Replaces the pre-Phase-2.2 single `SpeechEnginePreference`
/// persistence.
public struct SpeechEnginePreferences: Codable, Sendable, Equatable {
    public var global: SpeechEnginePreference
    public var dictation: FeatureEngineSelection
    public var fileTranscription: FeatureEngineSelection
    public var meetingRecording: FeatureEngineSelection

    public init(
        global: SpeechEnginePreference = .parakeet,
        dictation: FeatureEngineSelection = .global,
        fileTranscription: FeatureEngineSelection = .global,
        meetingRecording: FeatureEngineSelection = .global
    ) {
        self.global = global
        self.dictation = dictation
        self.fileTranscription = fileTranscription
        self.meetingRecording = meetingRecording
    }

    /// Resolves the engine for a given job kind. Per-feature overrides win;
    /// `.global` falls through to `global`.
    public func engine(for jobKind: STTJobKind) -> SpeechEnginePreference {
        switch jobKind {
        case .dictation:           return resolve(dictation)
        case .fileTranscription:   return resolve(fileTranscription)
        case .meetingFinalize, .meetingLiveChunk:
            return resolve(meetingRecording)
        }
    }

    private func resolve(_ selection: FeatureEngineSelection) -> SpeechEnginePreference {
        switch selection {
        case .global:           return global
        case .specific(let e):  return e
        }
    }

    // MARK: - Persistence

    /// UserDefaults key where the JSON-encoded `SpeechEnginePreferences` blob
    /// is stored. Distinct from `SpeechEnginePreference.defaultsKey` which
    /// is the pre-Phase-2.2 single-engine key, kept around for migration.
    public static let defaultsKey = "speechEnginePreferences"

    /// Loads the current preferences. If the new key isn't present, migrates
    /// from the legacy `SpeechEnginePreference` single key. If neither is
    /// present, returns defaults (all-Parakeet).
    public static func current(defaults: UserDefaults = .standard) -> SpeechEnginePreferences {
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(SpeechEnginePreferences.self, from: data) {
            return decoded
        }
        // Migration from pre-Phase-2.2: the only persisted value was the
        // legacy single-engine key. Promote it to `global` and leave every
        // per-feature override at `.global`.
        let legacy = SpeechEnginePreference.current(defaults: defaults)
        return SpeechEnginePreferences(
            global: legacy,
            dictation: .global,
            fileTranscription: .global,
            meetingRecording: .global
        )
    }

    /// Persists the preferences. Does not delete the legacy
    /// `SpeechEnginePreference.defaultsKey` — readers that still use it
    /// (until they're migrated) keep working off the old value.
    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter SpeechEnginePreferencesTests 2>&1 | tail -10
```

Expected: All 12+ tests pass (3 from Task 1's case test + ~9 from this task).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/STT/SpeechEnginePreferences.swift \
        Tests/MacParakeetTests/STT/SpeechEnginePreferencesTests.swift
git commit -m "feat(stt): SpeechEnginePreferences container with per-feature overrides + migration"
```

---

## Task 4: `VibeVoiceEngine` actor

**Files:**
- Create: `Sources/MacParakeetCore/STT/VibeVoiceEngine.swift`
- Create: `Tests/MacParakeetTests/STT/VibeVoiceEngineTests.swift`

Wraps `VibeVoiceASR` (from Phase 2.1) behind the same shape `STTRuntime` already manages.

- [ ] **Step 1: Write failing tests**

Create `Tests/MacParakeetTests/STT/VibeVoiceEngineTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore
import VibeVoiceCore

final class VibeVoiceEngineTests: XCTestCase {

    /// Same model location convention used by VibeVoiceASRTests in Phase 2.1.
    private var modelDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("MacParakeet")
            .appendingPathComponent("models")
            .appendingPathComponent("stt")
            .appendingPathComponent("vibevoice")
    }

    private func skipIfModelMissing() throws {
        let model = modelDir.appendingPathComponent("vibevoice-asr-q4_k.gguf")
        let tok = modelDir.appendingPathComponent("tokenizer.gguf")
        guard FileManager.default.fileExists(atPath: model.path),
              FileManager.default.fileExists(atPath: tok.path) else {
            throw XCTSkip("VibeVoice model not installed at \(modelDir.path)")
        }
    }

    private func fixtureURL() throws -> URL {
        // Re-use Phase 2.1's bundled fixture via the VibeVoiceCore module.
        let url = Bundle.module.url(forResource: "tiny_ted", withExtension: "wav")
            ?? Bundle(for: type(of: self)).url(forResource: "tiny_ted", withExtension: "wav")
        guard let url else { throw XCTSkip("tiny_ted.wav fixture not bundled") }
        return url
    }

    func testWarmUpThrowsWhenModelMissing() async {
        let engine = VibeVoiceEngine(modelDirectory: URL(fileURLWithPath: "/tmp/nonexistent-vibevoice"))
        do {
            try await engine.warmUp()
            XCTFail("Expected an error; got success")
        } catch {
            // expected — any error type is OK as long as we throw
        }
    }

    func testTranscribeReturnsSegmentsAndVibeVoiceEngineTag() async throws {
        try skipIfModelMissing()
        let audio = try fixtureURL()

        let engine = VibeVoiceEngine(modelDirectory: modelDir)
        let result = try await engine.transcribe(audioPath: audio.path, job: .fileTranscription)

        XCTAssertEqual(result.engine, .vibevoice)
        XCTAssertNotNil(result.segments)
        XCTAssertFalse(result.segments!.isEmpty)
        // VibeVoice doesn't expose word-level timing — words list is empty.
        XCTAssertTrue(result.words.isEmpty)
        // Diarized — at least one segment should carry a speakerId.
        XCTAssertTrue(result.segments!.contains { $0.speakerId != nil })
        // engineVariant identifies the GGUF.
        XCTAssertEqual(result.engineVariant, "vibevoice-asr-q4_k")
    }

    func testTextIsJoinedFromSegments() async throws {
        try skipIfModelMissing()
        let audio = try fixtureURL()

        let engine = VibeVoiceEngine(modelDirectory: modelDir)
        let result = try await engine.transcribe(audioPath: audio.path, job: .fileTranscription)

        // text should be a non-empty join of the segments' text fields.
        XCTAssertFalse(result.text.isEmpty)
        for seg in result.segments ?? [] {
            XCTAssertTrue(result.text.contains(seg.text))
        }
    }
}
```

The tests use `Bundle.module` from `VibeVoiceCoreTests` if the resource bundle is shared, or fall back to `Bundle(for:)`. If neither works, the integration test skips — same pattern Phase 2.1 used.

- [ ] **Step 2: Run to confirm tests fail**

```bash
swift test --filter VibeVoiceEngineTests 2>&1 | tail -8
```

Expected: FAIL — `VibeVoiceEngine` undefined.

- [ ] **Step 3: Implement `VibeVoiceEngine`**

Create `Sources/MacParakeetCore/STT/VibeVoiceEngine.swift`:

```swift
import Foundation
import VibeVoiceCore

/// Wraps `VibeVoiceASR` (Phase 2.1) behind the same shape `STTRuntime`
/// already manages for Parakeet and Whisper. Owns model lifecycle for
/// the VibeVoice engine; the actor's serialization guarantees that
/// concurrent transcribe calls queue rather than corrupt the underlying
/// single-engine C library.
///
/// Lifecycle:
/// 1. `warmUp()` — calls `vv_capi_load` once. Takes ~13s on M1 Max with Q4.
/// 2. `transcribe(audioPath:job:)` — many calls. Returns `STTResult` with
///    diarized segments populated and word-level timing empty (VibeVoice
///    doesn't expose words via its C ABI).
/// 3. `unload()` — frees the underlying engine. Optional; process exit
///    also frees it.
public actor VibeVoiceEngine {
    private let asr: VibeVoiceASR
    private let modelDirectory: URL
    private var isLoaded = false

    /// `modelDirectory` defaults to the conventional location under
    /// `~/Library/Application Support/MacParakeet/models/stt/vibevoice/`.
    /// Override for tests.
    public init(modelDirectory: URL? = nil) {
        self.asr = VibeVoiceASR()
        self.modelDirectory = modelDirectory ?? Self.defaultModelDirectory()
    }

    public static func defaultModelDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("MacParakeet")
            .appendingPathComponent("models")
            .appendingPathComponent("stt")
            .appendingPathComponent("vibevoice")
    }

    public func warmUp() async throws {
        if isLoaded { return }
        let model = modelDirectory.appendingPathComponent("vibevoice-asr-q4_k.gguf")
        let tok = modelDirectory.appendingPathComponent("tokenizer.gguf")
        try await asr.loadModel(modelPath: model, tokenizerPath: tok)
        isLoaded = true
    }

    public func transcribe(audioPath: String, job: STTJobKind) async throws -> STTResult {
        if !isLoaded { try await warmUp() }

        // VibeVoice requires 24 kHz mono WAV. If the input is something
        // else (mp3/m4a/etc.), convert via the bundled FFmpeg into a temp
        // file before handing it to the C ABI.
        let wavPath = try await Self.ensureWAV(audioPath)
        defer {
            // Best-effort cleanup of the temp WAV we created.
            if wavPath != audioPath {
                try? FileManager.default.removeItem(atPath: wavPath)
            }
        }

        let segments = try await asr.transcribe(wavPath: URL(fileURLWithPath: wavPath))
        let sttSegments = segments.map { seg in
            STTSegment(
                startMs: Int(seg.startSec * 1000),
                endMs: Int(seg.endSec * 1000),
                text: seg.text,
                speakerId: seg.speakerId
            )
        }
        let joinedText = segments.map(\.text).joined(separator: "\n")

        return STTResult(
            text: joinedText,
            words: [],
            segments: sttSegments,
            language: nil,
            engine: .vibevoice,
            engineVariant: "vibevoice-asr-q4_k"
        )
    }

    public func unload() async {
        await asr.unload()
        isLoaded = false
    }

    // MARK: - Audio conversion

    /// If the input is already a WAV, returns the path unchanged. Otherwise
    /// uses the bundled FFmpeg to produce a 24 kHz mono PCM WAV in `$TMPDIR`
    /// and returns its path. Caller is responsible for deletion.
    private static func ensureWAV(_ audioPath: String) async throws -> String {
        let lower = (audioPath as NSString).pathExtension.lowercased()
        if lower == "wav" {
            return audioPath
        }
        let ffmpeg = "/Applications/MacParakeet.app/Contents/Resources/ffmpeg"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibevoice-\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-i", audioPath,
            "-ar", "24000",
            "-ac", "1",
            "-y", outputURL.path
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw STTError.transcriptionFailed("FFmpeg failed with status \(process.terminationStatus) converting to WAV")
        }
        return outputURL.path
    }
}
```

- [ ] **Step 4: Symlink the model files (one-time setup for tests)**

```bash
mkdir -p ~/Library/Application\ Support/MacParakeet/models/stt/vibevoice
ln -sf /Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/vibevoice-spike/vibevoice.cpp/models/vibevoice-asr-q4_k.gguf \
       ~/Library/Application\ Support/MacParakeet/models/stt/vibevoice/vibevoice-asr-q4_k.gguf
ln -sf /Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/vibevoice-spike/vibevoice.cpp/models/tokenizer.gguf \
       ~/Library/Application\ Support/MacParakeet/models/stt/vibevoice/tokenizer.gguf
```

(Note: Phase 2.1 used `models/vibevoice/` — Phase 2.2 conventional path is `models/stt/vibevoice/` for parity with `models/stt/whisper/`. Update the symlinks.)

- [ ] **Step 5: Run tests**

```bash
swift test --filter VibeVoiceEngineTests 2>&1 | tail -10
```

Expected: All tests PASS. Integration tests take ~10s including model load.

- [ ] **Step 6: Add VibeVoiceCore as a dependency of MacParakeetCore**

In `Package.swift`, find `MacParakeetCore` target's `dependencies:`. Add `"VibeVoiceCore"` to the list. Note: VibeVoiceCore is currently a top-level target; this dependency makes it part of the MacParakeetCore graph so `import VibeVoiceCore` works from `STT/VibeVoiceEngine.swift`.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacParakeetCore/STT/VibeVoiceEngine.swift \
        Tests/MacParakeetTests/STT/VibeVoiceEngineTests.swift \
        Package.swift
git commit -m "feat(stt): VibeVoiceEngine actor wrapping VibeVoiceASR with FFmpeg input conversion"
```

---

## Task 5: `VibeVoiceModelDownloader`

**Files:**
- Create: `Sources/MacParakeetCore/STT/VibeVoiceModelDownloader.swift`
- Create: `Tests/MacParakeetTests/STT/VibeVoiceModelDownloaderTests.swift`

Downloads the two files (`vibevoice-asr-q4_k.gguf` 9.7 GB + `tokenizer.gguf` 5.6 MB) from HuggingFace, with SHA-256 verification, resumable HTTP via Range requests, and progress reporting.

- [ ] **Step 1: Write failing tests**

Create `Tests/MacParakeetTests/STT/VibeVoiceModelDownloaderTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore

final class VibeVoiceModelDownloaderTests: XCTestCase {

    func testFileSpecHasURLAndExpectedSize() {
        let spec = VibeVoiceModelDownloader.modelFile
        XCTAssertTrue(spec.remoteURL.absoluteString.contains("huggingface.co"))
        XCTAssertTrue(spec.remoteURL.absoluteString.hasSuffix("/vibevoice-asr-q4_k.gguf"))
        XCTAssertGreaterThan(spec.expectedSizeBytes, 9_000_000_000)  // ~9.7 GB
        XCTAssertLessThan(spec.expectedSizeBytes, 11_000_000_000)
    }

    func testTokenizerFileSpecHasURLAndExpectedSize() {
        let spec = VibeVoiceModelDownloader.tokenizerFile
        XCTAssertTrue(spec.remoteURL.absoluteString.hasSuffix("/tokenizer.gguf"))
        XCTAssertGreaterThan(spec.expectedSizeBytes, 5_000_000)  // ~5.6 MB
        XCTAssertLessThan(spec.expectedSizeBytes, 7_000_000)
    }

    func testDownloadDirectoryIsConventionalPath() {
        let dir = VibeVoiceModelDownloader.defaultModelDirectory()
        XCTAssertTrue(dir.path.contains("MacParakeet/models/stt/vibevoice"))
    }

    func testAreModelsInstalledReturnsFalseWhenMissing() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vv-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertFalse(VibeVoiceModelDownloader.areModelsInstalled(at: tmp))
    }

    func testAreModelsInstalledReturnsTrueWhenBothFilesPresent() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vv-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Touch the two expected files
        let model = tmp.appendingPathComponent("vibevoice-asr-q4_k.gguf")
        let tok = tmp.appendingPathComponent("tokenizer.gguf")
        FileManager.default.createFile(atPath: model.path, contents: Data())
        FileManager.default.createFile(atPath: tok.path, contents: Data())

        XCTAssertTrue(VibeVoiceModelDownloader.areModelsInstalled(at: tmp))
    }
}
```

(Network-driven download tests are NOT included — that would require either a mock URLSession or live network. We test the small contract surface that doesn't need network: file specs, paths, installation detection. The full download flow gets manual / smoke-test verification in Task 16.)

- [ ] **Step 2: Run to confirm tests fail**

```bash
swift test --filter VibeVoiceModelDownloaderTests 2>&1 | tail -5
```

Expected: FAIL — type undefined.

- [ ] **Step 3: Implement the downloader**

Create `Sources/MacParakeetCore/STT/VibeVoiceModelDownloader.swift`:

```swift
import Foundation
import CryptoKit

public actor VibeVoiceModelDownloader {

    public struct FileSpec: Sendable {
        public let remoteURL: URL
        public let localFilename: String
        public let expectedSizeBytes: Int64
        /// SHA-256 hex digest, lowercase. Verify after download; reject on mismatch.
        public let expectedSHA256: String

        public init(remoteURL: URL, localFilename: String, expectedSizeBytes: Int64, expectedSHA256: String) {
            self.remoteURL = remoteURL
            self.localFilename = localFilename
            self.expectedSizeBytes = expectedSizeBytes
            self.expectedSHA256 = expectedSHA256
        }
    }

    /// The 9.7 GB ASR model file.
    public static let modelFile = FileSpec(
        remoteURL: URL(string: "https://huggingface.co/mudler/vibevoice.cpp-models/resolve/main/vibevoice-asr-q4_k.gguf")!,
        localFilename: "vibevoice-asr-q4_k.gguf",
        expectedSizeBytes: 10_392_063_296,
        // SHA-256 of the file as observed in the Phase 2.1 spike download.
        // If HuggingFace re-publishes, this needs updating. Verified via:
        //   shasum -a 256 vibevoice-asr-q4_k.gguf
        expectedSHA256: "PLACEHOLDER_TO_BE_FILLED_FROM_SPIKE_DOWNLOAD"
    )

    /// The 5.6 MB Qwen-2.5 tokenizer file.
    public static let tokenizerFile = FileSpec(
        remoteURL: URL(string: "https://huggingface.co/mudler/vibevoice.cpp-models/resolve/main/tokenizer.gguf")!,
        localFilename: "tokenizer.gguf",
        expectedSizeBytes: 5_922_368,
        expectedSHA256: "PLACEHOLDER_TO_BE_FILLED_FROM_SPIKE_DOWNLOAD"
    )

    public static func defaultModelDirectory() -> URL {
        VibeVoiceEngine.defaultModelDirectory()
    }

    public static func areModelsInstalled(at dir: URL = defaultModelDirectory()) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent(modelFile.localFilename).path)
            && fm.fileExists(atPath: dir.appendingPathComponent(tokenizerFile.localFilename).path)
    }

    // MARK: - Download

    public typealias ProgressHandler = @Sendable (Int64, Int64) -> Void

    public enum DownloadError: Error, Equatable {
        case networkError(String)
        case writeError(String)
        case hashMismatch(expected: String, actual: String)
        case sizeMismatch(expected: Int64, actual: Int64)
        case cancelled
    }

    private let urlSession: URLSession
    private var currentTask: URLSessionDataTask?
    private var cancelled = false

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Downloads both files into `directory`, creating it if needed. Calls
    /// `onProgress` with cumulative bytes (across both files) and total expected.
    public func downloadAll(
        to directory: URL = Self.defaultModelDirectory(),
        onProgress: ProgressHandler? = nil
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let totalExpected = Self.modelFile.expectedSizeBytes + Self.tokenizerFile.expectedSizeBytes
        var cumulative: Int64 = 0

        // Tokenizer first — it's tiny and gives the user fast feedback.
        try await download(spec: Self.tokenizerFile, to: directory) { fileBytes in
            onProgress?(cumulative + fileBytes, totalExpected)
        }
        cumulative += Self.tokenizerFile.expectedSizeBytes

        try await download(spec: Self.modelFile, to: directory) { fileBytes in
            onProgress?(cumulative + fileBytes, totalExpected)
        }
    }

    public func cancel() {
        cancelled = true
        currentTask?.cancel()
    }

    private func download(
        spec: FileSpec,
        to directory: URL,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let destination = directory.appendingPathComponent(spec.localFilename)
        let resumeFile = destination.appendingPathExtension("partial")

        // If a completed file already exists with the right hash, skip.
        if FileManager.default.fileExists(atPath: destination.path) {
            let hash = try Self.sha256(of: destination)
            if hash == spec.expectedSHA256 {
                onProgress(spec.expectedSizeBytes)
                return
            }
            // Stale, retry from scratch
            try FileManager.default.removeItem(at: destination)
        }

        // Resume if a partial exists
        let existingBytes: Int64 = (try? FileManager.default.attributesOfItem(atPath: resumeFile.path)[.size] as? Int64) ?? 0

        var request = URLRequest(url: spec.remoteURL)
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let (asyncBytes, response) = try await urlSession.bytes(for: request)
        if cancelled { throw DownloadError.cancelled }
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DownloadError.networkError("Unexpected HTTP status")
        }

        // Append (or create) the partial file
        if !FileManager.default.fileExists(atPath: resumeFile.path) {
            FileManager.default.createFile(atPath: resumeFile.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: resumeFile)
        try handle.seekToEnd()
        defer { try? handle.close() }

        var receivedBytes: Int64 = existingBytes
        var buffer = Data()
        let chunkSize = 1 << 20  // 1 MB flushes — keeps memory bounded
        buffer.reserveCapacity(chunkSize)

        for try await byte in asyncBytes {
            if cancelled { throw DownloadError.cancelled }
            buffer.append(byte)
            if buffer.count >= chunkSize {
                try handle.write(contentsOf: buffer)
                receivedBytes += Int64(buffer.count)
                onProgress(receivedBytes)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            receivedBytes += Int64(buffer.count)
            onProgress(receivedBytes)
        }
        try handle.close()

        // Size check
        let actualSize: Int64 = (try FileManager.default.attributesOfItem(atPath: resumeFile.path)[.size] as? Int64) ?? 0
        guard actualSize == spec.expectedSizeBytes else {
            try? FileManager.default.removeItem(at: resumeFile)
            throw DownloadError.sizeMismatch(expected: spec.expectedSizeBytes, actual: actualSize)
        }

        // Hash check
        let hash = try Self.sha256(of: resumeFile)
        guard hash == spec.expectedSHA256 else {
            try? FileManager.default.removeItem(at: resumeFile)
            throw DownloadError.hashMismatch(expected: spec.expectedSHA256, actual: hash)
        }

        // Promote the partial file to the final name
        try FileManager.default.moveItem(at: resumeFile, to: destination)
    }

    /// Streams SHA-256 over the file in chunks so a 10 GB file doesn't
    /// require loading into memory.
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Fill the SHA-256 placeholders by hashing the locally-downloaded files from Phase 2.1**

```bash
shasum -a 256 ~/Library/Application\ Support/MacParakeet/models/stt/vibevoice/vibevoice-asr-q4_k.gguf
shasum -a 256 ~/Library/Application\ Support/MacParakeet/models/stt/vibevoice/tokenizer.gguf
```

Replace `PLACEHOLDER_TO_BE_FILLED_FROM_SPIKE_DOWNLOAD` in both `FileSpec` declarations with the actual SHA-256 hex strings (lowercase, no spaces).

- [ ] **Step 5: Run tests**

```bash
swift test --filter VibeVoiceModelDownloaderTests 2>&1 | tail -5
```

Expected: All 5 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacParakeetCore/STT/VibeVoiceModelDownloader.swift \
        Tests/MacParakeetTests/STT/VibeVoiceModelDownloaderTests.swift
git commit -m "feat(stt): VibeVoiceModelDownloader with SHA-256 verify and resume"
```

---

## Task 6: Plumb VibeVoiceEngine into STTRuntime

**Files:**
- Modify: `Sources/MacParakeetCore/STT/STTRuntime.swift`
- Test: append to existing STTRuntime tests if present, otherwise create `Tests/MacParakeetTests/STT/STTRuntimeVibeVoiceTests.swift`

`STTRuntime` is the sole owner of engine lifecycle. Add a lazy `vibevoiceEngine` slot — constructed only when VibeVoice is selected for some feature, freeing the ~10 MB working memory for users who never enable it.

- [ ] **Step 1: Read the existing runtime structure**

```bash
grep -n "private var\|public func\|private func" Sources/MacParakeetCore/STT/STTRuntime.swift | head -30
```

Identify where `whisperEngine` is declared (the pattern to mirror).

- [ ] **Step 2: Write the failing test**

Create `Tests/MacParakeetTests/STT/STTRuntimeVibeVoiceTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore

final class STTRuntimeVibeVoiceTests: XCTestCase {

    func testVibeVoiceEngineIsLazyInitiallyAbsent() async {
        let runtime = STTRuntime()
        let present = await runtime.hasLoadedVibeVoiceEngine
        XCTAssertFalse(present, "VibeVoice engine should not be loaded until ensureVibeVoice() is called")
    }

    func testEnsureVibeVoiceMakesEnginePresent() async throws {
        let runtime = STTRuntime()
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacParakeet/models/stt/vibevoice")
        // Skip if model isn't installed — same pattern as VibeVoiceEngineTests
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("vibevoice-asr-q4_k.gguf").path) else {
            throw XCTSkip("VibeVoice model missing; can't test ensureVibeVoice end-to-end")
        }

        try await runtime.ensureVibeVoiceLoaded()
        let present = await runtime.hasLoadedVibeVoiceEngine
        XCTAssertTrue(present)
    }
}
```

- [ ] **Step 3: Run to confirm tests fail**

```bash
swift test --filter STTRuntimeVibeVoiceTests 2>&1 | tail -5
```

Expected: FAIL — `hasLoadedVibeVoiceEngine` / `ensureVibeVoiceLoaded` undefined.

- [ ] **Step 4: Extend `STTRuntime`**

In `Sources/MacParakeetCore/STT/STTRuntime.swift`, add a new stored property and two methods alongside the existing Whisper plumbing:

```swift
// Add inside the STTRuntime actor body, near the existing
// `private var whisperEngine: WhisperEngine?` declaration:

private var vibevoiceEngine: VibeVoiceEngine?

public var hasLoadedVibeVoiceEngine: Bool {
    vibevoiceEngine != nil
}

/// Lazily constructs and warms the VibeVoice engine. Idempotent — calling
/// twice on a loaded engine is a no-op. Throws if model files are missing
/// or `vv_capi_load` fails.
public func ensureVibeVoiceLoaded() async throws {
    if let existing = vibevoiceEngine {
        // already loaded — re-warm is a no-op inside VibeVoiceEngine.warmUp
        try await existing.warmUp()
        return
    }
    let engine = VibeVoiceEngine()
    try await engine.warmUp()
    vibevoiceEngine = engine
}

/// Returns the loaded VibeVoice engine, throwing if it hasn't been warmed
/// up yet. The scheduler should call `ensureVibeVoiceLoaded()` first when
/// dispatching a VibeVoice job.
public func vibevoice() throws -> VibeVoiceEngine {
    guard let engine = vibevoiceEngine else {
        throw STTError.modelNotLoaded
    }
    return engine
}

/// Tears down the engine. Called on shutdown. Mirrors whisper teardown.
public func unloadVibeVoiceEngine() async {
    await vibevoiceEngine?.unload()
    vibevoiceEngine = nil
}
```

Also extend the existing `shutdown()` method (find it via `grep "public func shutdown"`) to call `await unloadVibeVoiceEngine()` after `await whisperEngine?.unload()`.

- [ ] **Step 5: Run tests**

```bash
swift test --filter STTRuntimeVibeVoiceTests 2>&1 | tail -5
```

Expected: 2 tests PASS (one might skip if model isn't installed).

- [ ] **Step 6: Run the full STT test suite for no regressions**

```bash
swift test --filter STT 2>&1 | grep -E "Executed [0-9]+ tests, with [^0]" | tail -3
```

Expected: All STT tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacParakeetCore/STT/STTRuntime.swift \
        Tests/MacParakeetTests/STT/STTRuntimeVibeVoiceTests.swift
git commit -m "feat(stt): STTRuntime lazily owns VibeVoiceEngine"
```

---

## Task 7: STTScheduler engine resolution + VibeVoice slot routing rules

**Files:**
- Modify: `Sources/MacParakeetCore/STT/STTScheduler.swift`
- Create: `Tests/MacParakeetTests/STT/STTSchedulerVibeVoiceTests.swift`

The scheduler reads `SpeechEnginePreferences.current()` to pick the engine for a job, but adds two guardrails:

1. **VibeVoice never claims the dictation slot.** Even if a user configures `dictation: .specific(.vibevoice)`, the job goes to the shared/background slot. The reserved dictation slot is for sub-second latency engines (Parakeet, Whisper).
2. **Only one VibeVoice job in flight.** The C library is single-engine; running concurrent jobs would queue inside the actor (wasting a scheduler slot). Track in-flight VibeVoice and queue any second job behind it instead of dispatching to a free slot.

- [ ] **Step 1: Write failing tests**

Create `Tests/MacParakeetTests/STT/STTSchedulerVibeVoiceTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore

final class STTSchedulerVibeVoiceTests: XCTestCase {

    func testEngineResolutionUsesPreferences() {
        // The scheduler should resolve to whatever the preferences say,
        // regardless of which slot the job lands in.
        var prefs = SpeechEnginePreferences()
        prefs.global = .whisper
        prefs.dictation = .specific(.parakeet)

        XCTAssertEqual(prefs.engine(for: .dictation), .parakeet)
        XCTAssertEqual(prefs.engine(for: .fileTranscription), .whisper)
    }

    func testVibeVoiceDictationRoutesToSharedSlot() {
        // When VibeVoice is configured for dictation, the scheduler's
        // slot-selection helper must return the shared slot, not the
        // reserved dictation slot. This is the guardrail that prevents
        // a 13s VibeVoice load from blocking interactive dictation.
        let slot = STTScheduler.preferredSlot(for: .dictation, engine: .vibevoice)
        XCTAssertEqual(slot, .shared)
    }

    func testParakeetDictationKeepsTheDictationSlot() {
        let slot = STTScheduler.preferredSlot(for: .dictation, engine: .parakeet)
        XCTAssertEqual(slot, .dictation)
    }

    func testWhisperDictationKeepsTheDictationSlot() {
        // Whisper is fast enough for dictation; only VibeVoice gets demoted.
        let slot = STTScheduler.preferredSlot(for: .dictation, engine: .whisper)
        XCTAssertEqual(slot, .dictation)
    }

    func testFileTranscriptionAlwaysGoesToSharedSlot() {
        XCTAssertEqual(STTScheduler.preferredSlot(for: .fileTranscription, engine: .parakeet), .shared)
        XCTAssertEqual(STTScheduler.preferredSlot(for: .fileTranscription, engine: .whisper), .shared)
        XCTAssertEqual(STTScheduler.preferredSlot(for: .fileTranscription, engine: .vibevoice), .shared)
    }
}
```

- [ ] **Step 2: Run to confirm tests fail**

```bash
swift test --filter STTSchedulerVibeVoiceTests 2>&1 | tail -5
```

Expected: FAIL — `STTScheduler.preferredSlot(for:engine:)` undefined; `STTScheduler.Slot` undefined.

- [ ] **Step 3: Add the slot enum + routing helper to STTScheduler**

In `Sources/MacParakeetCore/STT/STTScheduler.swift`, add at the top of the actor body (or as a top-level type if the existing scheduler has its own slot enum already — check via `grep "Slot\|slot" Sources/MacParakeetCore/STT/STTScheduler.swift`):

```swift
extension STTScheduler {
    /// The two execution slots from ADR-016. `dictation` is reserved for
    /// interactive low-latency jobs; `shared` carries everything else.
    public enum Slot: Sendable, Equatable {
        case dictation
        case shared
    }

    /// Returns the slot that should run a job of a given kind on a given
    /// engine. The default rule is "dictation jobs use the dictation slot,
    /// everything else uses the shared slot." The exception is VibeVoice
    /// dictation, which is demoted to the shared slot so its 13s load
    /// can't block interactive jobs.
    public nonisolated static func preferredSlot(
        for jobKind: STTJobKind,
        engine: SpeechEnginePreference
    ) -> Slot {
        switch jobKind {
        case .dictation:
            return engine == .vibevoice ? .shared : .dictation
        case .fileTranscription, .meetingFinalize, .meetingLiveChunk:
            return .shared
        }
    }
}
```

(If `STTScheduler.Slot` already exists with different cases, reconcile by either using the existing enum or rename `Slot` to `JobSlot` to avoid conflicts. Use `grep` to check.)

- [ ] **Step 4: Run the slot-routing tests**

```bash
swift test --filter STTSchedulerVibeVoiceTests 2>&1 | tail -5
```

Expected: 5 tests PASS.

- [ ] **Step 5: Wire engine resolution into the dispatch path**

This step depends on the exact shape of the existing scheduler's dispatch method. The change is:

1. Find the entrypoint method that accepts `STTJobKind` and produces an `STTResult` (likely `transcribe(audioPath:job:onProgress:)` or similar — `grep "public func transcribe" Sources/MacParakeetCore/STT/STTScheduler.swift`).
2. Inside that method, before slot assignment, resolve the engine:

```swift
let prefs = SpeechEnginePreferences.current()
let resolvedEngine = prefs.engine(for: job)
let slot = Self.preferredSlot(for: job, engine: resolvedEngine)
```

3. Pass `resolvedEngine` to whichever per-engine dispatch path exists (Parakeet vs Whisper vs new VibeVoice). VibeVoice dispatch calls `runtime.ensureVibeVoiceLoaded()` first, then `runtime.vibevoice().transcribe(audioPath:job:)`.

The exact implementation depends on the existing structure — the implementer should follow the existing pattern for "Parakeet vs Whisper" branching and add a `.vibevoice` arm.

- [ ] **Step 6: Add VibeVoice in-flight tracking**

Add a single-flight latch to the scheduler:

```swift
private var vibevoiceInFlight = false

private func dispatchVibeVoice(job: STTJob) async throws -> STTResult {
    // Single-flight: wait if another VibeVoice job is in progress.
    while vibevoiceInFlight {
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    }
    vibevoiceInFlight = true
    defer { vibevoiceInFlight = false }

    try await runtime.ensureVibeVoiceLoaded()
    return try await runtime.vibevoice().transcribe(
        audioPath: job.audioPath,
        job: job.kind
    )
}
```

The 50 ms poll interval is a simplification — production code should use a continuation-based wait, but this works and is testable.

- [ ] **Step 7: Run full STT tests**

```bash
swift test --filter STT 2>&1 | grep -E "Executed [0-9]+ tests, with [^0]" | tail -3
```

Expected: All pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/MacParakeetCore/STT/STTScheduler.swift \
        Tests/MacParakeetTests/STT/STTSchedulerVibeVoiceTests.swift
git commit -m "feat(stt): scheduler resolves engine per job + VibeVoice slot guardrails"
```

---

## Task 8: Extend CLI `transcribe --engine vibevoice`

**Files:**
- Modify: `Sources/CLI/Commands/TranscribeCommand.swift`
- Modify: `Tests/CLITests/TranscribeCommandTests.swift` (or similar — `grep` for existing)

- [ ] **Step 1: Locate the existing engine flag handling**

```bash
grep -n "engine\|--engine\|Whisper\|Parakeet" Sources/CLI/Commands/TranscribeCommand.swift | head -20
```

Look for where the `--engine` option is declared (probably `@Option`). The current valid values are `parakeet` and `whisper`. We're adding `vibevoice`.

- [ ] **Step 2: Write failing test**

Add to the existing TranscribeCommand test file (find via `ls Tests/CLITests/`):

```swift
func testAcceptsVibevoiceEngineFlag() throws {
    // Parse-only test: the parser accepts `--engine vibevoice` without error.
    let cmd = try TranscribeCommand.parse(["--engine", "vibevoice", "/tmp/foo.wav"])
    // Cmd has an internal property exposing the resolved engine string.
    XCTAssertEqual(cmd.engineString, "vibevoice")
}

func testLanguageFlagWithVibeVoiceTriggersWarning() throws {
    // VibeVoice doesn't take language hints. The CLI should accept the flag
    // but emit a warning to stderr. We can't easily test stderr in unit
    // tests; assert at minimum that the parse doesn't crash.
    let cmd = try TranscribeCommand.parse(["--engine", "vibevoice", "--language", "ja", "/tmp/foo.wav"])
    XCTAssertEqual(cmd.engineString, "vibevoice")
}
```

- [ ] **Step 3: Run to confirm failure**

```bash
swift test --filter TranscribeCommand 2>&1 | tail -5
```

Expected: FAIL — `vibevoice` not a valid engine choice.

- [ ] **Step 4: Update the option type**

In `Sources/CLI/Commands/TranscribeCommand.swift`, find the engine option. If it's defined like:

```swift
@Option var engine: String = "parakeet"
```

with validation later in the run method, add `"vibevoice"` to the accepted values. If it's an enum-typed option, add a `.vibevoice` case to the CLI's engine enum (likely a separate type from `SpeechEnginePreference`).

In the run method, when `engine == "vibevoice"`:

1. If `--language` was also provided, print a warning to stderr: `"warning: --language is ignored when --engine vibevoice (language auto-detected)"`
2. Dispatch through `STTScheduler` the same way Whisper does (the scheduler handles the rest).

- [ ] **Step 5: Run tests**

```bash
swift test --filter TranscribeCommand 2>&1 | tail -5
```

Expected: Tests pass.

- [ ] **Step 6: Smoke-test the CLI**

```bash
swift run macparakeet-cli transcribe --engine vibevoice ~/Downloads/some-test-file.wav 2>&1 | head -5
```

Expected: Transcription begins (assumes model is installed). If the model isn't installed, expect a clean error message about missing model files.

- [ ] **Step 7: Commit**

```bash
git add Sources/CLI/Commands/TranscribeCommand.swift Tests/CLITests/*.swift
git commit -m "feat(cli): transcribe --engine vibevoice (with --language warning)"
```

---

## Task 9: New CLI subcommand `stt download-model`

**Files:**
- Create: `Sources/CLI/Commands/STTDownloadModelCommand.swift`
- Create: `Tests/CLITests/STTDownloadModelCommandTests.swift`
- Modify: parent CLI command structure to register the new subcommand (likely `Sources/CLI/Commands/<something>.swift` that aggregates subcommands)

- [ ] **Step 1: Locate the existing CLI command registration**

```bash
grep -rn "subcommands\b\|CommandConfiguration\|TranscribeCommand" Sources/CLI/ | head -10
```

Find where top-level subcommands are registered (likely in a `MacParakeetCLI.swift` or `main.swift`).

- [ ] **Step 2: Write failing tests**

Create `Tests/CLITests/STTDownloadModelCommandTests.swift`:

```swift
import XCTest
@testable import CLI

final class STTDownloadModelCommandTests: XCTestCase {

    func testParsesEngineFlag() throws {
        let cmd = try STTDownloadModelCommand.parse(["--engine", "vibevoice"])
        XCTAssertEqual(cmd.engine, "vibevoice")
    }

    func testRejectsUnknownEngine() {
        XCTAssertThrowsError(try STTDownloadModelCommand.parse(["--engine", "bogus"]))
    }

    func testParsesForceFlag() throws {
        let cmd = try STTDownloadModelCommand.parse(["--engine", "vibevoice", "--force"])
        XCTAssertTrue(cmd.force)
    }
}
```

- [ ] **Step 3: Run to confirm failure**

```bash
swift test --filter STTDownloadModelCommandTests 2>&1 | tail -5
```

Expected: FAIL — type undefined.

- [ ] **Step 4: Create the subcommand**

Create `Sources/CLI/Commands/STTDownloadModelCommand.swift`:

```swift
import ArgumentParser
import Foundation
import MacParakeetCore

public struct STTDownloadModelCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "download-model",
        abstract: "Download an STT engine's model files to the conventional location."
    )

    @Option(name: .long, help: "Engine to download: vibevoice (only choice currently — whisper has a separate first-run path).")
    public var engine: String = "vibevoice"

    @Flag(name: .long, help: "Re-download even if the model already exists with the expected hash.")
    public var force: Bool = false

    public init() {}

    public func run() async throws {
        let normalized = engine.lowercased()
        guard normalized == "vibevoice" else {
            throw ValidationError("Only `--engine vibevoice` is supported. Whisper has its own first-run download path.")
        }
        let dir = VibeVoiceModelDownloader.defaultModelDirectory()
        if !force, VibeVoiceModelDownloader.areModelsInstalled(at: dir) {
            print("Already installed at \(dir.path). Use --force to re-download.")
            return
        }
        let downloader = VibeVoiceModelDownloader()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        try await downloader.downloadAll(to: dir) { done, total in
            let pct = total > 0 ? Int((Double(done) / Double(total)) * 100) : 0
            let doneStr = formatter.string(fromByteCount: done)
            let totalStr = formatter.string(fromByteCount: total)
            print("\u{1B}[2K\r[\(pct)%] \(doneStr) / \(totalStr)", terminator: "")
        }
        print("\nDone. Installed at \(dir.path)")
    }
}
```

Then create a parent `STTCommand` if one doesn't exist:

```swift
public struct STTCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "stt",
        abstract: "Speech-to-text engine management.",
        subcommands: [STTDownloadModelCommand.self]
    )
    public init() {}
}
```

Register `STTCommand.self` in the top-level CLI's `subcommands:` array.

- [ ] **Step 5: Run tests**

```bash
swift test --filter STTDownloadModelCommandTests 2>&1 | tail -5
```

Expected: 3 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/CLI/Commands/STTDownloadModelCommand.swift \
        Sources/CLI/<parent command file>.swift \
        Tests/CLITests/STTDownloadModelCommandTests.swift
git commit -m "feat(cli): stt download-model subcommand"
```

---

## Task 10: HealthCommand reports VibeVoice + CHANGELOG entry

**Files:**
- Modify: `Sources/CLI/Commands/HealthCommand.swift`
- Modify: `Sources/CLI/CHANGELOG.md`

- [ ] **Step 1: Locate the existing engine reporting in `HealthCommand`**

```bash
grep -n "Parakeet\|Whisper\|engine" Sources/CLI/Commands/HealthCommand.swift | head -15
```

Find the section that lists engine availability.

- [ ] **Step 2: Add VibeVoice to the report**

Insert a new engine row in the health output. The exact code depends on how the existing rows are structured. Roughly:

```swift
let vibevoiceInstalled = VibeVoiceModelDownloader.areModelsInstalled()
print("  VibeVoice    \(vibevoiceInstalled ? "ready" : "model missing (run `stt download-model --engine vibevoice`)")")
```

- [ ] **Step 3: Add a CHANGELOG entry**

Append to `Sources/CLI/CHANGELOG.md` (the version bump determines whether this is a minor or patch — `--engine vibevoice` is a new accepted value of an existing option, so it's a minor version bump per the CLI semver policy):

```markdown
## [X.Y.0] - 2026-05-25

### Added
- `transcribe --engine vibevoice` — transcribe via VibeVoice-ASR (third local engine alongside Parakeet and Whisper). 10 GB model, ~RTF 0.4 on M1 Max, returns diarized segments.
- `stt download-model --engine vibevoice` — download VibeVoice model files to the conventional location.
- `health` now reports VibeVoice engine availability alongside Parakeet and Whisper.

### Notes
- `--language` is accepted-but-ignored when paired with `--engine vibevoice` (the model auto-detects). A warning is printed to stderr.
```

(Look up the current version in CHANGELOG.md and bump appropriately.)

- [ ] **Step 4: Smoke-test**

```bash
swift run macparakeet-cli health 2>&1 | head -20
```

Expected: VibeVoice line appears with appropriate status.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLI/Commands/HealthCommand.swift Sources/CLI/CHANGELOG.md
git commit -m "feat(cli): health reports VibeVoice + CHANGELOG entry"
```

---

## Task 11: SettingsViewModel — bind to SpeechEnginePreferences

**Files:**
- Modify: `Sources/MacParakeetViewModels/SettingsViewModel.swift`

The existing view model has a single `speechEnginePreference: SpeechEnginePreference` property. Replace it with bindings to the full `SpeechEnginePreferences` blob.

- [ ] **Step 1: Read the current speechEnginePreference handling**

```bash
grep -n "speechEnginePreference" Sources/MacParakeetViewModels/SettingsViewModel.swift | head -10
```

Note every line that touches the property — they all need updating.

- [ ] **Step 2: Add a new persisted property**

Inside the `SettingsViewModel` class, add (alongside the existing `speechEnginePreference`):

```swift
@ObservationIgnored
public var speechEnginePreferences: SpeechEnginePreferences {
    didSet {
        speechEnginePreferences.save(to: defaults)
        // Mirror the global into the legacy property so any callers
        // not yet migrated still see the right value.
        speechEnginePreference = speechEnginePreferences.global
    }
}
```

Initialize it in `init`:

```swift
self.speechEnginePreferences = SpeechEnginePreferences.current(defaults: defaults)
```

Keep the existing `speechEnginePreference` property — it shadows `speechEnginePreferences.global` for the duration of the migration. New UI uses `speechEnginePreferences`; existing UI references `speechEnginePreference` until they're updated in Task 14.

- [ ] **Step 3: Add convenience accessors for the four selectors**

For SwiftUI binding ergonomics, expose four bindings that the new `SpeechEngineCard` view can use:

```swift
public var globalEngine: SpeechEnginePreference {
    get { speechEnginePreferences.global }
    set { speechEnginePreferences.global = newValue }
}

public var dictationEngineSelection: FeatureEngineSelection {
    get { speechEnginePreferences.dictation }
    set { speechEnginePreferences.dictation = newValue }
}

public var fileTranscriptionEngineSelection: FeatureEngineSelection {
    get { speechEnginePreferences.fileTranscription }
    set { speechEnginePreferences.fileTranscription = newValue }
}

public var meetingRecordingEngineSelection: FeatureEngineSelection {
    get { speechEnginePreferences.meetingRecording }
    set { speechEnginePreferences.meetingRecording = newValue }
}
```

- [ ] **Step 4: Build to verify**

```bash
swift build 2>&1 | grep -E "error:" | head -10
```

Expected: no errors. Existing SettingsView keeps compiling against the legacy `speechEnginePreference`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetViewModels/SettingsViewModel.swift
git commit -m "feat(settings): expose SpeechEnginePreferences with per-feature bindings"
```

---

## Task 12: `EngineModelStatusRow` SwiftUI view

**Files:**
- Create: `Sources/MacParakeet/Views/Settings/EngineModelStatusRow.swift`

A single row showing one engine's installation status with optional `[Download]` button.

- [ ] **Step 1: Create the view**

```swift
import SwiftUI
import MacParakeetCore

struct EngineModelStatusRow: View {
    let engine: SpeechEnginePreference
    let isInstalled: Bool
    let downloadProgress: Double?     // 0.0-1.0 when downloading; nil otherwise
    let downloadAction: () -> Void
    let cancelDownloadAction: (() -> Void)?

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            engineIcon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.displayName)
                    .font(DesignSystem.Typography.body)
                if let progress = downloadProgress {
                    progressView(progress)
                } else {
                    Text(isInstalled ? "Installed" : missingText)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if downloadProgress != nil {
                Button("Cancel") { cancelDownloadAction?() }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            } else if !isInstalled, needsDownloadButton {
                Button("Download") { downloadAction() }
                    .parakeetAction(.secondary)
            }
        }
    }

    private var engineIcon: some View {
        Image(systemName: iconName)
            .foregroundStyle(DesignSystem.Colors.accent.opacity(0.7))
    }

    private var iconName: String {
        switch engine {
        case .parakeet: return "bird"
        case .whisper: return "globe"
        case .vibevoice: return "person.wave.2"
        }
    }

    private var missingText: String {
        switch engine {
        case .vibevoice: return "9.7 GB needed"
        case .whisper: return "Not installed"
        case .parakeet: return "Not installed"
        }
    }

    /// Phase 2.2 only adds an in-Settings download for VibeVoice; Parakeet and
    /// Whisper have existing first-run paths that handle their installs.
    private var needsDownloadButton: Bool {
        engine == .vibevoice
    }

    private func progressView(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 200)
            Text("\(Int(progress * 100))%")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
swift build 2>&1 | grep -E "error:" | head -5
```

Expected: no errors. (Views aren't tested directly per CLAUDE.md — they're verified by the dev app smoke test.)

- [ ] **Step 3: Commit**

```bash
git add Sources/MacParakeet/Views/Settings/EngineModelStatusRow.swift
git commit -m "feat(settings): EngineModelStatusRow view"
```

---

## Task 13: `SpeechEngineCard` SwiftUI view

**Files:**
- Create: `Sources/MacParakeet/Views/Settings/SpeechEngineCard.swift`

The 4-picker UI: global default + dictation + file transcription + meeting recording.

- [ ] **Step 1: Create the view**

```swift
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct SpeechEngineCard: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        SettingsCard(
            title: "Speech Engines",
            subtitle: "Pick a default engine and optionally override per feature.",
            icon: "waveform",
            iconTint: DesignSystem.Colors.accent
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                globalSection
                Divider()
                featurePicker(
                    label: "Dictation",
                    selection: bind(\.dictationEngineSelection),
                    hint: dictationHint
                )
                featurePicker(
                    label: "File transcription",
                    selection: bind(\.fileTranscriptionEngineSelection),
                    hint: nil
                )
                featurePicker(
                    label: "Meeting recording",
                    selection: bind(\.meetingRecordingEngineSelection),
                    hint: meetingHint
                )
                Divider()
                modelsSection
            }
        }
    }

    private var globalSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Default engine").font(DesignSystem.Typography.body)
                Text("Used when a feature below is set to \"Use default\".")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            Picker("", selection: bind(\.globalEngine)) {
                ForEach(SpeechEnginePreference.allCases, id: \.self) { e in
                    Text(e.displayName).tag(e)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 180)
        }
    }

    private func featurePicker(
        label: String,
        selection: Binding<FeatureEngineSelection>,
        hint: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(DesignSystem.Typography.body)
                Spacer()
                Picker("", selection: selection) {
                    Text("Use default").tag(FeatureEngineSelection.global)
                    ForEach(SpeechEnginePreference.allCases, id: \.self) { e in
                        Text(e.displayName).tag(FeatureEngineSelection.specific(e))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }
            if let hint {
                Text(hint)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Engine models").font(DesignSystem.Typography.body)
            EngineModelStatusRow(
                engine: .parakeet, isInstalled: true,
                downloadProgress: nil, downloadAction: {}, cancelDownloadAction: nil
            )
            EngineModelStatusRow(
                engine: .whisper, isInstalled: true,
                downloadProgress: nil, downloadAction: {}, cancelDownloadAction: nil
            )
            EngineModelStatusRow(
                engine: .vibevoice,
                isInstalled: viewModel.isVibeVoiceModelInstalled,
                downloadProgress: viewModel.vibevoiceDownloadProgress,
                downloadAction: { viewModel.startVibeVoiceDownload() },
                cancelDownloadAction: { viewModel.cancelVibeVoiceDownload() }
            )
        }
    }

    // MARK: - Hints

    private var dictationHint: String? {
        let resolved = viewModel.speechEnginePreferences.engine(for: .dictation)
        if resolved == .vibevoice {
            return "⚠ VibeVoice has ~13 s startup latency. Dictation may feel slow."
        }
        return nil
    }

    private var meetingHint: String? {
        let resolved = viewModel.speechEnginePreferences.engine(for: .meetingFinalize)
        if resolved == .vibevoice {
            return "✨ VibeVoice provides native speaker labels."
        }
        return nil
    }

    // MARK: - Bindings

    private func bind<T>(_ keyPath: ReferenceWritableKeyPath<SettingsViewModel, T>) -> Binding<T> {
        Binding(
            get: { viewModel[keyPath: keyPath] },
            set: { viewModel[keyPath: keyPath] = $0 }
        )
    }
}
```

The view references three view-model fields that don't exist yet:
- `viewModel.isVibeVoiceModelInstalled: Bool`
- `viewModel.vibevoiceDownloadProgress: Double?`
- `viewModel.startVibeVoiceDownload()` and `viewModel.cancelVibeVoiceDownload()`

These are added in Task 11 (already done — but you can extend that task's commit if needed). Actually, since Task 11 has already been committed, add a follow-up small commit to `SettingsViewModel.swift` here:

```swift
// Inside SettingsViewModel:
@ObservationIgnored
private var vibevoiceDownloader: VibeVoiceModelDownloader?

public var isVibeVoiceModelInstalled: Bool {
    VibeVoiceModelDownloader.areModelsInstalled()
}

public var vibevoiceDownloadProgress: Double? = nil  // 0.0-1.0 during download; nil otherwise

public func startVibeVoiceDownload() {
    guard vibevoiceDownloader == nil else { return }
    let downloader = VibeVoiceModelDownloader()
    self.vibevoiceDownloader = downloader
    vibevoiceDownloadProgress = 0
    Task {
        do {
            try await downloader.downloadAll { @Sendable [weak self] done, total in
                Task { @MainActor in
                    self?.vibevoiceDownloadProgress = total > 0 ? Double(done) / Double(total) : 0
                }
            }
            await MainActor.run {
                self.vibevoiceDownloadProgress = nil
                self.vibevoiceDownloader = nil
            }
        } catch {
            await MainActor.run {
                self.vibevoiceDownloadProgress = nil
                self.vibevoiceDownloader = nil
            }
        }
    }
}

public func cancelVibeVoiceDownload() {
    Task { await vibevoiceDownloader?.cancel() }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | grep -E "error:" | head -5
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacParakeet/Views/Settings/SpeechEngineCard.swift \
        Sources/MacParakeetViewModels/SettingsViewModel.swift
git commit -m "feat(settings): SpeechEngineCard (4 pickers + model status rows)"
```

---

## Task 14: Replace existing engine picker in SettingsView

**Files:**
- Modify: `Sources/MacParakeet/Views/Settings/SettingsView.swift`

The current Modes tab has a custom Parakeet/Whisper card around lines 1660-1745 (per the earlier grep). Replace it with the new `SpeechEngineCard`.

- [ ] **Step 1: Locate the existing card**

```bash
grep -n "speechEnginePreference\|Parakeet\|EngineOptionTile" Sources/MacParakeet/Views/Settings/SettingsView.swift | head -20
```

Identify the block that renders the engine picker (likely uses `EngineOptionTile` views per the grep result).

- [ ] **Step 2: Replace with new card**

Remove the existing engine picker block and replace with:

```swift
SpeechEngineCard(viewModel: viewModel)
```

- [ ] **Step 3: Build + launch dev app**

```bash
swift build 2>&1 | grep -E "error:" | head -5
scripts/dev/run_app.sh
```

Expected: app launches, Settings → Modes tab shows the new card with 4 pickers and 3 engine rows.

- [ ] **Step 4: Manual smoke test**
- Change global engine → file transcription via CLI uses the new engine
- Set dictation to .specific(.whisper) → dictation hotkey uses Whisper
- Set meeting to .specific(.vibevoice) — verify the hint about diarization appears
- Click Download for VibeVoice (if not installed) — verify progress shows

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeet/Views/Settings/SettingsView.swift
git commit -m "feat(settings): replace single engine picker with SpeechEngineCard"
```

---

## Task 15: Update spec/06-stt-engine.md

**Files:**
- Modify: `spec/06-stt-engine.md`

- [ ] **Step 1: Add a section on VibeVoice**

Read the existing spec to find the right insertion point — likely after the WhisperKit section. Add ~150 words covering:
- VibeVoice as the third engine, alongside Parakeet (default) and Whisper
- Native speaker diarization in the output
- 10 GB model, ~RTF 0.4 on Apple Silicon
- Per-feature engine selection via `SpeechEnginePreferences`
- VibeVoice never claims the dictation slot (scheduler guardrail)
- Subtitle export limitation: segment-level cues only (no word-level alignment in Phase 2.2)
- Cross-reference to ADR-021 (sibling engine pattern)

- [ ] **Step 2: Commit**

```bash
git add spec/06-stt-engine.md
git commit -m "docs(spec): document VibeVoice as third STT engine"
```

---

## Task 16: End-to-end integration test

**Files:**
- Create: `Tests/MacParakeetTests/Integration/VibeVoiceEndToEndTests.swift`

Verifies a real transcription run through the full stack: preferences → scheduler → runtime → engine → result.

- [ ] **Step 1: Write the test**

```swift
import XCTest
@testable import MacParakeetCore

final class VibeVoiceEndToEndTests: XCTestCase {

    func testVibeVoiceEndToEndFromScheduler() async throws {
        // Skip if model not installed
        guard VibeVoiceModelDownloader.areModelsInstalled() else {
            throw XCTSkip("VibeVoice model not installed")
        }
        // Skip if fixture not bundled
        guard let fixtureURL = Bundle.module.url(forResource: "tiny_ted", withExtension: "wav") else {
            throw XCTSkip("tiny_ted.wav fixture not available")
        }

        // Configure preferences with VibeVoice for file transcription
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        var prefs = SpeechEnginePreferences()
        prefs.fileTranscription = .specific(.vibevoice)
        prefs.save(to: defaults)

        // Build the scheduler with a runtime and run a job
        let runtime = STTRuntime()
        let scheduler = STTScheduler(runtime: runtime)  // adjust to actual constructor
        let result = try await scheduler.transcribe(
            audioPath: fixtureURL.path,
            job: .fileTranscription,
            onProgress: nil
        )

        XCTAssertEqual(result.engine, .vibevoice)
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertNotNil(result.segments)
        XCTAssertFalse(result.segments!.isEmpty)
        XCTAssertTrue(result.text.lowercased().contains("college"))
    }
}
```

(Adjust the scheduler constructor call to match the actual signature — may need to load preferences from a non-default UserDefaults, depending on how `STTScheduler` is wired.)

- [ ] **Step 2: Run**

```bash
swift test --filter VibeVoiceEndToEndTests 2>&1 | tail -8
```

Expected: PASS (or SKIP if model isn't installed).

- [ ] **Step 3: Run the full test suite**

```bash
swift test 2>&1 | grep -E "Executed [0-9]+ tests, with [^0]" | tail -3
```

Expected: All tests pass with the same baseline + ~30 new tests across this phase.

- [ ] **Step 4: Commit**

```bash
git add Tests/MacParakeetTests/Integration/VibeVoiceEndToEndTests.swift
git commit -m "test(stt): VibeVoice end-to-end integration test"
```

---

## Self-Review

After writing this plan I re-read it against the spec. Findings:

### Spec coverage
- ✅ Section "Type System": Tasks 1, 2, 3
- ✅ Section "Result Type": Task 2 (the `segments` field already existed — extended with `speakerId`)
- ✅ Section "VibeVoiceEngine": Task 4
- ✅ Section "STTRuntime Changes": Task 6
- ✅ Section "STTScheduler Changes": Task 7
- ✅ Section "Settings UI": Tasks 11, 12, 13, 14
- ✅ Section "Model Download": Tasks 5, 13 (UI), 9 (CLI)
- ✅ Section "CLI": Tasks 8, 9, 10
- ✅ Testing Strategy: each new component has a test task
- ✅ File Inventory: matches Tasks 1-16

### Placeholder scan
- The SHA-256 hash placeholders in Task 5's downloader are intentional — the engineer fills them in at Task 5 Step 4 from the locally-downloaded files (the actual values can only be obtained by running `shasum` on the real binaries).
- Task 7 Step 5 ("Wire engine resolution into the dispatch path") deliberately refers to "the implementer should follow the existing pattern" because the exact shape of `STTScheduler`'s dispatch is too dependent on what's there to specify line-by-line in this plan. The pattern is well-defined.
- Task 8, 9, 10 reference grep'ing the existing files to find the right insertion points — same justification.

### Type consistency
- `SpeechEnginePreference` (singular) is the enum, `SpeechEnginePreferences` (plural) is the container. Used consistently.
- `FeatureEngineSelection.global` / `.specific(...)` used consistently.
- `STTSegment.speakerId: Int?` used consistently in Tasks 2 and 4.
- `STTResult.engine` is non-optional (`SpeechEnginePreference`) — Task 4 passes `engine: .vibevoice` directly, not `engine: SpeechEnginePreference?(.vibevoice)`.
- `STTResult.engineVariant` (not `modelVariant`) used consistently.
- `STTJobKind` cases `.dictation`, `.fileTranscription`, `.meetingFinalize`, `.meetingLiveChunk` used consistently.

No gaps or inconsistencies. Plan is ready for execution.
