# Issue #850: DAPT export for MacParakeet

## Bottom line

MacParakeet should support DAPT 1.0 as an original-language transcript export.
The format is a strong fit for MacParakeet's existing timed-word, language, and
optional speaker-label data, and it still has an honest conforming shape when
speaker diarization or word timing is absent.

Speaker diarization quality is not a DAPT-specific blocker. DAPT character
metadata is optional, so MacParakeet should include it only when the stored
transcript has aligned speaker-attributed words. If diarization is disabled,
fails, or produces incomplete attribution, the export remains useful and valid
without character references. This is the same underlying accuracy boundary as
SRT, VTT, TXT, Markdown, PDF, DOCX, and JSON; DAPT makes the optional metadata
more explicit rather than making it more authoritative.

## Sources and current state

- Live request: [GitHub issue #850](https://github.com/moona3k/macparakeet/issues/850),
  opened 2026-07-20 by DAPT editor Nigel Megitt, asks for a DAPT
  `originalTranscript` output carrying speaker and language metadata.
- Baseline: `origin/main` at `1e5502c1d9951457e91725e2fbd1cc69a29b3b29`.
- Governing standard: [W3C DAPT Candidate Recommendation Draft, 26 June
  2026](https://www.w3.org/TR/dapt/).
- Primary examples: [w3c/dapt examples](https://github.com/w3c/dapt/tree/main/examples).
- Validation sources: [w3c/dapt XSD validator](https://github.com/w3c/dapt/tree/main/schema-validator),
  [W3C DAPT tests](https://github.com/w3c/dapt-tests), and
  [BBC TTML validator](https://github.com/bbc/ttml-validator).
- Existing MacParakeet export boundary:
  [`ExportService.swift`](../../Sources/MacParakeetCore/Services/ExportService.swift),
  [`TranscriptResultActions.swift`](../../Sources/MacParakeet/Views/Transcription/TranscriptResultActions.swift),
  [`AutoSaveService.swift`](../../Sources/MacParakeetCore/Services/AutoSaveService.swift),
  and [`ExportCommand.swift`](../../Sources/CLI/Commands/ExportCommand.swift).

No open MacParakeet PR or branch currently overlaps DAPT.

## What DAPT requires

DAPT is a TTML2-based exchange format for transcription and translation
workflows. The standard explicitly lists speech-to-text output as a use for an
original-language transcript ([DAPT section
2.1.3](https://www.w3.org/TR/dapt/#other-uses)). A minimal MacParakeet document
needs:

- a TTML `<tt>` root;
- the DAPT 1.0 content profile designator
  `http://www.w3.org/ns/ttml/profile/dapt1.0/content`;
- `daptm:scriptType="originalTranscript"`;
- `daptm:scriptRepresents="audio.dialogue"`;
- a non-empty BCP 47 `xml:lang` value;
- zero or more script-event `<div>` elements, each with an `xml:id` and a
  computed `daptm:represents` value;
- UTF-8, well-formed XML 1.0 without a BOM, DTD, or custom entity declarations.

The event `begin` and `end` attributes are **SHOULD**, not **MUST**
([DAPT section 4.3](https://www.w3.org/TR/dapt/#script-event)). Character
identifiers are optional. When character data exists, each character is a
`ttm:agent type="character"` with an alias name and events can reference it via
`ttm:agent` ([DAPT section 4.2](https://www.w3.org/TR/dapt/#character)).

Those rules give MacParakeet three honest output tiers:

1. aligned word timings plus speaker labels: timed events with character agents;
2. aligned word timings without speaker labels: timed events without agents;
3. no aligned timings (including manually edited transcripts): one untimed text
   event without agents.

The third tier must not manufacture a whole-file time range or speaker mapping.
An untimed event says exactly what MacParakeet knows; a synthetic timed event
would appear more precise than the source data.

## Mapping from MacParakeet

| MacParakeet data | DAPT representation | Rule |
|---|---|---|
| `language` | root `xml:lang` and, when known, `daptm:langSrc` | Normalize known language codes; use `xml:lang="und"` and omit `langSrc` when unavailable. |
| `wordTimestamps` | timed script events | Reuse `TranscriptCueBuilder` so DAPT, SRT, and VTT share deterministic timing/speaker boundaries. |
| `speakers` + word `speakerId` | `ttm:agent` character metadata and event references | Emit only for speakers actually referenced by aligned events; preserve renamed labels; never infer a speaker. |
| edited transcript text | one untimed script event | Manual editing invalidates word/text alignment, matching existing export behavior. |
| `cleanTranscript` / `rawTranscript` without words | one untimed script event | Prefer the same display text as existing text exports. |
| effective display title | `ttm:title` metadata | Human-readable metadata only; no local path or private source URL. |

MacParakeet currently persists a single transcript-level language, so this
first implementation should not pretend to provide per-event mixed-language
metadata. DAPT can carry that later without a format redesign if the data model
gains it.

## Diarization impact

Speaker detection is user-controllable and currently defaults on where
supported. It is post-ASR, non-fatal, and depends on aligned word timestamps.
The app stores stable anonymous speaker IDs on words and separate renameable
labels in `speakers`.

DAPT should carry those labels as character aliases, but it should not claim
persistent identity, cast/actor identity, or confidence that MacParakeet does
not store. Anonymous labels such as `Speaker 1`, `Me`, or `Others 1` are valid
character names for interchange. If attribution is absent or partial, events
without a character reference remain conforming.

This also handles plain-text engines such as Cohere correctly: a transcript
with no word timings becomes an untimed DAPT script rather than receiving fake
timings or a dominant-speaker guess.

## Recommended integration

- Add a pure DAPT renderer behind `ExportService.formatDAPT` and
  `exportToDAPT`.
- Use `.dapt.xml` as MacParakeet's filename convention. DAPT defines XML
  serialization but does not prescribe a dedicated filename extension; the
  double extension stays recognizable to people and generic XML tools.
- Add DAPT to the app's single export, bulk export, and transcription/meeting
  auto-save format pickers.
- Add `--format dapt` to `macparakeet-cli export` and to one-step
  `macparakeet-cli transcribe`, both using the shared renderer.
- Keep `macparakeet-cli meetings export` unchanged. That command exports the
  deterministic meeting artifact/Markdown contract, while the generic
  transcript exporter already handles meeting transcription rows.
- Add a dedicated boundary contract for DAPT v1 output, focused tests, CLI
  spec/changelog/docs updates, and validation against the current W3C schema
  plus the BBC DAPT validator.

## Risks and follow-ups

- DAPT is still a Candidate Recommendation Draft. The implementation should
  pin the DAPT 1.0 profile URI and keep the mapping isolated so later standard
  changes are contained.
- MacParakeet's diarization error rate is inherited by every speaker-aware
  export. DAPT should remain a faithful carrier, not an accuracy claim.
- Per-event language, non-dialogue sound classification, actor/talent identity,
  source-media identifiers, confidence extensions, and audio embedding are all
  deliberately out of scope. They require data or product decisions that issue
  #850 does not ask for.

## Implementation validation

Three files produced through the real `macparakeet-cli export --format dapt`
path were checked on 2026-07-20: timed with two speakers, timed without
diarization, and untimed without word timestamps. All three passed the current
`w3c/dapt` XSD validator and the BBC TTML Validator's DAPT rules with zero
DAPT-related warnings. The BBC tool reports its generic optional-copyright
warning because MacParakeet deliberately does not invent rights metadata.
