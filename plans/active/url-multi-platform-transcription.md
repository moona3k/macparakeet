# URL Transcription — Any Platform (multi-platform) + Recognition UI

> Status: **ACTIVE** · Branch `feat/url-multi-platform` · Follow-up to PR #457 (X support)

## Goal

Two parts:

1. **Accept any media URL.** Today the GUI's Transcribe button only lights up for
   YouTube / X / Apple Podcasts, even though the bundled `yt-dlp` download path
   already handles any media URL (Vimeo, Facebook, TikTok, Instagram, …). Stop
   gating: paste anything plausible, the button enables, yt-dlp tries it, failures
   surface in the existing error banner (same contract the CLI already honors).
   **No allowlist** (owner direction 2026-06-08, overriding the earlier PR #457
   note). The CLI is already permissive — unchanged.

2. **Enterprise-grade URL card UX.** Replace the muddy static SF-Symbol cluster
   with clean, recolorable vector brand glyphs and a live **orbiting constellation**
   hero: glyphs slowly orbit a core; when a recognized URL is pasted, the matched
   platform's glyph flies to focus and blooms to its brand color. Rename the entry
   points ("Transcribe Video…" → "Transcribe YouTube & more"). Update placeholder /
   caption copy.

## Non-goals / invariants

- **Do not change the download/transcription pipeline** — `YouTubeDownloader` +
  `yt-dlp` already handle arbitrary URLs. No new download code.
- **Keep podcast routing** (`PodcastURLValidator` → iTunes resolver) and **YouTube
  videoID dedup** (`YouTubeURLValidator.extractVideoID`) exactly as-is.
- **CLI public contract unchanged** — it already accepts any downloadable URL.
- No continuous animation when the tab/window is inactive or Reduce Motion is on
  (protects the app's low-idle-CPU ethos; cf. issue #107).
- No third-party logo assets bundled — glyphs are hand-drawn simplified `Shape`s
  (recolorable, trademark-safe, matches brand-assets line-mark philosophy).

## Architecture

### Core (pure, testable — no SwiftUI)
- **NEW `MediaPlatform`** (`Sources/MacParakeetCore/Utilities/MediaPlatform.swift`):
  - `enum MediaPlatform` cases: youtube, x, vimeo, facebook, tiktok, instagram,
    applePodcasts, soundcloud, twitch, … (+ recognition by host).
  - `static func recognize(_ urlString:) -> MediaPlatform?` — host-based, best-effort.
  - `var displayName: String`.
  - `static func isTranscribableURL(_:) -> Bool` — the ONE permissive gate that
    replaces the 4 duplicated OR-chains (podcast OR any http(s) media OR
    scheme-less known host). Consolidation, not new abstraction.
- **Keep** `YouTubeURLValidator` (dedup), `PodcastURLValidator` (routing),
  `XURLValidator` (strict /status/ — reused by recognize for X), and
  `DownloadableMediaURLValidator` (generic http(s)).

### App / UI
- **NEW `PlatformGlyph`** (`Views/Components/PlatformGlyph.swift`): one simplified,
  monochrome, tintable SwiftUI mark per platform + a generic link/globe fallback.
  Geometry per research brief (YouTube wide-pill+knockout triangle; X pointed
  crossing strokes; FB circle+knockout f; IG outlined squircle+lens+dot; Vimeo
  rounded "v"; TikTok eighth-note; Podcasts mic+rings).
- **NEW `MediaPlatformOrbitView`** (`Views/Transcription/MediaPlatformOrbitView.swift`):
  the orbiting hero. Inputs: matched `MediaPlatform?`. Slow rotation gated on
  visibility + window-active + `accessibilityReduceMotion`. Reuses the app's
  rosette motif for the core (visual continuity).
- **DesignSystem**: add brand tints (vimeoBlue, facebookBlue, tiktok, instagramPink;
  reuse youtubeRed/xMark/podcastPurple) + a `MediaPlatform → (tint, glyph)` mapping
  in the app layer.

### Wire-up (edits)
- `TranscribeView.swift` — swap icon cluster → orbit; permissive gate; copy.
- `YouTubeInputPanelView.swift` — compact reactive matched-glyph header; permissive
  gate; copy.
- `YouTubeInputPanelController.swift` — clipboard auto-paste uses permissive gate.
- `TranscriptionViewModel.swift` — `isValidURL` → `MediaPlatform.isTranscribableURL`;
  `transcribeURL()` placeholder name uses recognized `displayName` (routing intact).
- `TranscriptionSourceDisplay.swift` — derive richer library badges from
  `MediaPlatform.recognize` (Vimeo/TikTok/… instead of generic "Video").
- `MenuBarCoordinator.swift` (×2) — "Transcribe Video…" → "Transcribe YouTube & more…".

## Tests
- `MediaPlatformTests` — recognize() host mapping for all platforms + nil fallback;
  isTranscribableURL permissive accepts (vimeo/tiktok/ig/fb/yt/x/podcast/scheme-less)
  and rejects ("hello", empty, whitespace, non-URL).
- Update `TranscriptionViewModelTests` any case asserting non-YT/X/podcast URLs are
  invalid (now valid).
- Keep existing validator tests green.

## Verification
- `swift test` green.
- Build + run app; screenshot the orbit idle + paste-react states; iterate.
- Spot-check a Vimeo/TikTok download via CLI if network allows (not gating-critical).

## Docs
- spec/02-features.md F11, CLAUDE.md (mode #2 copy), traceability, README if user-visible.
