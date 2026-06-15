 # AI Formatting Architecture — Findings & Nuances

> Status: **ACTIVE** (reference). Captured 2026-06-14 during a deep review of how
> AI text cleanup ("AI Formatter") works across **dictation**, **file/URL
> transcription**, and **meetings**. Read this before touching the AI Formatter,
> the transcript display modes, meeting transcript finalization, or the
> raw/clean data model — several behaviors here are non-obvious from grep.

## TL;DR (the surprising bits)

1. **One shared LLM prompt** runs for *both* dictation and all transcription.
   Its default is literally a *"transcription cleanup assistant"* template, and
   it's used on the dictation path too.
2. **The AI Formatter is a second cleanup**, not "formatting." Stacked on top of
   the always-on deterministic cleanup. Its default job *is* cleanup.
3. **For meetings, AI cleanup and speaker attribution are mutually exclusive on
   screen.** The default `.text` view shows flat cleaned text with no speakers;
   the `.timed` view shows speaker turns built from *raw* words (no cleanup).
   You cannot see cleaned-AND-attributed at once.
4. **App-aware profiles are dictation-only** (they key off the frontmost app),
   and are **gated off** for v0.6.23 (`aiFormatterProfilesEnabled = false`).
5. The raw transcript is **always preserved** in `rawTranscript`, so applying the
   AI pass is non-destructive at the data layer — but transcript revert is
   one-way, unlike dictation's reversible "Undo AI edit."

---

## 1. The two-layer model

Every transcript/dictation passes through up to two cleanup layers:

| Layer | LLM? | When | Controlled by |
|-------|------|------|---------------|
| **Deterministic cleanup** (ADR-004 pipeline) | No | Always | — |
| **AI Formatter** (LLM rewrite) | Yes | After deterministic cleanup, *if a provider is configured* + per-surface toggle + under size cap | `aiFormatterEnabled` (= provider exists) AND the per-surface toggle |

The AI Formatter is **opt-in by provider**: `aiFormatterEnabled = (providerID != nil)`
(`LLMSettingsViewModel.persistAIFormatterPreferences`). No provider → no LLM pass,
ever; you get deterministic cleanup only. This bounds the blast radius of all AI
behavior here to users who've wired up an LLM.

## 2. One shared prompt (the root of the "AI Formatter" naming confusion)

There is a **single** customizable prompt — `runtimePreferences.aiFormatterPrompt`
(the "Customize fallback prompt" box) — used by both surfaces. Default =
`AIFormatter.defaultPromptTemplate`, a *"You are a transcription cleanup
assistant… Convert the following raw transcript…"* template
(`AIFormatter.swift:34`).

Wiring (`AppEnvironment.swift`):
- **Transcription** (`:331`) → `aiFormatterPromptClosure` → the global prompt **directly**.
- **Dictation** (`:275`) → an `AIFormatterPromptResolving`:
  - profiles **on** → `AIFormatterProfilePromptResolver` (per-app prompt, falling back to global)
  - profiles **off** (current) → `AIFormatterGlobalPromptResolver` → the **same** global prompt.

Consequence: with profiles gated off, **dictation and transcription run the
identical prompt today.** `TranscriptionService` has *zero* concept of profiles.

Naming nuance discussed: "Formatter" undersells it (the prompt is a general,
user-editable LLM pass that *defaults* to cleanup), and "cleanup" double-counts
(the deterministic layer is also "cleanup"). The default prompt is
transcript-flavored ("raw transcript", "the speaker"), so it's mildly
mis-framed on the dictation path. **Decision 2026-06-14: keep one shared prompt**
(see §8) — the prompt is general enough, dictation formatting is off by default,
and real dictation-context divergence (code/commands vs prose) is the job of
app-aware profiles, not a second static prompt.

## 3. Gating & defaults

| Setting | Default | Notes |
|---------|---------|-------|
| `aiFormatterEnabled` | true iff provider configured | master availability |
| `aiFormatterEnabledForTranscriptions` | **on** | file/URL/meeting |
| `aiFormatterEnabledForDictation` | **off** | opt-in; LLM adds latency to the hot path (issue #408) |
| `AIFormatter.maxTranscriptionInputChars` | **20_000** | transcripts over the cap **skip the LLM** and fall back to deterministic cleanup; dictation is *not* capped |

The transcripts toggle + cap were added 2026-06-12 by community contributor
Andrea Grandi (PR fixing **issue #493**): before that, transcripts were
force-on with no opt-out, and the inline formatter stalled hour-long meetings
for the full 300s provider timeout before failing to cleanup. Defaults are
delivered via `loadStored…(… ?? true/false)` and seeded only when absent — so
configuring a provider never silently flips transcripts off.

## 4. App-aware profiles (REQ-LLM-004) — dictation-only, gated off

Profiles route the dictation prompt by the **frontmost app** (exact bundle id,
or category like messaging/code). They are inherently dictation-only: a
file/YouTube/meeting transcription has **no target app** to key off. Confirmed:
only the dictation path consumes the resolver; transcription never does.

**Gated off for v0.6.23** on 2026-06-14: `AppFeatures.aiFormatterProfilesEnabled
= false`. Flipping it is a no-data operation (profile table/repo migrate
regardless). Flip back to `true` to ship in a later tag.

## 5. Data model — raw vs clean

Both models store **both** a raw and a cleaned string:

| | `rawTranscript` | `cleanTranscript` | Revert affordance |
|---|---|---|---|
| **Dictation** (`Dictation.swift`) | literal STT | AI/clean (nil if == raw) | **Reversible** per-row toggle `displayRawTranscript` → "Undo AI edit" ⇄ "Re-apply AI edit" |
| **Transcription** (`Transcription.swift`) | literal STT | deterministic refinement → +AI → +manual edits | **One-way** `revertCurrentTranscriptToOriginal()` (nulls clean → shows raw, also discards edits). No reversible toggle. |

- `cleanTranscript` is **almost always set** for completed transcripts (it holds
  the deterministic refinement even when the LLM doesn't run).
- Raw is **always preserved** → the AI pass is non-destructive; worst case the
  user reverts to raw.
- Dead code spotted: `TranscriptResultView.rawTranscriptText` (`:665`) is defined
  but never used.

## 6. Transcript display modes (the part that surprises everyone)

`TranscriptResultView` has two modes (`TranscriptDisplayMode`): `.text` (flat) and
`.timed` (word-timestamped + speaker turns), switched via the "Transcript view"
Picker (`:1136`).

- **Default** (`syncTranscriptDisplayMode`, `:2576`):
  `(hasCleanTranscriptText || !hasTimestamps) ? .text : .timed`.
  Since `cleanTranscript` is ~always present, **the default is `.text`** (flat
  cleaned). `.timed` is the opt-in.
- **`.text`** renders `transcriptText = cleanTranscript ?? rawTranscript` — the
  **cleaned, flat** text. **No speaker attribution.**
- **`.timed`** renders from `wordTimestamps` (the **raw** STT words) grouped into
  segments/turns + a speaker summary panel. **No AI cleanup.** Requires word
  timestamps to exist.

So even outside meetings, the AI cleanup is what you see by default (`.text`),
while `.timed` shows raw words. Copy/edit/prompt/chat all use
`transcriptText` (the cleaned flat string).

## 7. Meetings — the real "special treatment" gap

Meetings go through the **same** `TranscriptionService.completeTranscription`
(`:1057`), so the flat AI Formatter **does** run on them (subject to toggle +
provider + 20k cap). Separately, `MeetingTranscriptFinalizer` populates
`rawTranscript`, `wordTimestamps`, `speakers`, and `diarizationSegments`.

A single meeting therefore exists in **four** textual representations, each used
by a different consumer:

| Representation | Built from | Speakers? | AI-cleaned? | Used by |
|---|---|---|---|---|
| `.text` view (default) | `cleanTranscript` | ❌ | ✅ | main on-screen view |
| `.timed` view (opt-in) | raw `wordTimestamps` + diarization | ✅ | ❌ | speaker turns on screen |
| Copy / export | `cleanTranscript ?? rawTranscript` | ❌ | ✅ | `MeetingArtifactStore:329`, clipboard |
| LLM context | `TranscriptAIContextFormatter.richTranscript` → `{ts} {label}: {text}` from raw cues | ✅ | ❌ | summaries, Ask, prompts, chat |

**The collision:** on screen, **cleaned XOR speaker-attributed** — never both.
Default `.text` gives a meeting user flat cleaned prose with *no speakers*; they
must switch to `.timed` to get speakers, which shows *raw* words. This is the
substantive gap behind "should meetings get special treatment" — it's
structural (the LLM rewrite breaks word-timestamp alignment that attribution
depends on), not a prompt-wording issue.

**Engine nuance:** Nemotron surfaces **no word-level timestamps**, so a Nemotron
meeting has no `wordTimestamps` → no `.timed` mode and effectively **no speaker
turns at all**. Parakeet (default) and Whisper do produce word timestamps.

**Already speaker-aware:** the *LLM-context* path
(`TranscriptAIContextFormatter` rich mode) builds speaker+timestamp-labeled
lines from the structured data, so summaries/Ask/prompts already get
speaker-attributed input. It's the *cleanup formatter* and the *default display
+ export* that are not speaker-aware.

## 8. Decisions made 2026-06-14

1. **Gate app-aware profiles off for v0.6.23** — `aiFormatterProfilesEnabled =
   false` (uncommitted on a detached HEAD at time of writing; needs a PR to land
   on `main` before tagging).
2. **Keep ONE shared cleanup prompt** — explicitly *rejected* splitting into
   separate transcript/dictation prompts and rejected de-flavoring the wording.
   Rationale: the prompt is general; dictation formatting is opt-in/off-by-default;
   non-prose dictation context is profiles' job.
3. **Planned (fast-follow, not v0.6.23): a non-destructive Raw ⇄ Cleaned viewer**
   for transcripts — buttons/menu to flip between `rawTranscript` and
   `cleanTranscript`, replacing the one-way revert. Scope transcripts first,
   align dictation onto the same model later. Framed as a trust feature (verify
   the LLM didn't drop content).

## 9. Open questions / follow-ups

- **Meetings:** how to deliver cleaned *and* speaker-attributed text. Options
  raised: per-speaker-turn LLM cleanup (preserves attribution; more calls);
  default meetings to `.timed`; or a dedicated cleaned-with-speakers view. Lean
  on the (already speaker-aware) summary as the "smart" output? Needs a design
  pass — **not** v0.6.23.
- Should meetings **default to `.timed`** rather than `.text` (speakers are the
  point of a meeting)?
- Dictation prompt is transcript-flavored — accepted for now; revisit if/when
  profiles ship.
- Remove dead `rawTranscriptText` accessor.
- Transcript revert is one-way vs dictation's reversible toggle — unify via the
  planned viewer.
- Nemotron meetings get no speaker turns (word-timestamp limitation) — document
  or warn?

## 10. File map (where each concern lives)

| Concern | Location |
|---|---|
| Default prompt + 20k cap | `Sources/MacParakeetCore/TextProcessing/AIFormatter.swift` |
| Formatter gate + meeting branch + `formatTranscriptIfNeeded` | `Sources/MacParakeetCore/Services/TranscriptionService.swift` (meeting branch ~`:1033`, formatter ~`:1548`, cap ~`:1648`) |
| Prompt/resolver wiring (transcription vs dictation) | `Sources/MacParakeet/App/AppEnvironment.swift:227–331` |
| Toggles + defaults + provider gate | `Sources/MacParakeetViewModels/LLMSettingsViewModel.swift` |
| Settings UI ("AI Formatter", toggles, Customize prompt) | `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift:390+` |
| Display modes + speaker turns + revert | `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift` (modes `:45/:99/:1040/:1136/:2576`) |
| Raw/clean models | `Sources/MacParakeetCore/Models/{Dictation,Transcription}.swift` |
| Meeting finalize → raw/words/speakers/diarization | `Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptFinalizer.swift` |
| Speaker-aware LLM context | `Sources/MacParakeetCore/TextProcessing/TranscriptAIContextFormatter.swift` |
| Feature flag | `Sources/MacParakeetCore/AppFeatures.swift` (`aiFormatterProfilesEnabled`) |

---

*Related: REQ-LLM-004 (app-aware profiles), REQ-LLM-005 (per-surface routing +
length cap), ADR-004 (deterministic pipeline), ADR-010 (diarization), ADR-013
(prompt library / summaries), ADR-020 (meeting notepad + memo summaries),
issues #408 / #493.*
