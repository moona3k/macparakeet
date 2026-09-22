# Branching recording covers — implementation plan

Status: **Superseded by Seed of Life v2** on 2026-09-16. See
[`docs/design/2026-09-15-cover-geometry/philosophy.md`](../design/2026-09-15-cover-geometry/philosophy.md).
v1 Recursive Canopy remains historical evidence below.
Base: origin/main 5760cec90394ec9ed3fe7fd15e1d557c0677994e.

## Goal
Replace generic missing-artwork placeholders with a stable, beautiful Branching Field cover using bounded native drawing that does not interfere with Library scrolling or capture.

## Settled design
User selected Branching Field above harmonic and orbital alternatives. Reference: seed72841659, density6, disruption0.44, negative space0.28; three approved curated palettes Tidal stone, Lichen dusk, Plum mineral. Automatically select family and restrained variant from domain-separated deterministic UUID seed streams. No product palette picker. Approximate uniform distribution, not quotas; adding/sorting/deleting recordings cannot recolor others. Color is decorative, never label/status identity.

Use the local study as visual reference: /Users/dmoon/code/macparakeet/docs/design/2026-09-08-recording-art/index.html (renderBranch, paletteForSeed and paletteMap). Do not copy p5 runtime/HTML into the app. Preserve organic branch silhouette, hierarchy, small warm center; make primary limbs legible at thumbnail size. No animation/timers/particles needing continuous updates. Keep title, duration and status in existing card chrome.

The user selected the Recursive Canopy refinement over a denser filigree
alternative and a Mandelbrot comparison study. Before the first release, v1
keeps the same UUID streams, focal-point range, and curated palettes while its
geometry changes from three to four descendant generations, at most 192 limbs,
and thinner primary limbs. The 192 hard cap is above the 186-limb theoretical
six-root, full-binary maximum, so the cap cannot remove a late root merely
because earlier roots branched densely. This is an explicit pre-release v1
revision; after release a visual recipe change needs a new version rather than
silently changing an existing identity.

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

The combined-suite attempt on the stacked UI-plus-art head did not pass: `/tmp/macparakeet-library-art-combined-full-20260908.log` exited 1 after 5,855 XCTest tests with 21 skips and 46 assertion failures across 22 `HotkeyManagerTests`; Swift Testing reported 29 passed. At the same code head, `/tmp/macparakeet-hotkey-focused-20260908-rerun.log` ran the isolated `HotkeyManagerTests` 87/87 passed. Independent UI review found the Hotkey source and tests byte-identical to `origin/main`; all 22 failing cases use the live physical-keyboard default without injection, and the host state was not captured. This remains historical evidence of a likely pre-existing test-isolation flake, not a local full-suite pass. No source or test change was made for it. Hosted exact-head CI subsequently passed in runs 34279191343 and 34279276556.

## Recursive Canopy refinement evidence (September 8, 2026)
The refined recipe preserves the static, UUID-only Canvas architecture with no
cache or background job. A static arithmetic audit over 512 synthetic UUIDs
produced 95–178 limbs per cover; every sample reached depth four and stayed
within 1.423 normalized coordinate magnitude, below the accepted clipped bound
of 2.0. `swift test --jobs 4 --filter 'BranchingRecordingCoverRecipeTests|BranchingRecordingCoverViewTests'`
passed all eight focused tests for both the exact prior `origin/main` recipe
and the refinement. Each renderer run constructed a fresh 320×180 pt SwiftUI
`ImageRenderer` at 2×, rasterized Canvas, encoded `NSBitmapImageRep` PNG, and
wrote twelve synthetic covers. The baseline outputs are in
`/tmp/macparakeet-recursive-canopy-baseline-gallery-20260908`; refined outputs
are in `/tmp/macparakeet-recursive-canopy-refinement-gallery-20260908`.

Using that same combined synthetic method, the prior recipe measured cold
p50/p95 5.66/6.09 ms, warm p50/p95 5.63/6.02 ms, and 67.82 ms for twelve
sequential covers. Recursive Canopy measured cold p50/p95 6.26/6.66 ms, warm
p50/p95 6.24/6.37 ms, and 74.36 ms for twelve: roughly 0.6 ms per exported
cover and 6.54 ms per twelve above baseline. The direct comparison confirms
that the new terminal forks remain visible at normal thumbnail scale. These
renderer-plus-PNG timings are not a library scrolling profile and do not imply
no lag; the bounded increase did not justify a cache or a background job.

## Execution and gates
Read project instructions and governing specs. Use focused checks and limit build
concurrency to `--jobs 4` due prior process exhaustion. The user authorized the
three reviewed fixes to land directly on `main`; root owns the combined review
and one final rebuild/restart QA after they are integrated. This worker must not
launch or restart the user's running app, publish a release, or claim no lag
without a real scrolling profile. Report native measurement method, test count,
deviations, and limitations honestly.
