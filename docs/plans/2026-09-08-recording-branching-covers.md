# Branching recording covers — implementation plan

Status: approved for implementation and PR/merge on September 8, 2026.
Base: origin/main edfaa4889b8beac34b28712829d3850f88bd8fd3; land after Library UI polish.

## Goal
Replace generic missing-artwork placeholders with a stable, beautiful Branching Field cover using bounded native drawing that does not interfere with Library scrolling or capture.

## Settled design
User selected Branching Field above harmonic and orbital alternatives. Reference: seed72841659, density6, disruption0.44, negative space0.28; three approved curated palettes Tidal stone, Lichen dusk, Plum mineral. Automatically select family and restrained variant from domain-separated deterministic UUID seed streams. No product palette picker. Approximate uniform distribution, not quotas; adding/sorting/deleting recordings cannot recolor others. Color is decorative, never label/status identity.

Use the local study as visual reference: /Users/dmoon/code/macparakeet/docs/design/2026-09-08-recording-art/index.html (renderBranch, paletteForSeed and paletteMap). Do not copy p5 runtime/HTML into the app. Preserve organic branch silhouette, hierarchy, small warm center; make primary limbs legible at thumbnail size. No animation/timers/particles needing continuous updates. Keep title, duration and status in existing card chrome.

## Stable inputs and architecture
UUID only plus fixed version1 recipe, explicit reproducible PRNG and byte-order contract; not Swift hashValue, title, duration, text, timestamps, confidence, source path or audio data. No audio reads/FFT, network, inference, migration, sidecars or required post-processing job. Same item stays recognizable after rename/transcript edits/reprocess/restart/audio removal. V1 fixed globally; future selective v2 needs explicit version selection, do not promise preservation from cache alone.

Start with bounded static Canvas and pure small geometry/palette model, ideally computed once per identity rather than every draw. Measure actual native render cost. Only add raster caching if measurements show meaningful redraw cost. If needed separate namespace from ThumbnailCacheService (<UUID>.jpg there is real-image cache with no provenance/version). Do not broaden scope into new cache framework without root discussion.

Insertion point: TranscriptionThumbnailCard cached/remote image branch then placeholderView around163–205. Keep real artwork first. Preserve remote loading state; generated art for no artwork or failed load. No source schema/capture lifecycle changes. Existing completion refresh sufficient. SonicMandalaView has reusable curve ideas but text/confidence seed is wrong; leave it unchanged.

## Verification
Test deterministic bounded geometry and stable UUID palette selection, distinct representative IDs, finiteness at accepted sizes and branch limits. Demonstrate fallback/real artwork priority with focused meaningful tests where testable. Add a native synthetic gallery or renderer harness artifact for actual AppKit/CoreGraphics/Canvas output and measurements (cold/warm per-image p50/p95 and dense-grid implications); HTML timings are not native evidence. No private app/database/audio inputs. Inspect output at normal thumbnail scale and relevant appearances.

Worker owns this isolated worktree: source, tests, narrow spec/04-ui-patterns.md behavior update and final plan evidence. Not alone: preserve other worktrees. UI worker also edits ThumbnailCard and spec in its own branch; root merges UI first and coordinates rebase/conflict resolution. Do not rebase automatically while root reviews.

## Implementation evidence (September 8, 2026)
The bounded v1 recipe now produces 5–6 roots, at most 96 limbs, and compact primary reach so that its smaller generations remain visible at card scale. A UUID pin fixes the selected palette, focal point and quantized limb-model digest; 512 synthetic UUIDs stayed within the documented ±2 normalized Canvas composition bound. Canvas clips that bounded overscan at the card edge without a separate clipping system.

Focused checks used `swift test --jobs 4 --filter BranchingRecordingCoverRecipeTests` (6 passed) and an opt-in native renderer run for `BranchingRecordingCoverViewTests` (2 passed). The latter constructs a fresh 320×180 pt SwiftUI `ImageRenderer` at 2×, obtains its `CGImage`, encodes it through `NSBitmapImageRep`, and saves an explicit 12-image synthetic PNG gallery only when an output directory is supplied. The gallery was inspected at 640×360 px; it showed distinct teal, lichen, and plum branching compositions with visible secondary and tertiary tips. No recordings, audio, database, or network data entered the harness.

On the final focused run, the complete Branching Field recipe plus renderer and PNG pipeline measured cold p50/p95 5.36/6.14 ms and warm p50/p95 5.38/6.49 ms across 24 UUIDs; twelve sequential covers took 62.45 ms. A flat waveform placeholder through the same pipeline measured p50/p95 1.41/3.19 ms and 18.89 ms for twelve. These are native synthetic export measurements, not a library scrolling profile; they do not establish a cache need or a no-lag claim. The implementation remains uncached and static pending combined UI QA.

The combined-suite attempt on the stacked UI-plus-art head did not pass: `/tmp/macparakeet-library-art-combined-full-20260908.log` exited 1 after 5,855 XCTest tests with 21 skips and 46 assertion failures across 22 `HotkeyManagerTests`; Swift Testing reported 29 passed. At the same code head, `/tmp/macparakeet-hotkey-focused-20260908-rerun.log` ran the isolated `HotkeyManagerTests` 87/87 passed. Independent UI review found the Hotkey source and tests byte-identical to `origin/main`; all 22 failing cases use the live physical-keyboard default without injection, and the host state was not captured. This is evidence of a likely pre-existing test-isolation flake, not a full-suite pass. No source or test change was made for it; hosted exact-head CI remains required.

## Execution and gates
Read project instructions and governing specs. Swift6 clean build, focused checks only. Limit build concurrency (--jobs4) due previous process exhaustion. Root owns single final full swift test across combined changes after rebase; do not run full suite/gate baseline yourself. Do not launch/restart user's running app or publish a release. Commit with rich intent, push branch, open PR main, but do not merge. Root owns independent review and exact-head CI/merge. Report PR URL/head, files, native measurements and method, test counts, deviations and limitations honestly. Do not claim no lag without actual profiling.
