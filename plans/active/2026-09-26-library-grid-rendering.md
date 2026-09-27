# Library Grid Rendering and Page Payload

> **Status:** PR OPEN on `perf/library-grid-rendering`.
> **Scope:** Library grid scroll/hover smoothness and filter/search latency.
> No visual, persistence, or CLI output changes.

## Problem (measured 2026-09-26 on a 464-row production library)

1. `TranscriptionThumbnailCard` called `NSImage(contentsOf:)` inside `body`.
   Every evaluation (scroll-in, hover enter/exit, any parent invalidation)
   read and decoded the cached JPEG on the main thread at full size (mostly
   1280x720, up to 2560x1072) for a ~280pt card. Load + decode measured
   ~5 ms per card, so one new row of six cards costs ~30 ms of main-thread
   work — two dropped frames at 60 Hz.
2. `fetchLibraryPage` ran `SELECT *`. A 100-row page carried 36 MB of
   `wordTimestamps`, 14 MB of `transcriptSegments`, and 3.5 MB of
   `diarizationSegments` JSON that no card reads. Decoding just the word
   timestamps took ~0.7 s per filter change. Search scans every row through
   the same path.
3. Smaller: remote thumbnails were fetched twice (`AsyncImage` plus the
   `onAppear` cache download), YouTube-derived thumbnails were never cached
   to disk, and the card animated a shadow that `clipShape` fully hides.

## Changes

- `ThumbnailImageDecoder` (Core): ImageIO downsampling to a bounded pixel
  size, decoded eagerly off the main thread.
- `LibraryThumbnailStore` (app, `@MainActor`): `NSCache` of decoded images,
  in-flight de-duplication per recording, and one download path that also
  caches derived YouTube thumbnails. The card holds the decoded image in
  state; `body` does no decoding.
- `TranscriptionLibraryQuery.payload`: `.full` (default, CLI unchanged) or
  `.summary`, which selects the three timing JSON columns as `NULL`. The
  Library view models request `.summary`.
- Hand-offs that need timing data load the full row by ID first: opening a
  recording (Library and Meetings) and Library bulk export.
- Remove the invisible, clipped hover shadow from the thumbnail card.

## Invariants

- CLI `history`/`meetings` output is unchanged (default `.full`).
- Library search results and effective (corrected) transcript text are
  unchanged; corrected rows resolve against their full stored row.
- No summary row is persisted or handed to the transcript detail view or an
  exporter. Library write paths use column updates only (favorite, title,
  audio detach, delete); retry already refetches.
- Card appearance is unchanged.

## Verification

- Focused tests: decoder, repository summary payload (fields, search,
  corrected text), library view model full-row hand-offs.
- Full `swift test` once as the final gate; Swift 6 language-mode build.
- Manual: scroll and hover the Video grid, switch filters, open a recording,
  bulk-export a selection.
