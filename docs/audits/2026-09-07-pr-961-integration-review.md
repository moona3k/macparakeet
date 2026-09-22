# PR #961 integration review

## Intent and scope

Keep @alfred-sa's immutable prompt versions, history comparisons, restore-as-new,
collections, labels and request provenance. Apply the approved C interface:
one searchable/filterable prompt list, separate creation and collection/trash
sheets, and the complete existing editor. The HTML transcript simulator is a
design explanation, not a new product feature.

The integration starts from upstream `2590e420` and contributor PR head
`2448d3a5c06a8ebe5b400f982759228e676b801b`. Contributor commits are retained.
The inherited optional-Discover build proposal (#955) is excluded; current
upstream Discover preferences and build/distribution behavior remain intact.

## Review repairs

- Preserve main's background-generation lifecycle while carrying prompt/version,
  model, settings and notes snapshots through retries.
- Preserve inference-settings validation at the new prompt editing service.
- Refresh eligible prompts after classification commits, not just optimistic
  label selection.
- Refresh derived artifacts from the current recording projection; skip deleted
  recordings rather than recreating their artifact folder from a stale receipt.
- Refresh Transform shortcut bindings after successful prompt-manager mutations.
- Save a prompt/version and its edited label policies in one transaction.
- Keep notes controls specific to result prompts; preserve hidden metadata on
  Transforms without presenting an inert checkbox.

## Control inventory

The manager retains kind/collection/search filtering, visibility, source auto-run,
notes, label availability, model/settings, Markdown preview, deletion/restoration,
collection CRUD/order, and version history/comparison/restoration. Advanced row
information is disclosed on expansion. Transform shortcut editing remains in
Transforms. Prompt duplication, prompt-order controls and a running-label editor
were not exposed by the original manager; they are not new promises of this layout.

## Verification

- Integrated SwiftPM app/CLI build passed.
- Broad focused selection: 944 tests, with one outdated artifact fixture failure.
  The fixture now saves the referenced prompt/version before its result.
- Corrected prompt/editor/CLI selection: 122 tests passed, zero failures.
- Native SwiftUI walkthrough used a temporary XCTest host with a normal AppKit
  event loop and fictional in-memory database. Verified the unified list,
  creation sheet, draft preservation across dismissal, successful creation,
  edit/save, history comparison, restore as a new version, collection management,
  keyboard-created collection and Escape dismissal. No provider calls or user
  database access occurred. The temporary harness is not part of the product.
- Native screenshots: [library](pr-961/prompt-library.png),
  [collections](pr-961/collections.png). VoiceOver and live paid-provider calls
  were not exercised.

The single local full suite and current-candidate hosted CI are the final merge
gates; their results are recorded on PR #961. Direct verification owns the local
suite so the existing contributor PR can be updated without a separate PR/push
pipeline or automatic full-suite retries. Independent reviews covered persistence,
runtime/classification, UI lifecycle, Transform bindings and CLI contracts.
