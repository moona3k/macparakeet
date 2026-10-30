# YouTube Video Playback

## Purpose

Keep Show Video usable when a media source offers separate audio and video,
without changing transcription or the user's retained audio. Playback stays on
one AVPlayer timeline so seeking, speed, and transcript highlighting share a clock.

## Producers and consumers

- `VideoStreamService` resolves remote media and prepares temporary playback files.
- `VideoPlaybackResource` owns a playable URL and, for prepared files, their temporary directory.
- `MediaPlayerViewModel` retains that resource while its player uses it.
- `TranscriptionVideoPanel` displays extraction, download, and combination stages.

## Stable semantics

- Opening a transcript prepares its retained audio; video is requested by Show Video.
- Prefer one combined audio/video URL. Only remote combined URLs enter the shared
  two-hour URL cache. Never silently discard additional extraction output.
- When only separate streams are available, select HTTPS H.264 MP4 video up to
  1080p and AAC M4A audio. Exclude tracks whose known size exceeds 512 MiB,
  allowing smaller compatible formats to be selected. Download them separately and combine both tracks using
  bundled/runtime FFmpeg with stream copy. Unsupported formats fail explicitly;
  this path does not introduce codec transcoding.
- Request a 512 MiB download limit per track and reject missing, empty, or oversized
  downloaded tracks. The helper's download limit depends on available size metadata;
  it is not a guaranteed hard limit on peak disk use. Process timeouts also bound preparation.
- Keep all fallback artifacts in a unique directory under system temporary storage.
  Do not persist that path to the transcript database or alter retained source audio.
- Cancellation and errors remove artifacts owned by that preparation. Successful
  preparation transfers directory ownership to the returned resource. The caller
  detaches the player item before releasing the last resource reference.
- A cancelled load cannot replace the current player, update its preparation stage,
  or stop a newer load's timer. Failed preparation leaves the existing audio player available.
- Hide Video cancels unfinished preparation without stopping retained audio. Hiding
  already-prepared video keeps its player available for audio playback.
- Preserve the latest playback position, play/pause state, and rate when switching
  from retained audio to video; sample them after preparation completes.
- Keep subprocess output out of pipes that could fill while waiting for exit; bound
  captured error text and sanitize it before exposing it through errors/logging.

## Non-stable fields

Generated directory/file names, temporary paths, UI wording, process log details,
and YouTube's format IDs are implementation details. The app does not depend on
specific IDs such as 136 or 140. Live format availability can change independently
of app versions.

## Compatibility

This is an internal Core-to-view-model contract. `playbackResource(for:onStageChange:)`
replaces `streamURL(for:)` because a returned local URL needs an explicit lifetime.
All in-repository callers migrate together. There is no CLI, database, or export
format change and no migration of existing user media.

## Tests and changes

`VideoStreamServiceTests` covers combined and separate extraction, malformed output,
failure/cancellation cleanup, ownership, and a real FFmpeg mux of synthetic media.
`MediaPlayerViewModelTests` covers resource release, stale completion, preparation
stages, retained-audio preservation, and existing playback controls.

Update this document and those focused tests when changing selection, ownership,
or cancellation. Native playback and real YouTube availability remain separate
qualification from deterministic CI fixtures.
