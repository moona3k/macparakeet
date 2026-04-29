# Engine Attribution Polish

> Status: **IMPLEMENTED** — shipped in PR #171 (merged 2026-04-28).
> Commits: `caa2d6cd`, `2e702514`, `fa168f5c`, `82411da8`, `1ee9e88c`, `52cdfa84`.

## Problem

After PR #167 (Whisper) shipped, MacParakeet has two STT engines but no surfaces tell users *which engine produced what*. Three concrete gaps:

1. **Live progress card** (`TranscriptionViewModel.subline`): hardcoded `"Runs entirely on-device using the Neural Engine"` — Parakeet-flavored copy that's shown for Whisper too.
2. **Settings → Whisper status detail**: never names the variant (`large-v3-v20240930_turbo_632MB`). Users see no friendly model name anywhere.
3. **Persisted records** (`Transcription`, `Dictation`): no engine/variant column. Past transcripts are forever ambiguous about what produced them.

PR #167's body explicitly captures engine + language in meeting *metadata/lock* files at recording start — but that information never lands on the final `Transcription` row, so the closing half of the loop is missing.

Whisper merged 2026-04-28 (~36 hours ago). Backfill is trivial *now* (essentially zero historical Whisper rows in the wild). Cost grows daily.

## Goal

One cohesive engine-attribution polish: live UI honest about which engine is running, persisted records carry engine + variant, surfaces that should display attribution do.

## Out of scope

- Cold-start `.loadingModel` overlay state for Whisper first-dictation-after-switch (PR #167's own deferred follow-up — separate UX thread).
- Per-meeting language picker (PR #167 deferred).
- Engine attribution on dictation history list rows / library grid rows (low value-per-row; can add later if asked).
- Telemetry events for engine usage (separate concern; out of scope for this polish).

## Tier 1 — Live UI (zero schema risk)

### Surfaces

| Surface | File | Change |
|---|---|---|
| Progress card subline | `Sources/MacParakeetViewModels/TranscriptionViewModel.swift` | Replace hardcoded subline with engine-aware copy read from `STTRuntime.currentSpeechEngineSelection()` |
| Settings Whisper status detail | `Sources/MacParakeetViewModels/SettingsViewModel.swift` | Prefix friendly variant name onto status detail strings |

### Friendly-name helper

Add to `SpeechEnginePreference` (single source for engine display naming):

```swift
public static func friendlyVariantName(_ rawVariant: String) -> String
// "large-v3-v20240930_turbo_632MB" → "Large v3 Turbo"
// Unknown variant → variant string verbatim (graceful fallback)
```

### Subline copy

| Engine | Subline |
|---|---|
| Parakeet | `"Parakeet TDT · Neural Engine"` |
| Whisper | `"Whisper {friendlyVariant} · Neural Engine"` |

(Use middle-dot `·` not bullet — tighter visual.)

## Tier 2 — Persisted Attribution (schema migration)

### Schema migration

`Sources/MacParakeetCore/Database/DatabaseManager.swift`, new migration `v0.8-engine-attribution`:

```sql
ALTER TABLE transcriptions ADD COLUMN engine TEXT;
ALTER TABLE transcriptions ADD COLUMN engineVariant TEXT;
ALTER TABLE dictations    ADD COLUMN engine TEXT;
ALTER TABLE dictations    ADD COLUMN engineVariant TEXT;
```

- **No backfill.** Pre-migration rows = NULL. Display layer omits the attribution line for NULL rather than mislabeling.
- Stored values are canonical (`"parakeet"` / `"whisper"`), not display strings — decouple persistence from copy.

### Model updates

- `Sources/MacParakeetCore/Models/Transcription.swift`: add `engine: String?`, `engineVariant: String?`. Update `init(from:)` with `decodeIfPresent`. Extend `Columns`.
- `Sources/MacParakeetCore/Models/Dictation.swift`: same.

### STTResult carries authoritative engine

`Sources/MacParakeetCore/STT/STTResult.swift`:
```swift
public struct STTResult: Sendable {
    public let text: String
    public let words: [TimestampedWord]
    public let language: String?
    public let engine: SpeechEnginePreference   // NEW
    public let engineVariant: String?           // NEW (whisper variant; nil for parakeet)
}
```

The engine that ran is the authoritative source — not `STTRuntime.currentSpeechEngineSelection()` at save time, which can race a switch. `WhisperEngine` and `ParakeetEngine` populate at result construction.

### Save sites

Populate engine fields from `STTResult`:

| File | Lines | Change |
|---|---|---|
| `Sources/MacParakeetCore/Services/DictationService.swift` | ~530 | `Dictation(...)` init gets `engine: result.engine.rawValue, engineVariant: result.engineVariant` |
| `Sources/MacParakeetCore/Services/TranscriptionService.swift` | 4 save sites (262, 421, 544, 1114) | Same — populate when building/updating `Transcription` |
| `Sources/MacParakeetCore/Services/MeetingRecordingRecoveryService.swift` | 336 | Recovered meetings inherit engine from lock metadata if present |

### Display surfaces

| Surface | File | Copy |
|---|---|---|
| Transcription detail metadata footer | `Sources/MacParakeet/Views/Transcription/...` (find concrete view) | `"Transcribed with Parakeet TDT"` / `"Transcribed with Whisper Large v3 Turbo"` — only when non-nil |
| CLI JSON output | `Sources/CLI/...` | Add `engine`, `engineVariant` fields to JSON shape |

## Validation

- `swift build` clean.
- `swift test` — all pre-existing tests pass.
- New unit tests:
  - `friendlyVariantName` for known + unknown variants.
  - Settings status string includes friendly name when Whisper is selected.
  - Migration: existing rows decode with nil engine.
  - Save path: `STTResult.engine` round-trips to persisted `Transcription.engine`.
  - CLI JSON: `engine` field present in output.
- Manual smoke: dev app, swap to Whisper, transcribe short file, confirm progress card shows `"Whisper Large v3 Turbo · Neural Engine"`, detail view shows attribution line, JSON CLI output contains engine fields.

## Risks

- **Migration backfill question** — chose `NULL` over `'parakeet'` default. Honest but means display omits line for legacy rows. Acceptable; alternative (default to `parakeet`) is wrong because mid-Whisper-rollout window has ambiguous rows.
- **STTResult breaking change** — adding required fields to a public struct breaks call sites in tests/mocks. Mitigated by giving default values in init (`engine: SpeechEnginePreference = .parakeet`, `engineVariant: String? = nil`) so test fixtures still compile.
- **Conflicts with `feat/whisper-language-picker`** (other agent's branch) — both touch `SettingsViewModel.swift` Whisper status. Worktree isolates implementation; merge order will need attention. Will note in PR description.

## PR shape

Single PR titled "Engine attribution polish" (or similar). Sections in PR body: Live UI, Persisted attribution, Migration, Display surfaces, Tests, Manual smoke.
