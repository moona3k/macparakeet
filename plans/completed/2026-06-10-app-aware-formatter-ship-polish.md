# App-Aware AI Formatter — Ship Polish

> Status: **IMPLEMENTED** (2026-06-10)
> Date: 2026-06-10
> Requirement: legacy REQ-LLM-004 (`docs/historical/requirements-legacy.yaml`);
> current authoritative behavior is in `spec/11-llm-integration.md` and
> `spec/02-features.md`
> Prior art: PR #419 (profiles), PR #428 (smart defaults), `6cd4a7034` (flag pulled
> "while the profile UX is refined"), issues #117 / #412.

## Goal

Make app-aware AI Formatter profiles ready to ship and flip
`AppFeatures.aiFormatterProfilesEnabled` back on. A four-agent pre-ship review
(2026-06-10) found the runtime, data layer, and privacy posture release-grade,
and converged on one product gap plus a short list of P1/P2 fixes. This plan
fixes all of them.

## The product decision

Smart defaults stay **on by default** (the #428 intent: the common path is
automatic), but they become **visible, readable, and toggleable**:

- A master "Smart defaults" switch (off = the user's fallback prompt is used
  everywhere no custom profile matches — byte-for-byte legacy behavior).
- Per-category switches on each of the seven built-in defaults.
- Every built-in prompt is readable in Settings before it ever runs.
- Persistence is `UserDefaults` (no schema change, no migration), exposed as a
  pure `AIFormatterSmartDefaultsPolicy` value resolved per dictation.

This reconciles the R1/R7 contradiction from the 2026-06-03 brainstorm: users
who tuned a global prompt get a one-click "use my prompt everywhere" escape
hatch, and nothing is hidden.

## In scope

1. **Core**
   - `AIFormatterSmartDefaultsPolicy` (master + per-category disable set),
     `current(defaults:)` / `save(to:)`, keys on
     `UserDefaultsAppRuntimePreferences`.
   - `AIFormatterProfileMatcher.resolve` takes the policy; smart-default tier
     respects it. Shared `sortedByPrecedence` ordering used by both matching
     and the Settings list (fixes display-order/precedence divergence).
   - `AIFormatterProfilePromptResolver` gains the policy closure; AppEnvironment
     wires `onFetchError` to an OSLog logger (was silently nil).
   - Browser smart default: drop the "concise" pressure (it governs long-form
     Gmail/Docs writing).
   - `TelemetryAppCategory.formatterDisplayName` in Core; repository duplicate
     errors say "Email", not "email".
2. **ViewModel** (P1s from review)
   - Edit path: derive `appCategory` from the bundle ID when rehydrating a
     saved app profile (was hardcoded `.messaging`).
   - Manual bundle-ID entry routes through the same derivation as the app
     picker (category, auto-name, auto-prompt follow).
   - Smart-defaults toggle state + persistence; preview respects the policy and
     includes the open draft even before it is saveable.
   - Profile badge text moved to VM (`Smart default` / `Fallback prompt` /
     `Custom prompt`), compared against the *user's* fallback prompt.
   - Dead `"New category profile"` token removed; category display names
     unified on the Core helper.
3. **View**
   - Smart defaults block: master switch in the header, category rows with
     per-row switches, click-to-read prompt preview, dimmed when master is off.
   - Custom profiles always live in one stable `DisclosureGroup` (no layout
     restructure when a draft opens); auto-expands when profiles exist.
   - Save errors render inside the editor next to Save; section-level errors
     only when no editor is open.
   - One precedence explanation, phrased as behavior ("first match wins").
   - Unified vocabulary: fallback prompt editor badge "Built-in default" /
     "Customized"; profile badges per VM helper.
   - App picker: icon cache (was uncached main-thread fetch per render),
     `~/Applications/JetBrains Toolbox` scan dir, running-apps merge,
     localized display names via `FileManager.displayName(atPath:)`.
4. **History**: tiny provenance chip on dictation rows that were formatted by
   an app/category profile or smart default (answers "why did this come out
   casual?" — R9 metadata was stored but never surfaced).
5. **Search**: `ai.formatter` index entry un-gated (the formatter card is
   always visible; only profile keywords are flag-conditional). Anchor moves to
   the section root.
6. **Tests**
   - Matcher policy matrix; resolver fetch-error/nil-context fallbacks.
   - VM: edit-path category, manual-entry parity, toggle persistence, preview
     with unsaveable draft, badge text.
   - DB: category-enum↔CHECK drift guard over `allCases` round-trip; v0.21
     hidden-row scrub upgrade-path test; v0.21 marker-missing re-run test.
   - Search index + repo error copy updates.
7. **Docs + flag**: spec/11, 12, 02, README, legacy requirements record,
   traceability, CLAUDE.md, telemetry note (`default_prompt_used` step change),
   brainstorm amendment note; the original ship-polish sequence flipped
   `aiFormatterProfilesEnabled = true` as an isolated final commit.

   **Postscript:** the flag was re-gated to `false` on 2026-06-14 to hold the
   feature out of the v0.6.23 release train. The 2026-07-04 alignment pass kept
   the implementation flag-off and clarified the Settings behavior: built-in
   smart-default prompts remain readable while the master switch is off, but
   the tier cannot run until the master switch is enabled.

## Out of scope

- Browser domain/URL matching, window-title matching (deferred per
  requirements doc).
- Transforms per-app variants (R10 future work).
- Gating app-context capture when the formatter is disabled (one
  `NSWorkspace` read per dictation; pre-existing for telemetry).
- New telemetry fields (R8: V1 emits nothing new).

## Invariants (must not change)

- With the feature flag off: byte-for-byte legacy prompt selection.
- With master smart-defaults off and no profiles: byte-for-byte legacy prompt
  selection.
- Telemetry never carries bundle ID, app name, profile ID/name, match kind,
  prompt body, or transcript (existing regression test stays green).
- No-history mode persists no profile metadata (existing tests stay green).
- No DB schema change in this PR.
