# File Transcription Audio Tracks

> Status: ACTIVE - local-file audio-stream selection boundary.

## Purpose

Prevent multi-audio media containers from silently transcribing FFmpeg's
default stream when the user intended another language/commentary track, while
preserving the zero-friction path for ordinary single-track files.

## Producers

- `FFmpegAudioTrackProbe`
- `TranscriptionViewModel` local-file preflight and selection flow
- `TranscribeCommand --audio-track`
- `TranscriptionService` / `AudioFileConverter`
- Database migration `v0.29-transcription-audio-track`

## Consumers

- Transcribe-tab file, folder, and drag/drop ingestion
- Sequential local-file batches
- `macparakeet-cli transcribe`
- File retranscription through the app or CLI

## Stable Semantics

- User-facing track numbers are one-based. Core and persisted ordinals are
  zero-based among audio streams only and map to FFmpeg `0:a:N`.
- Container-wide stream indices are informational and never substitute for the
  audio-only ordinal.
- No audio streams is an input error. Exactly one stream continues without a
  picker or explicit map. Two or more streams require an app choice before a
  history row or STT work begins.
- Track labels always have a numbered fallback. Language/default metadata is
  additive and best-effort.
- One app batch choice is reused for each multi-track file; single-track files
  retain automatic selection and do not receive an explicit map. A missing
  ordinal on a later multi-track file fails that file; it must never fall back
  silently to another stream, and the remaining sequential batch continues.
- `transcriptions.audioTrackOrdinal` is nullable. `NULL` means automatic/legacy
  selection; a value records an explicit choice and is reused on
  retranscription.
- CLI `--audio-track N` is local-file/folder only, applies explicitly to every
  expanded file, validates the requested ordinal before creating a row or
  starting STT, and is rejected for media URL and podcast lanes.

## Non-stable Details

- Exact sheet copy, symbols, spacing, and metadata display wording.
- FFmpeg's container-wide `streamIndex` values.
- Human-readable conversion error wording, provided failure stays visible and
  no fallback occurs.

## Versioning And Compatibility

The database and JSON field are additive and nullable. Old rows decode as
automatic selection. Existing service/converter calls retain automatic
behavior through additive overloads and default implementations. Changing
numbering, fallback, persistence, or source-lane semantics requires an updated
contract, migration/compatibility analysis, changelog entry, and focused tests.

## Tests That Enforce This

- `FFmpegAudioTrackProbeTests`
- `AudioFileConverterTests.testFFmpegArgumentsMapExplicitAudioTrackOrdinal`
- `TranscriptionViewModelBatchTests` audio-track scenarios
- `TranscriptionServiceTests.testTranscribeFileMapsAndPersistsExplicitAudioTrackOrdinal`
- `TranscriptionServiceTests.testRetranscribeExistingFileUpdatesOriginalRowWithoutDuplicate`
- `DatabaseManagerTests.testAudioTrackOrdinalColumnExistsOnTranscriptions`
- `TranscribeCommandTests` audio-track option scenarios

## When This Changes

Update this contract, `spec/01-data-model.md`, `spec/02-features.md`,
`spec/04-ui-patterns.md`, `spec/05-audio-pipeline.md`, the CLI changelog and
integration docs, the schema migration when persistence changes, and focused
tests in the same PR.
