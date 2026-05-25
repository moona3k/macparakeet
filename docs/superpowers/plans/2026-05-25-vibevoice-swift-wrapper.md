# VibeVoice Swift Wrapper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `VibeVoiceCore` Swift Package target inside the macparakeet repo that wraps the `vibevoice.cpp` C ABI, exposing a clean `VibeVoiceASR` actor with a `transcribe(wavPath:) async throws -> [DiarizedSegment]` API. This is Phase 2.1 of the VibeVoice integration — covers ONLY the Swift wrapper. Engine plumbing into `STTRuntime` / `STTScheduler` and UI changes are out of scope for this plan and will be Phase 2.2.

**Architecture:** vibevoice.cpp is already built at `/Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/vibevoice-spike/vibevoice.cpp/build/`. We vendor the C ABI header (`vibevoice_capi.h`) into the macparakeet repo and add a new `VibeVoiceCore` SPM target with C interop. The Swift wrapper calls 4 C functions (`vv_capi_load`, `vv_capi_asr`, `vv_capi_unload`, `vv_capi_version`), parses the returned JSON, and returns Swift-native `DiarizedSegment` values. The actual `libvibevoice.a` + `libggml*.dylib` libraries are referenced via `unsafeFlags` linker settings pointing at the spike build dir — not committed to git.

**Tech Stack:** Swift 6.0, SwiftPM, C interop via `module.modulemap`, `actor` for thread safety, `JSONDecoder` for parsing the C ABI's JSON output. No new third-party Swift dependencies.

**Key constraints:**
- Model file is ~10 GB — NEVER committed to git. Tests use `XCTSkip` when the model isn't found at the expected path (`~/Library/Application Support/MacParakeet/models/vibevoice/`).
- Library files (`libvibevoice.a`, `libggml*.dylib`) are NOT committed — they're built locally via `vibevoice-spike/vibevoice.cpp`. Document the build dependency.
- C ABI's single-engine-per-process lifetime model (one `vv_capi_load` per process) maps cleanly to an actor. Calling `loadModel` twice swaps the engine; the actor serializes.
- No memory leak from `vv_capi_asr`: the JSON output buffer is caller-owned (Swift `[CChar]` array).

---

## File Structure

**New files (committed to git):**
- `Sources/VibeVoiceCore/include/vibevoice_capi.h` — vendored C ABI header (106 lines, MIT licensed, copied from upstream)
- `Sources/VibeVoiceCore/include/module.modulemap` — module map so Swift can import the C header
- `Sources/VibeVoiceCore/CVibeVoiceShim.c` — empty C source file (SPM requires at least one source file in a C target)
- `Sources/VibeVoiceCore/DiarizedSegment.swift` — the result type
- `Sources/VibeVoiceCore/VibeVoiceASRError.swift` — typed error enum
- `Sources/VibeVoiceCore/VibeVoiceASR.swift` — the actor wrapping the C ABI
- `Tests/VibeVoiceCoreTests/VibeVoiceASRTests.swift` — unit tests
- `Tests/VibeVoiceCoreTests/DiarizedSegmentTests.swift` — JSON decoding tests
- `Tests/VibeVoiceCoreTests/Resources/tiny_ted.wav` — ~5-second 24kHz mono WAV test fixture (~250 KB)

**Modified files:**
- `Package.swift` — add `VibeVoiceCore` C target + Swift target + test target + library product
- `.gitignore` — ignore any locally-built vibevoice artifacts that might land in repo paths
- `docs/spec/06-stt-engine.md` — note VibeVoice as a future third engine (one-line cross-reference; full doc update is Phase 2.2)

**NOT committed:**
- Pre-built `libvibevoice.a`, `libggml*.dylib` (referenced from external spike dir)
- Model files (`vibevoice-asr-q4_k.gguf`, `tokenizer.gguf`) — too large; tests skip when absent

---

## Task 1: Vendor the C ABI header and create module map

**Files:**
- Create: `Sources/VibeVoiceCore/include/vibevoice_capi.h`
- Create: `Sources/VibeVoiceCore/include/module.modulemap`
- Create: `Sources/VibeVoiceCore/CVibeVoiceShim.c`

- [ ] **Step 1: Copy the C ABI header verbatim from the spike**

```bash
cp /Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/vibevoice-spike/vibevoice.cpp/include/vibevoice_capi.h \
   Sources/VibeVoiceCore/include/vibevoice_capi.h
```

Expected: File copied. `wc -l Sources/VibeVoiceCore/include/vibevoice_capi.h` should report ~106 lines.

- [ ] **Step 2: Create the module map**

`Sources/VibeVoiceCore/include/module.modulemap`:

```
module CVibeVoice {
    header "vibevoice_capi.h"
    export *
}
```

- [ ] **Step 3: Create empty C shim (SPM needs at least one C source file)**

`Sources/VibeVoiceCore/CVibeVoiceShim.c`:

```c
// Empty shim. SPM requires at least one source file in a C target;
// the actual implementation lives in libvibevoice.a (built externally
// from vibevoice-spike/vibevoice.cpp). See plans/2026-05-25-vibevoice-swift-wrapper.md.
```

- [ ] **Step 4: Commit**

```bash
git add Sources/VibeVoiceCore/include/vibevoice_capi.h \
        Sources/VibeVoiceCore/include/module.modulemap \
        Sources/VibeVoiceCore/CVibeVoiceShim.c
git commit -m "feat(vibevoice): vendor C ABI header and module map"
```

---

## Task 2: Add VibeVoiceCore C target to Package.swift

**Files:**
- Modify: `Package.swift` (add new C target + library product)

- [ ] **Step 1: Read current Package.swift target list**

```bash
grep -n "^        \.target\|^        \.executableTarget\|^        \.testTarget" Package.swift
```

Expected: List of existing targets including `MacParakeetObjCShims` (the precedent for C interop).

- [ ] **Step 2: Add VibeVoiceCore C target**

Add to `targets:` array in `Package.swift`, right after the `MacParakeetObjCShims` target (which is the existing precedent for C interop):

```swift
// VibeVoiceCore — C-interop layer for the vibevoice.cpp ASR engine.
//
// The actual C++ library is built externally via the canonical
// `localai-org/vibevoice.cpp` CMake build (see scripts/dev/build_vibevoice.sh
// in a future task). At build time, this target only needs the header
// and a stub `.c` to keep SPM happy; the Swift target above is what
// actually links against the prebuilt static library.
.target(
    name: "VibeVoiceCore",
    path: "Sources/VibeVoiceCore",
    exclude: [
        "DiarizedSegment.swift",
        "VibeVoiceASRError.swift",
        "VibeVoiceASR.swift",
    ],
    publicHeadersPath: "include"
),
```

(Excludes the Swift files — those go in the separate Swift target in Task 3. SPM doesn't let one target mix C and Swift sources cleanly.)

- [ ] **Step 3: Build to verify the C target compiles**

Run: `swift build --target VibeVoiceCore`

Expected: `Build complete!` with no errors. Module `CVibeVoice` is now importable.

- [ ] **Step 4: Commit**

```bash
git add Package.swift
git commit -m "feat(vibevoice): add VibeVoiceCore C target to SPM"
```

---

## Task 3: Add the Swift sibling target

**Files:**
- Modify: `Package.swift` (add Swift target that consumes the C module)

The C target from Task 2 only exposes the module map. We need a sibling Swift target that depends on it and contains the Swift wrapper code.

- [ ] **Step 1: Rename Task 2's C target to a C-only "system module"**

Replace the `VibeVoiceCore` target added in Task 2 with this two-target pair:

```swift
// C interop module — exposes the vibevoice_capi.h symbols to Swift.
// Contains only the module map + a stub .c; the real library is
// linked via the Swift target's linkerSettings.
.target(
    name: "CVibeVoice",
    path: "Sources/VibeVoiceCore",
    exclude: [
        "DiarizedSegment.swift",
        "VibeVoiceASRError.swift",
        "VibeVoiceASR.swift",
    ],
    publicHeadersPath: "include"
),

// Swift wrapper around the vibevoice.cpp C ABI.
.target(
    name: "VibeVoiceCore",
    dependencies: ["CVibeVoice"],
    path: "Sources/VibeVoiceCore",
    exclude: [
        "include",
        "CVibeVoiceShim.c",
    ],
    linkerSettings: [
        // Static vibevoice library (built externally via vibevoice.cpp's CMake).
        .unsafeFlags([
            "-L", "/Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/vibevoice-spike/vibevoice.cpp/build",
            "-L", "/Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/vibevoice-spike/vibevoice.cpp/build/third_party/ggml/src",
            "-lvibevoice",
            "-lggml", "-lggml-base", "-lggml-cpu",
            // Required system frameworks for ggml's Metal + Accelerate backends.
            "-framework", "Metal",
            "-framework", "MetalKit",
            "-framework", "Foundation",
            "-framework", "Accelerate",
        ]),
    ]
),
```

- [ ] **Step 2: Add library product**

In the `products:` array, add:

```swift
.library(name: "VibeVoiceCore", targets: ["VibeVoiceCore"]),
```

- [ ] **Step 3: Build to verify both targets compile**

Run: `swift build --target VibeVoiceCore`

Expected: `Build complete!`. There will be a linker warning about unresolved symbols since `Sources/VibeVoiceCore/` doesn't yet contain Swift files that reference the C ABI. That's fine — the link step only runs when something USES VibeVoiceCore.

- [ ] **Step 4: Commit**

```bash
git add Package.swift
git commit -m "feat(vibevoice): add Swift wrapper target with linker settings"
```

---

## Task 4: Define DiarizedSegment with JSON decoding

**Files:**
- Create: `Sources/VibeVoiceCore/DiarizedSegment.swift`
- Create: `Tests/VibeVoiceCoreTests/DiarizedSegmentTests.swift`
- Modify: `Package.swift` (add test target)

- [ ] **Step 1: Add the test target to Package.swift**

In the `targets:` array, after the existing `.testTarget` entries:

```swift
.testTarget(
    name: "VibeVoiceCoreTests",
    dependencies: ["VibeVoiceCore"],
    path: "Tests/VibeVoiceCoreTests",
    resources: [.copy("Resources")]
),
```

- [ ] **Step 2: Write the failing JSON decoding test**

`Tests/VibeVoiceCoreTests/DiarizedSegmentTests.swift`:

```swift
import XCTest
@testable import VibeVoiceCore

/// Pins the JSON shape that `vv_capi_asr` returns. Real output from the
/// spike on a 60s TED clip was:
///   [{"Start":0,"End":12.7,"Speaker":0,"Content":"So in college..."}, ...]
final class DiarizedSegmentTests: XCTestCase {

    func testDecodesSingleSegment() throws {
        let json = #"""
        [{"Start":0,"End":12.7,"Speaker":0,"Content":"So in college, I was a government major."}]
        """#.data(using: .utf8)!
        let segments = try JSONDecoder().decode([DiarizedSegment].self, from: json)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].startSec, 0)
        XCTAssertEqual(segments[0].endSec, 12.7)
        XCTAssertEqual(segments[0].speakerId, 0)
        XCTAssertEqual(segments[0].text, "So in college, I was a government major.")
    }

    func testDecodesMultipleSegmentsWithDifferentSpeakers() throws {
        let json = #"""
        [
          {"Start":0,"End":2.5,"Speaker":0,"Content":"Hello."},
          {"Start":2.5,"End":5.0,"Speaker":1,"Content":"Hi there."}
        ]
        """#.data(using: .utf8)!
        let segments = try JSONDecoder().decode([DiarizedSegment].self, from: json)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speakerId, 0)
        XCTAssertEqual(segments[1].speakerId, 1)
    }

    func testDecodesEmptyArray() throws {
        let json = "[]".data(using: .utf8)!
        let segments = try JSONDecoder().decode([DiarizedSegment].self, from: json)
        XCTAssertTrue(segments.isEmpty)
    }
}
```

- [ ] **Step 3: Run to confirm it fails**

Run: `swift test --filter DiarizedSegmentTests`

Expected: FAIL — `DiarizedSegment` is not defined.

- [ ] **Step 4: Define `DiarizedSegment`**

`Sources/VibeVoiceCore/DiarizedSegment.swift`:

```swift
import Foundation

/// One diarized speech segment returned by VibeVoice-ASR.
///
/// VibeVoice's C ABI emits JSON of shape
///   `[{"Start": <sec>, "End": <sec>, "Speaker": <int>, "Content": <string>}]`
/// per audio file. This struct mirrors that shape exactly so the JSON
/// decoder can hydrate it without custom transforms.
///
/// `startSec` / `endSec` are in seconds relative to the input audio.
/// `speakerId` is VibeVoice's internal speaker label (0-indexed). Maps
/// to MacParakeet's existing speaker model in the Phase 2.2 wire-up.
public struct DiarizedSegment: Sendable, Equatable, Codable {
    public let startSec: Double
    public let endSec: Double
    public let speakerId: Int
    public let text: String

    public init(startSec: Double, endSec: Double, speakerId: Int, text: String) {
        self.startSec = startSec
        self.endSec = endSec
        self.speakerId = speakerId
        self.text = text
    }

    /// Custom keys: vibevoice.cpp returns PascalCase fields per the
    /// Microsoft VibeVoice reference implementation.
    private enum CodingKeys: String, CodingKey {
        case startSec = "Start"
        case endSec = "End"
        case speakerId = "Speaker"
        case text = "Content"
    }
}
```

- [ ] **Step 5: Run test, expect pass**

Run: `swift test --filter DiarizedSegmentTests`

Expected: PASS, all 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Package.swift \
        Sources/VibeVoiceCore/DiarizedSegment.swift \
        Tests/VibeVoiceCoreTests/DiarizedSegmentTests.swift
git commit -m "feat(vibevoice): DiarizedSegment with JSON decoding"
```

---

## Task 5: Define VibeVoiceASRError

**Files:**
- Create: `Sources/VibeVoiceCore/VibeVoiceASRError.swift`

- [ ] **Step 1: Define the error enum**

`Sources/VibeVoiceCore/VibeVoiceASRError.swift`:

```swift
import Foundation

/// Errors thrown by `VibeVoiceASR`. Mirrors the negative return codes
/// from `vv_capi_load` / `vv_capi_asr`, with a few Swift-level errors
/// for file-not-found and JSON-decode failures.
public enum VibeVoiceASRError: Error, Equatable, Sendable {
    /// `vv_capi_load` returned non-zero. The C ABI doesn't expose a
    /// granular reason; we surface the raw code for logging.
    case loadFailed(code: Int32)

    /// `vv_capi_asr` returned a negative value other than the
    /// "buffer too small" case. Raw code surfaced for logging.
    case transcribeFailed(code: Int32)

    /// `vv_capi_asr` returned -<required-size>, meaning our caller-
    /// owned buffer wasn't large enough to hold the JSON. We grow and
    /// retry up to `VibeVoiceASR.maxBufferGrowAttempts` times before
    /// giving up.
    case outputBufferTooSmall(requiredBytes: Int)

    /// The JSON output decoded by `JSONDecoder` was structurally
    /// unexpected (not an array of segments).
    case malformedJSON(String)

    /// `loadModel` wasn't called, or was called with a path that
    /// doesn't exist on disk.
    case modelNotLoaded

    /// One of the audio / model / tokenizer file paths doesn't exist
    /// on disk. Caught Swift-side before the C call.
    case fileNotFound(URL)
}
```

- [ ] **Step 2: Build to verify no syntax errors**

Run: `swift build --target VibeVoiceCore`

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/VibeVoiceCore/VibeVoiceASRError.swift
git commit -m "feat(vibevoice): typed error enum for ASR client"
```

---

## Task 6: Add a small WAV test fixture

**Files:**
- Create: `Tests/VibeVoiceCoreTests/Resources/tiny_ted.wav`

- [ ] **Step 1: Trim the TED clip down to ~5 seconds**

The full spike-test TED clip is 60 seconds / 2.7 MB. For unit tests we want something smaller (~250 KB, 5 sec). Use the bundled FFmpeg:

```bash
mkdir -p Tests/VibeVoiceCoreTests/Resources
/Applications/MacParakeet.app/Contents/Resources/ffmpeg \
  -i /Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/macparakeet/.build/checkouts/argmax-oss-swift/Tests/WhisperKitTests/Resources/ted_60.m4a \
  -t 5 -ar 24000 -ac 1 -y \
  Tests/VibeVoiceCoreTests/Resources/tiny_ted.wav
```

Expected: `tiny_ted.wav` exists, ~230 KB, 5 seconds, 24 kHz mono PCM s16.

- [ ] **Step 2: Verify the fixture**

Run: `file Tests/VibeVoiceCoreTests/Resources/tiny_ted.wav && ls -lh Tests/VibeVoiceCoreTests/Resources/tiny_ted.wav`

Expected: `RIFF (little-endian) data, WAVE audio, Microsoft PCM, 16 bit, mono 24000 Hz` and size ~230 KB.

- [ ] **Step 3: Commit**

```bash
git add Tests/VibeVoiceCoreTests/Resources/tiny_ted.wav
git commit -m "test(vibevoice): commit 5s WAV fixture for ASR tests"
```

---

## Task 7: Write the failing VibeVoiceASR test

**Files:**
- Create: `Tests/VibeVoiceCoreTests/VibeVoiceASRTests.swift`

This is the integration test — actually loads a real model and transcribes the fixture. Skipped when the model isn't on disk.

- [ ] **Step 1: Write the failing test**

`Tests/VibeVoiceCoreTests/VibeVoiceASRTests.swift`:

```swift
import XCTest
@testable import VibeVoiceCore

/// Integration tests for `VibeVoiceASR`. Skipped when the model isn't
/// present at the expected path (~10 GB download, not committed).
/// Run locally after `scripts/dev/download_vibevoice_model.sh`.
final class VibeVoiceASRTests: XCTestCase {

    /// Where we expect the user to have placed the model. Same path
    /// the Phase 2.2 engine plumbing will use.
    private var modelDir: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("MacParakeet")
            .appendingPathComponent("models")
            .appendingPathComponent("vibevoice")
    }

    private var modelPath: URL { modelDir.appendingPathComponent("vibevoice-asr-q4_k.gguf") }
    private var tokenizerPath: URL { modelDir.appendingPathComponent("tokenizer.gguf") }

    private func skipIfModelMissing() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelPath.path),
              fm.fileExists(atPath: tokenizerPath.path) else {
            throw XCTSkip("VibeVoice model not installed at \(modelDir.path). Run scripts/dev/download_vibevoice_model.sh.")
        }
    }

    private func fixtureURL() throws -> URL {
        let url = Bundle.module.url(forResource: "tiny_ted", withExtension: "wav")
        guard let url else {
            throw XCTSkip("tiny_ted.wav not bundled in test resources")
        }
        return url
    }

    func testTranscribesShortClip() async throws {
        try skipIfModelMissing()
        let audio = try fixtureURL()

        let asr = VibeVoiceASR()
        try await asr.loadModel(modelPath: modelPath, tokenizerPath: tokenizerPath)
        let segments = try await asr.transcribe(wavPath: audio)
        await asr.unload()

        // The 5-second TED excerpt opens with "So in college, I was a
        // government major". We assert non-empty + at least one segment
        // mentions "college" — looser than asserting exact text since
        // quantized inference is non-deterministic at the token level.
        XCTAssertFalse(segments.isEmpty)
        let joinedText = segments.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(
            joinedText.contains("college"),
            "Expected 'college' in transcription; got: \(joinedText)"
        )
    }

    func testTranscribeWithoutLoadThrows() async throws {
        let audio = try fixtureURL()
        let asr = VibeVoiceASR()
        do {
            _ = try await asr.transcribe(wavPath: audio)
            XCTFail("Expected modelNotLoaded; got success")
        } catch VibeVoiceASRError.modelNotLoaded {
            // expected
        } catch {
            XCTFail("Expected modelNotLoaded; got: \(error)")
        }
    }

    func testTranscribeWithMissingAudioThrows() async throws {
        try skipIfModelMissing()
        let asr = VibeVoiceASR()
        try await asr.loadModel(modelPath: modelPath, tokenizerPath: tokenizerPath)
        defer { Task { await asr.unload() } }

        let bogusURL = URL(fileURLWithPath: "/tmp/does-not-exist.wav")
        do {
            _ = try await asr.transcribe(wavPath: bogusURL)
            XCTFail("Expected fileNotFound; got success")
        } catch VibeVoiceASRError.fileNotFound(let url) {
            XCTAssertEqual(url, bogusURL)
        } catch {
            XCTFail("Expected fileNotFound; got: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run to confirm it fails**

Run: `swift test --filter VibeVoiceASRTests`

Expected: FAIL — `VibeVoiceASR` is not defined.

(If the model isn't on disk yet, `testTranscribesShortClip` would skip; the other two failure-path tests should still fail with compile errors at this stage.)

- [ ] **Step 3: Commit the failing test**

```bash
git add Tests/VibeVoiceCoreTests/VibeVoiceASRTests.swift
git commit -m "test(vibevoice): failing tests for VibeVoiceASR actor"
```

---

## Task 8: Implement VibeVoiceASR actor

**Files:**
- Create: `Sources/VibeVoiceCore/VibeVoiceASR.swift`

- [ ] **Step 1: Symlink the model files so the test can find them**

```bash
mkdir -p ~/Library/Application\ Support/MacParakeet/models/vibevoice
ln -sf /Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/vibevoice-spike/vibevoice.cpp/models/vibevoice-asr-q4_k.gguf \
       ~/Library/Application\ Support/MacParakeet/models/vibevoice/vibevoice-asr-q4_k.gguf
ln -sf /Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/vibevoice-spike/vibevoice.cpp/models/tokenizer.gguf \
       ~/Library/Application\ Support/MacParakeet/models/vibevoice/tokenizer.gguf
ls -la ~/Library/Application\ Support/MacParakeet/models/vibevoice/
```

Expected: Both symlinks resolve to the real files in the spike dir.

- [ ] **Step 2: Implement `VibeVoiceASR`**

`Sources/VibeVoiceCore/VibeVoiceASR.swift`:

```swift
import Foundation
import CVibeVoice

/// Swift wrapper around the vibevoice.cpp C ABI. One actor per
/// process — the underlying C library uses a single global engine
/// (`vv_capi_load` is idempotent and replaces the engine on re-call).
///
/// Lifecycle:
/// 1. `loadModel(modelPath:tokenizerPath:)` — must be called once before any
///    `transcribe(...)` call. Takes ~13s on M1 Max with the Q4 GGUF.
/// 2. `transcribe(wavPath:)` — called many times. Returns diarized
///    segments via JSON parsing of the C ABI's output buffer.
/// 3. `unload()` — optional; process exit frees engine state.
public actor VibeVoiceASR {
    /// Initial JSON output buffer. Long-form transcriptions can produce
    /// 50-100 KB of JSON; we start at 256 KB and grow on `outputBufferTooSmall`.
    private static let initialBufferSize: Int = 256 * 1024

    /// Grow up to 16 MB before giving up. Bounds the worst case so a
    /// runaway response can't OOM the host.
    private static let maxBufferSize: Int = 16 * 1024 * 1024

    private var isLoaded: Bool = false

    public init() {}

    /// Library version string from the C ABI. Useful for logging.
    public nonisolated var libraryVersion: String {
        guard let cstr = vv_capi_version() else { return "unknown" }
        return String(cString: cstr)
    }

    /// Load the ASR model + tokenizer. Idempotent — calling twice
    /// replaces the engine. Throws if either file is missing or if
    /// `vv_capi_load` returns non-zero.
    public func loadModel(modelPath: URL, tokenizerPath: URL) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelPath.path) else {
            throw VibeVoiceASRError.fileNotFound(modelPath)
        }
        guard fm.fileExists(atPath: tokenizerPath.path) else {
            throw VibeVoiceASRError.fileNotFound(tokenizerPath)
        }

        let rc = modelPath.path.withCString { modelCStr in
            tokenizerPath.path.withCString { tokCStr in
                vv_capi_load(
                    nil,             // tts_model_path — ASR-only client
                    modelCStr,       // asr_model_path
                    tokCStr,         // tokenizer_path
                    nil,             // voice_path — TTS only
                    0                // n_threads — 0 = auto
                )
            }
        }
        guard rc == 0 else {
            isLoaded = false
            throw VibeVoiceASRError.loadFailed(code: rc)
        }
        isLoaded = true
    }

    /// Transcribe a WAV file. Returns one `DiarizedSegment` per row of
    /// the JSON returned by `vv_capi_asr`.
    public func transcribe(wavPath: URL) async throws -> [DiarizedSegment] {
        guard isLoaded else { throw VibeVoiceASRError.modelNotLoaded }
        guard FileManager.default.fileExists(atPath: wavPath.path) else {
            throw VibeVoiceASRError.fileNotFound(wavPath)
        }

        var bufferSize = Self.initialBufferSize
        while bufferSize <= Self.maxBufferSize {
            var buffer = [CChar](repeating: 0, count: bufferSize)
            let written = wavPath.path.withCString { wavCStr in
                buffer.withUnsafeMutableBufferPointer { bufPtr -> Int32 in
                    vv_capi_asr(
                        wavCStr,
                        bufPtr.baseAddress,
                        bufPtr.count,
                        0  // max_new_tokens — 0 = library default
                    )
                }
            }

            if written > 0 {
                // Success — buffer is NUL-terminated. Trim to the
                // written-bytes prefix and decode JSON.
                let jsonString = buffer.prefix(Int(written)).withUnsafeBufferPointer { ptr in
                    String(cString: ptr.baseAddress!)
                }
                guard let data = jsonString.data(using: .utf8) else {
                    throw VibeVoiceASRError.malformedJSON("non-UTF8 output")
                }
                do {
                    return try JSONDecoder().decode([DiarizedSegment].self, from: data)
                } catch {
                    throw VibeVoiceASRError.malformedJSON(error.localizedDescription)
                }
            } else if written == 0 {
                return []  // No transcription produced; empty audio or silence.
            } else {
                // Negative: either buffer-too-small (negated required size)
                // or a real error code. The C ABI doesn't distinguish in the
                // value itself; we differentiate by checking whether the
                // negated value is plausibly a buffer size.
                let requiredOrError = -Int(written)
                if requiredOrError > bufferSize && requiredOrError < Self.maxBufferSize * 2 {
                    bufferSize = min(requiredOrError + 1024, Self.maxBufferSize)
                    continue  // Grow and retry.
                } else {
                    throw VibeVoiceASRError.transcribeFailed(code: written)
                }
            }
        }
        throw VibeVoiceASRError.outputBufferTooSmall(requiredBytes: bufferSize)
    }

    /// Free engine state. Optional — process exit also frees it.
    public func unload() {
        guard isLoaded else { return }
        vv_capi_unload()
        isLoaded = false
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build --target VibeVoiceCore`

Expected: `Build complete!`. If the link fails with "library not found", verify the `-L` paths in Package.swift point at a directory containing `libvibevoice.a`.

- [ ] **Step 4: Run the JSON decoding tests (no model required)**

Run: `swift test --filter DiarizedSegmentTests`

Expected: 3 tests PASS.

- [ ] **Step 5: Run the failure-path tests (no model required)**

Run: `swift test --filter VibeVoiceASRTests/testTranscribeWithoutLoadThrows`

Expected: PASS.

- [ ] **Step 6: Run the full integration test (requires model symlinks from Step 1)**

Run: `swift test --filter VibeVoiceASRTests/testTranscribesShortClip`

Expected: PASS after ~15 seconds (13s load + ~2s for 5s of audio at RTF 0.4).

If skipped: `XCTSkip` fired because the symlinks weren't created. Re-run Step 1.

If failed with non-zero load code: check whether the model file is fully downloaded (`ls -lh ~/Library/Application\ Support/MacParakeet/models/vibevoice/` — should show ~10 GB for the .gguf).

- [ ] **Step 7: Run the full macparakeet test suite to confirm no regressions**

Run: `swift test`

Expected: Same pass count as before (3197 baseline) + the new tests, with the integration test either passing or skipping based on model availability.

- [ ] **Step 8: Commit**

```bash
git add Sources/VibeVoiceCore/VibeVoiceASR.swift
git commit -m "$(cat <<'EOF'
feat(vibevoice): VibeVoiceASR actor wrapping vibevoice.cpp C ABI

## What Changed
Implements the Swift wrapper around the vibevoice.cpp C ABI for ASR:

- `VibeVoiceASR.loadModel(modelPath:tokenizerPath:)` — calls vv_capi_load,
  validates file existence Swift-side, surfaces non-zero return codes
  as `VibeVoiceASRError.loadFailed`.
- `VibeVoiceASR.transcribe(wavPath:)` — calls vv_capi_asr with a
  256 KB output buffer, grows to 16 MB on buffer-too-small responses,
  decodes the returned JSON via `JSONDecoder` into `[DiarizedSegment]`.
- `VibeVoiceASR.unload()` — frees engine state.
- `VibeVoiceASR.libraryVersion` — nonisolated read of vv_capi_version
  for logging.

## Tests
- DiarizedSegmentTests: 3 tests passing (JSON decode happy + multi-speaker + empty).
- VibeVoiceASRTests:
  - testTranscribesShortClip — full integration test, skips when model
    isn't installed at ~/Library/Application Support/MacParakeet/models/vibevoice/
  - testTranscribeWithoutLoadThrows — verifies modelNotLoaded fires.
  - testTranscribeWithMissingAudioThrows — verifies fileNotFound fires.

## Root Intent
Phase 2.1 of the VibeVoice-ASR integration. The C ABI is wrapped in a
clean Swift actor; Phase 2.2 will plug this into STTRuntime + STTScheduler
per ADR-016 and surface VibeVoice as a third STT engine option.

EOF
)"
```

---

## Self-Review

**Spec coverage:**
- ✅ Wraps vibevoice.cpp C ABI in a Swift actor (Task 8)
- ✅ Returns `[DiarizedSegment]` via JSON decode (Tasks 4, 8)
- ✅ Typed errors for the failure modes (Task 5)
- ✅ Unit test with committed audio fixture (Tasks 6, 7)
- ✅ Skips integration test when model is missing (Task 7)
- ✅ Does NOT plumb into STTRuntime/STTScheduler (deferred to Phase 2.2 as planned)
- ✅ Does NOT add UI changes (deferred to Phase 2.2 as planned)

**Type consistency check:**
- `DiarizedSegment` fields: `startSec, endSec, speakerId, text` — used consistently across Tasks 4, 7, 8
- `VibeVoiceASRError` cases: `loadFailed, transcribeFailed, outputBufferTooSmall, malformedJSON, modelNotLoaded, fileNotFound` — used consistently in Tasks 5, 7, 8
- `VibeVoiceASR` methods: `loadModel(modelPath:tokenizerPath:), transcribe(wavPath:), unload(), libraryVersion` — consistent across Tasks 7, 8

**Placeholder scan:**
- No "TODO" / "TBD" / "implement later" in tasks
- All code blocks contain complete code (not summaries)
- Test code is real, not "write similar tests"
- File paths are exact (`Sources/VibeVoiceCore/VibeVoiceASR.swift`, not "the wrapper file")

**Risk acknowledgment (not blockers, just things to watch for at execution time):**
- The `unsafeFlags` linker setting in Task 3 hard-codes the spike directory path. This is intentional for Phase 2.1 since the library isn't yet productized into the app bundle — Phase 2.5 will replace this with proper bundling. The path is documented in the task's comment for the engineer.
- The "buffer-too-small" heuristic in `transcribe` (Task 8 Step 2) interprets negative return codes by their magnitude. The C ABI docstring confirms this is the correct interpretation; if a future version changes the signaling we'd need to adjust.

---

## Out of Scope (Phase 2.2+)

The following are EXPLICITLY OUT OF SCOPE for this plan and belong in a future plan:
- Productizing the vibevoice.cpp build into a script the user can run (`scripts/dev/build_vibevoice.sh`)
- Bundling the libraries into the production .app bundle
- Adding `VibeVoiceEngine` conforming to MacParakeet's STT engine protocol
- Wiring into `STTRuntime` and `STTScheduler` per ADR-016
- Engine selection UI in Settings
- Model download flow (first-run UX for the ~10 GB GGUF)
- Diarization output mapping to MacParakeet's existing speaker model
- Subtitle pipeline integration (segment-level vs word-level handling)
- Custom vocabulary → hotwords plumbing
