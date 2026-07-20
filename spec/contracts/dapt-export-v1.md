# DAPT Export v1

> Status: ACTIVE - public structured-transcript boundary for MacParakeet.

## Purpose

MacParakeet exports W3C DAPT 1.0 original-language transcripts for downstream
translation, accessibility, editing, and archival workflows. This contract
protects both the DAPT document shape and MacParakeet's rule that missing or
stale alignment metadata is omitted rather than invented.

## Producers

- `DAPTDocumentRenderer`
- `ExportService.formatDAPT(transcription:)`
- `ExportService.exportToDAPT(transcription:url:)`
- App single and bulk transcript export
- Transcription and meeting auto-save
- `macparakeet-cli export --format dapt`
- `macparakeet-cli transcribe --format dapt`

## Consumers

- DAPT-aware localization and accessibility tools.
- TTML/XML processors and validators.
- Local scripts and coding-agent workflows.
- Users opening or moving the exported document as structured data.

## Stable Document Semantics

- Serialization is XML 1.0 encoded as UTF-8, without a byte-order mark, DTD,
  entity declarations, or custom entity references.
- The root uses the TTML namespace and declares
  `ttp:contentProfiles="http://www.w3.org/ns/ttml/profile/dapt1.0/content"`.
- `daptm:scriptType` is `originalTranscript` and
  `daptm:scriptRepresents` is `audio.dialogue`.
- Root `xml:lang` is always non-empty. A supported stored BCP 47 language is
  canonicalized and also written as `daptm:langSrc`; missing or unusable
  language becomes `xml:lang="und"` with no `daptm:langSrc`.
- Each emitted script-event `div` has a unique generated `xml:id` and
  `daptm:represents="audio.dialogue"`.
- Aligned, unedited word timestamps are grouped through
  `TranscriptCueBuilder`. Their script events contain clock-time `begin` and
  `end` attributes.
- A transcript without aligned words, including manually edited transcript
  text, uses one untimed script event. File duration is not substituted for
  missing word alignment.
- Referenced speaker IDs become generated `ttm:agent type="character"`
  declarations with current speaker labels as aliases. When the optional label
  map is missing or incomplete, the stored anonymous ID itself is the alias;
  that preserves a known diarization cluster without claiming person identity.
  Unattributed events do not receive an agent reference. No persistent
  identity, actor/talent role, confidence, or voiceprint claim is implied.
- If there are no aligned speaker-attributed words, no character agents are
  emitted even when a legacy speaker roster or speaker count exists.
- User text, title, and labels are XML-escaped; code points forbidden by XML
  1.0 are removed.
- The product filename convention is `.dapt.xml`. DAPT itself does not assign
  a dedicated filename extension.

## Stable Availability

- The app exposes DAPT for single export, bulk export, transcription auto-save,
  and meeting auto-save.
- The generic CLI exposes DAPT through both saved-transcript export and
  one-step transcription, with stdout and file output.
- The meeting-artifact-specific `meetings export` command remains a separate
  Markdown/JSON boundary. A saved meeting transcription can still be exported
  as DAPT through the generic `export` command.

## Non-Stable Details

- Whitespace and indentation of the XML document.
- Generated event and character identifier spellings, provided references stay
  valid and deterministic within a document.
- Cue boundaries produced by a future deliberate `TranscriptCueBuilder`
  revision.
- Additional standards-valid metadata or namespaces added in a compatible
  revision.
- Human-facing format labels and icons.

## Versioning And Compatibility

Additive metadata that remains valid under the DAPT 1.0 content profile is
compatible with v1. Changing the DAPT profile URI, script type, missing-data
policy, timing semantics, speaker semantics, or filename convention requires a
contract revision and migration/compatibility analysis. Import, translated
scripts, per-event language detection, non-dialogue description, embedded
media, and proprietary extensions are outside v1.

## Tests That Enforce This

- `DAPTExportTests`
- `TranscriptResultActionsTests.testBulkExportWritesDAPTWithCompoundExtension`
- `AutoSaveServiceTests.testSaveIfEnabledWritesDAPTFile`
- `ExportCommandTests` DAPT format, filename, and stdout tests
- `TranscribeCommandTests` DAPT parsing, renderer-parity, and file tests
- `SpecCommandTests.testTranscribeSpecDocumentsCurrentTranscribeSurface`

Representative timed-speaker, timed-no-speaker, and untimed files are also
checked during release/review against the current W3C DAPT XSD validator and
the BBC TTML Validator's DAPT rules.

## When This Changes

Update this contract, focused tests, `spec/02-features.md`,
`spec/03-architecture.md`, `integrations/README.md`, `docs/cli-testing.md`, and
`Sources/CLI/CHANGELOG.md` in the same PR. Re-run both external DAPT validators
when serialized output changes.
