# Settings IA Overhaul — Premium Enterprise-Grade UX

> **Status:** Active. Drafted 2026-04-27 after IA conversation with Daniel. Updated 2026-04-28 with the single-PR strategy and five design decisions on previously-open questions.
> **Scope:** Refactor MacParakeet Settings from a 1411-line single-scroll-15-cards panel into a tabbed, searchable, status-aware Settings surface that feels Linear-grade. Sub-VM split is forced by the IA, not the other way around.
> **Owner:** Daniel.
> **Branch:** `feat/settings-ia` — one branch, one final PR to `main`, ordered commits along the way (no long-lived integration branch with internal PRs).

---

## 1. Problem & North Star

### Today

- `Sources/MacParakeet/Views/Settings/SettingsView.swift` — 1,411 lines, 15 cards in one vertical `ScrollView`, ordered by implementation history rather than user intent.
- `Sources/MacParakeetViewModels/SettingsViewModel.swift` — 1,265 lines, ~80 fields, six mutually exclusive `Task { }` blocks fired from `.onAppear`.
- 28+ user-facing toggles/actions, no search, no findability beyond manual scroll.
- Storage card mixes read-only configuration (audio retention) with three catastrophic destructive actions (Clear All Dictations, Reset Lifetime Stats, Clear YouTube Audio).
- Permissions live in their own card *and* are duplicated implicitly in per-mode cards (no consolidated dashboard mental model, no contextual chip pattern).

### Target experience

A user opens Settings and immediately:

1. Knows where things are (4 named tabs, no scroll-and-pray).
2. Can `⌘F` to find any setting in <500ms.
3. Sees status at a glance (subtle yellow dot on tabs that need attention).
4. Trusts destructive actions are safely contained — fenced off, named explicitly, never interleaved with daily config.
5. Feels the surface is alive — instant persistence, smooth tab transitions, restrained but native motion.

The bar is **Linear / Raycast / 1Password 8**, not Apple System Settings (too sprawling) and not stock SwiftUI (too generic).

---

## 2. Final Information Architecture

### The 4 tabs

```
┌──────────────────────────────────────────────────────────────────────┐
│  [ Modes ]  [ Engine ]  [ AI ]  [ System ]              [⌕ search ]  │
└──────────────────────────────────────────────────────────────────────┘
```

**Modes** — daily-ops config for the three product modes, plus the Audio Input prerequisite. Each mode card shows relevant permissions inline as status chips.

| Position | Card | Contents |
|---|---|---|
| 1 | Audio Input | Mic device picker, refresh, level-meter test. **Mic permission chip in header status slot** — one source of truth, no duplication on Dictation/Meeting cards. Subtitle: "Used for dictation and meetings." |
| 2 | Dictation | Hotkey, push-to-talk vs persistent guide, auto-stop after silence + delay, **Show idle pill toggle (relocated from old `generalCard`)**, accessibility-permission chip in header |
| 3 | Transcription | File transcription hotkey, YouTube transcription hotkey, speaker detection, auto-save transcripts + destination |
| 4 | Meeting Recording | Meeting hotkey, **calendar auto-start folded in** (not a separate card), pending recovery action, auto-save meetings + destination, screen-recording-permission chip in header — gated on `AppFeatures.meetingRecordingEnabled` |

**Engine** — speech recognition stack.

| Card | Contents |
|---|---|
| Engine selector | Parakeet / Whisper segmented; brief copy on what each is best at |
| Language | Auto-detect default; searchable picker (the in-flight `LanguagePickerPopover.swift` lives here); contextually relevant only when Whisper is active |
| Models | Per-engine download status, sizes, manage / retry actions |

**AI** — LLM provider config (already a clean subsystem). Reuses the existing `LLMSettingsView` with light polish to consistent card primitives.

| Card | Contents |
|---|---|
| Provider | Claude / OpenAI / OpenAI-Compatible / LM Studio (existing) |
| Formatter | On/off, prompt selection |

**System** — everything that isn't daily ops, ordered by frequency of use. Reset & Cleanup is fenced off at the bottom by a divider.

| Position | Card | Contents |
|---|---|---|
| 1 | Startup | **Launch at login + Menu Bar Only mode (relocated from old `generalCard`).** Frequency-of-use puts startup ahead of permissions — startup is what users tweak when they change their mind about app presence; permissions is diagnostic. |
| 2 | Permissions | Dashboard view of mic, accessibility, screen recording — high-signal diagnostic when something breaks |
| 3 | Storage | Read-only: disk used, model size; toggle: audio retention |
| 4 | Updates | Auto-check, auto-download (Sparkle bindings) |
| 5 | Privacy & Telemetry | Telemetry opt-out toggle, plain-language explainer |
| 6 | Onboarding-redo | "Run setup again" — preserves Daniel's audit-walk-through use case |
| 7 | About | Version, build identity (with copy button), license, GitHub link |
| — | *visual divider* | — |
| 8 | Reset & Cleanup | Three destructive actions, each with one-line blast-radius description |

### Diff vs. today

| Before (today) | After (target) | Reason |
|---|---|---|
| 15 cards in one vertical scroll | 4 tabs, ~13 cards distributed | Findability; eliminate scroll-and-pray |
| `headerCard` "Workspace Controls" with 4 stat chips | **Eliminated** | Every chip is already shown elsewhere (Storage, Permissions, per-mode chips). The four-tab bar with status badges *is* the at-a-glance summary. Modes opens to Dictation first — what users came for. |
| `audioInputCard` mixed in mid-list | **Top of Modes tab as its own card; mic permission chip in header** | Mic is one piece of hardware shared by Dictation + Meeting — single source of truth, no per-mode duplication. Permission chip belongs where users configure input. |
| `generalCard` (idle pill + launch + menu bar) | **Split:** idle pill → Dictation card; launch + menu bar → System "Startup" card | Idle pill is dictation-UX; launch + menu bar are OS-integration. Different audiences, different tabs. |
| Storage card mixes read-only + destructive | Storage (read-only) + Reset & Cleanup (destructive, fenced) | Different intents, different anxiety levels |
| Permissions standalone card | Permissions dashboard (System) + per-mode chips (Modes) | Both views: contextual + global |
| Calendar standalone card | Folded into Meeting Recording card as inline section | Reduces card count; calendar is meeting-only |
| Onboarding-redo card | Stays as System card | Per Daniel's feedback — it's a procedural audit, not redundant |
| AI Provider card | Becomes its own AI tab | Provider config is dense enough to deserve a tab |
| Vestigial `SettingsViewModel` license UI plumbing (`isUnlocked`, `licenseKeyInput`, `activateLicense()`, etc.) | **Drop in a follow-up PR** (not in this branch) | Keeps the IA branch's review surface focused on the IA. The actual `EntitlementsService` is *not* vestigial — it gates dictation/CLI transcription. Only the dead UI plumbing on the VM goes. |

### Search escape hatch

Search transcends tabs. When the search field is non-empty, the 4-tab layout collapses into a flat results list grouped by tab name with badges. Click a result → navigate to its tab + scroll to its card + 200ms accent flash on the row. `⌘F` focuses search; `Esc` clears.

---

## 3. Sub-View-Model Split

`SettingsViewModel` (1,265 lines, ~80 fields) splits into focused VMs. Each new VM is `@MainActor @Observable`, no bare `Task { }` patterns.

| New VM | Owns | Approx. size |
|---|---|---|
| `SettingsRootViewModel` | active tab, search query, deep-link state, shared service handles, fan-out refresh on `.onAppear` / `didBecomeActive` | ~200 lines |
| `ModesSettingsViewModel` | composition root for the three section VMs below | ~100 lines |
| `DictationSectionViewModel` | hotkey, hold/toggle, mic, processing mode, dictation-specific permissions | ~250 lines |
| `TranscriptionSectionViewModel` | transcription hotkeys, auto-copy, speaker detection, auto-save | ~150 lines |
| `MeetingSectionViewModel` | meeting hotkey, calendar settings, screen-recording-permission | ~200 lines |
| `EngineSettingsViewModel` | engine selector, Whisper language, model status, downloads | ~250 lines |
| `LLMSettingsViewModel` | already exists — reused as-is | unchanged |
| `SystemSettingsViewModel` | permissions polling, storage stats, updates wrapper, privacy/telemetry, onboarding-redo trigger, about info, destructive actions | ~400 lines |

**Total: ~1,550 lines distributed across 7 focused VMs** (vs. 1,265 lines in one). Same approximate volume, but each VM has a single bounded job and is independently testable.

### Key architectural decisions

- **Composition over inheritance for Modes.** `ModesSettingsViewModel` owns three `@Observable` child VMs as properties. The Modes view passes the right child VM to each card. Resists re-becoming a god object.
- **No bare `Task { }` in new code.** All async work is invoked from `@MainActor` contexts via `await`, with errors surfaced as state (`.idle / .loading / .error(message)`). Closes the pattern flagged in the architecture review (recent fixes in `5c67d638` / `89d82fff` were point patches; this generalizes).
- **Sub-VMs do not import each other.** Cross-VM coordination happens at `SettingsRootViewModel`. Prevents implicit coupling.
- **VMs do not import SwiftUI.** They live in `MacParakeetViewModels`, depend only on `MacParakeetCore`. Same as today; preserved.

---

## 4. Component Primitives (new + refactored)

Every new component lives in `Sources/MacParakeet/Views/Settings/Components/` with a `#Preview` block in light + dark, narrow + wide.

| Primitive | Status | Purpose |
|---|---|---|
| `SettingsTabBar` | NEW | Pill-style segmented control with status badges and `⌘1`–`⌘4` shortcuts |
| `SettingsSearchField` | NEW | Persistent top-of-panel search field; `⌘F` focuses, `x` clears, results-as-you-type |
| `SettingsCard<Content>` | REFACTOR (currently inline helper at SettingsView.swift:1071) | Real component: title + subtitle + status chip slot + content slot |
| `SettingsRow<Trailing>` | REFACTOR (currently inline at SettingsView.swift:1080) | Title + helper text + trailing control slot |
| `SettingsStatusChip` | NEW | Green/yellow/red dot + label; used both inline in cards and on tab bar |
| `SettingsDestructiveButton` | NEW | Bordered red-tinted button with built-in confirmation alert wrapper |
| `SettingsKeyboardCapture` | AUDIT (exists) | Existing hotkey capture component; verify consistent active state across all three hotkey rows |
| `SettingsCardSkeleton` | NEW | Loading placeholder; preserves layout vs. spinner pop-in |
| `SettingsEmptyState` | NEW | First-time / no-config CTA card (e.g., "No AI provider configured — Add one") |
| `SettingsErrorBanner` | NEW | Inline error + retry CTA (model download failed, etc.) |

### Design rules

- **No bare `Color.*` or numeric spacing literals.** Everything from `DesignSystem`. Lint via `grep -rn "Color\.\(red\|blue\|green\)" Sources/MacParakeet/Views/Settings/` post-merge.
- **Red is reserved for destructive actions.** Status chips never use red — yellow means "action recommended," green means "OK," gray means "informational."
- **One accent color, one neutral palette.** Match existing `DesignSystem.Colors`.

---

## 5. Search Architecture

### Index

Built lazily on first search, or eagerly at `SettingsRootViewModel` init (cheap — ~50–80 entries).

```swift
struct SettingsSearchEntry: Identifiable {
    let id: String              // "<tab>.<card>.<row>"
    let tab: SettingsTab
    let cardID: String
    let rowID: String
    let title: String
    let subtitle: String?
    let keywords: [String]      // synonyms: "delete" → ["clear", "reset", "wipe", "remove"]
}
```

### Matching

- Case-insensitive substring on `title`, `subtitle`, `keywords`.
- Optional fuzzy (Levenshtein) — start with substring; upgrade only if it feels insufficient.
- Highlight matched range inline using `AttributedString`.

### UI mode

| Query state | UI |
|---|---|
| Empty | Normal 4-tab view |
| Non-empty | Flat results list, grouped by originating tab, with tab-name badges |
| No matches | Empty-state copy: "No settings match '*query*'." |

### Navigation behavior

- Click result → navigate to (tab, cardID, rowID) → scroll card into view → 200ms accent-color flash on the landing row.
- `⌘F` from any tab → focuses search field.
- `Esc` while searching → clears query, restores tab view.
- `Esc` while not searching → no-op (don't dismiss the panel).

### Why this is the premium pattern

Most indie settings have either tabs **or** search; rarely both well-integrated. Linear has both. Raycast has both. macOS System Settings has both. The "flat-when-searching" pattern is what separates this from "filter the current tab only" amateur-hour search.

### Compile-time sync

The search index is built from the same enum/struct hierarchy that drives the tabs and cards. A new card without a corresponding `SettingsSearchEntry` should fail a unit test (`testEverySettingsCardHasSearchIndex`), preventing drift.

---

## 6. Status Awareness

### Tab badges

Each tab in the bar can show a small status dot. Strict semantics:

| Tab | Yellow dot when… | Red dot when… |
|---|---|---|
| Modes | Any required permission for an enabled mode is missing | (never) |
| Engine | Model failed to load, or download interrupted | No model installed at all (first-run-incomplete) |
| AI | (never — opt-in feature, no error state) | (never) |
| System | Permissions dashboard shows any missing | (never) |

**Rule:** yellow = action recommended; red = action required; no dot = nothing actionable. Never use color for "informational."

### In-card chips

The Permissions dashboard uses `SettingsStatusChip` per row. Per-mode cards in the Modes tab use the same chip inline next to the relevant permission. Single source of truth (the appropriate VM), two view sites — no duplicated polling.

---

## 7. Microinteractions Checklist

These are the details that separate functional from premium. Each is small; together they're the whole feel.

- [ ] Tab switch: 200ms spring, active pill background slides between segments
- [ ] Card hover: 1px lift, 80ms ease, subtle shadow
- [ ] Toggle: native SwiftUI `Toggle` (don't reinvent); verify haptic + animation feel solid
- [ ] Hotkey capture: dotted border + "Press your hotkey…" placeholder when listening; success → 80ms green flash
- [ ] Engine switch: smooth crossfade between Parakeet/Whisper status panels; explicit loading state during async swap
- [ ] Search input: caret + filtering as-you-type, no `Enter` required
- [ ] Search result tap: scroll-to + 200ms accent-color flash on landing row
- [ ] Destructive confirmation: native `.alert` (existing pattern), no custom modal — preserves accessibility
- [ ] Empty state: subtle SF Symbol or illustration + 1-line copy + CTA button
- [ ] Loading state: card-shaped skeleton, not a generic spinner
- [ ] Tab keyboard shortcuts: `⌘1`–`⌘4` navigate tabs; shown on hover or via `.help()`
- [ ] `Esc` behavior: clear search if active; otherwise no-op
- [ ] Last-viewed tab persists across app restart (UserDefault `kSettingsLastViewedTab`)
- [ ] Scroll position within a tab persists when switching back to that tab in the same session

---

## 8. Acceptance Criteria

### Functional

- [ ] All 28+ existing toggles/actions are preserved and reachable
- [ ] No regressions in preference persistence (UserDefaults keys unchanged)
- [ ] All existing tests pass (1,700 XCTest baseline)
- [ ] New sub-VM tests cover state transitions for each VM
- [ ] Search index test: every tab/card/row appears at least once
- [ ] Deep-link test: programmatic navigation to (tab, cardID, rowID) works
- [ ] Tab persistence test: kill app, relaunch, last tab restored

### UX

- [ ] Settings opens in <100ms (no async block on view init)
- [ ] Tab switch feels instant and smooth (perceptual <200ms)
- [ ] `⌘F` focuses search from any tab
- [ ] `Esc` clears search
- [ ] All destructive actions live in Reset & Cleanup card, not interleaved
- [ ] Permissions chip status is consistent between System dashboard and per-mode cards
- [ ] Dark mode is first-class — every component previewed and visually verified

### Code health

- [ ] No view file >700 lines
- [ ] No VM file >500 lines
- [ ] All Settings UI uses `DesignSystem` tokens (lint check via `grep`)
- [ ] No bare `Task { }` calls in new code
- [ ] All new components have `#Preview` blocks (light + dark)

---

## 9. Phased Rollout

Ship as a chain of focused PRs. Each PR is independently reviewable, mergeable, testable.

| PR | Scope | Days |
|---|---|---|
| **PR 1: Foundation** | Component primitives (TabBar, SearchField, refactored Card/Row, StatusChip, DestructiveButton). `SettingsTab` enum. `SettingsRootViewModel` skeleton. Old SettingsView still rendering — but inside a new shell that shows one tab pill with all 15 cards underneath. No functional change yet. | 2 |
| **PR 2: Modes tab** | Move Dictation + Transcription + Meeting cards under Modes tab. Introduce `DictationSectionViewModel`, `TranscriptionSectionViewModel`, `MeetingSectionViewModel`. Permissions chips inline in each mode card. Calendar folded into Meeting Recording card. | 3 |
| **PR 3: Engine tab** | New tab. Engine selector, language picker (the in-flight `feat/whisper-language-picker` branch rebases onto Engine tab). Model status card. `EngineSettingsViewModel`. | 2 |
| **PR 4: AI tab** | Reuse `LLMSettingsView`. Light polish to consistent `SettingsCard` primitive, consistent header, `SettingsEmptyState` when no provider configured. | 1 |
| **PR 5: System tab** | Permissions dashboard, Storage (read-only slimmed), Updates, Privacy, Onboarding-redo, About. `SystemSettingsViewModel`. Visual divider before Reset & Cleanup. | 3 |
| **PR 6: Reset & Cleanup card** | Final card in System. Three destructive actions, each with one-line blast-radius copy. Reuses existing confirmation alerts. | 1 |
| **PR 7: Search** | Search index + flat results UI + deep-link navigation + `⌘F` + `Esc` + result-tap accent flash. | 2 |
| **PR 8: Microinteractions polish** | Tab transitions, hover states, hotkey-capture polish, empty/error/loading states, `⌘1`–`⌘4` shortcuts. | 2 |
| **PR 9: Accessibility audit** | VoiceOver labels, keyboard-only nav, focus rings, contrast in dark mode. | 1 |

**Total: ~17 working days.** Compressible with parallel work — Modes (PR 2), Engine (PR 3), and AI (PR 4) tabs are independent.

### Sequencing notes

- PR 1 must merge first (foundation).
- PRs 2–5 (the four tabs) can interleave; PR 5 (System) is best last because it absorbs leftovers.
- PR 6 piggybacks on PR 5.
- PR 7 (Search) depends on all tabs landing — index references final card structure.
- PR 8 polish runs after functional completeness.
- PR 9 accessibility audit is the gate before final merge to main.

### Branch strategy — UPDATED 2026-04-28: single PR, ordered commits

One feature branch `feat/settings-ia` off `main`. **One PR to `main` at the end.** No long-lived integration branch with internal sub-PRs; the nine "phases" above become the **commit chain inside the single branch**, readable via `git log -p`.

Implications:
- A senior team can absorb a ~5,000-line refactor PR in one review. The trade-off is fewer mid-flight UX course-corrections; mitigated by the five design decisions resolved upfront (Section 12) and visual mocks where ambiguous.
- Commits land incrementally on the branch as each phase completes. Daniel (or any reviewer) can scan `git log` to follow the architecture's evolution.
- No `kSettingsV2Enabled` flag — keeps the codebase clean of dual UI paths.
- Pre-merge gate: phase 9 (accessibility audit) is the last gate; if anything regresses there, fix in place rather than ship-and-patch.
- During the implementation window (~3 weeks of senior-dev effort), avoid landing other PRs that touch `Sources/MacParakeet/Views/Settings/` or `Sources/MacParakeetViewModels/SettingsViewModel.swift` to minimize rebase tax.

---

## 10. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| 1,411-line file rewrite breaks existing behavior | Medium | High | Phase ship; preserve old SettingsView in PR 1, swap card-by-card |
| VM split introduces concurrency bugs | Medium | Medium | All new VMs are `@MainActor @Observable`; no `Task { }` without an `await`-able caller |
| Search index drifts from card structure | Low | Medium | Index built from same enum/struct that drives tabs; unit test enforces every card appears at least once |
| Tab switch feels janky on transcript-loaded sessions | Low | Medium | Lazy-render tab content; cards in inactive tabs are not in the view tree |
| `feat/whisper-language-picker` (in flight) conflicts with Engine tab refactor | Resolved | — | Land language picker first into current SettingsView (decided 2026-04-27). PR 3 (Engine tab) starts from `main` after the picker has merged and reparents `LanguagePickerPopover` into the Engine tab's Language card. |
| Reset & Cleanup card buried at bottom of System tab — users can't find it | Low | Low | Search index covers it; small "Manage storage…" deep-link from data panels for the disk-full path |
| Status badges overpromise (yellow dot when actually fine) | Medium | Low | Strict semantics: yellow only if action is recommended, never for "informational" |

---

## 11. Out of Scope

- New settings (no feature additions; this is pure reorganization)
- Preference key migrations (none required — UserDefaults keys unchanged)
- Telemetry plumbing changes
- Library / History panel rewrites (only the small "Manage storage…" deep-link added)
- Custom Settings window (we stay inside the main panel)
- Localization (English-only for now; structure supports future)
- Audio input picker mirror in dictation overlay (deferred — separate decision)

---

## 12. Decisions & Open Questions

### Resolved (2026-04-27)

- **Coordinate with `feat/whisper-language-picker`** — Picker PR shipped first into current SettingsView (merged 2026-04-28 as PR #170). Engine tab refactor reparents `LanguagePickerPopover` into the new Engine tab's Language card.

### Resolved (2026-04-28)

- **Branch & merge strategy** — Single feature branch `feat/settings-ia` cut from `main`; one PR to `main` at the end; the nine phases are the commit chain inside the branch (no long-lived integration branch with internal sub-PRs). No `kSettingsV2Enabled` feature flag. (Section 9 updated.)
- **Tab order** — `Modes / Engine / AI / System`. Daily-ops first, infrastructure-toward-the-back. AI stays after Engine because Engine is the more frequently-touched surface and AI is genuinely opt-in.
- **headerCard fate** — **Eliminate.** Every chip in the current "Workspace Controls" card is already shown elsewhere: Dictations count + YouTube cache live in Storage; Mic + Accessibility live in Permissions and (per the new IA) per-mode chips. The four-tab bar with status badges *is* the at-a-glance summary. Removing it also means Modes opens to **Dictation** first — what users came for ~80% of the time.
- **audioInputCard placement** — Own card at the **top of Modes**, with the **mic permission chip in its header status slot**. Mic is a single piece of hardware shared by Dictation + Meeting, so it lives in one place, not duplicated. The permission chip belongs where the user is already configuring input. Subtitle clarifies scope: "Used for dictation and meetings."
- **generalCard split** — Don't move it as a unit. Two intents:
  - **"Show idle pill"** → Dictation card (the idle pill *is* the dictation summon button — a dictation-UX choice).
  - **"Launch at login" + "Menu bar only"** → System tab, in a card called **"Startup"** (frequency-of-use puts this at position 1 of System, ahead of Permissions which is diagnostic).
- **AI tab status semantics** — **Yellow when the last actual attempt failed; otherwise silent; never red.** Don't probe speculatively — cache the outcome of real user activity. If summary generation failed with a 401 yesterday, AI tab shows a yellow dot today. If it succeeded last time, no badge. AI is genuinely opt-in, so red is never appropriate. Adds one contract field on the LLM service ("last attempt outcome"). This is the *evidence-based* version of status awareness.
- **Licensing/entitlements UI plumbing** — **Drop in a follow-up PR**, not in the IA refactor branch. The actual `EntitlementsService` is wired into `DictationFlowCoordinator`, `AppEnvironmentConfigurer`, and the CLI — it's the runtime gate, not vestigial. The vestigial parts are the UI-bound license activation state on `SettingsViewModel` (`isUnlocked`, `licenseKeyInput`, `activateLicense()`, etc.) which no UI binds to. Splitting this into its own PR keeps the IA branch's review surface focused on the IA.

### Still open (deferred to polish-phase commits)

- [ ] **Search highlight style** — yellow background range, or just bold the matched substring? Decide during the search commit.
- [ ] **Reset & Cleanup confirmations** — keep native `.alert` (current) or move to richer custom modals with a checkbox "I understand this is irreversible"? Decide during the Reset & Cleanup commit.
- [ ] **Status badge color for Engine when downloading** — blue (informational) or yellow (action needed)? Decide when wiring Engine status.

---

## 13. Reference

### Files touched

| Path | Action |
|---|---|
| `Sources/MacParakeet/Views/Settings/SettingsView.swift` | Eventually deleted, replaced by tabbed shell |
| `Sources/MacParakeet/Views/Settings/Components/` | New directory for primitives |
| `Sources/MacParakeet/Views/Settings/Tabs/ModesSettingsView.swift` | New |
| `Sources/MacParakeet/Views/Settings/Tabs/EngineSettingsView.swift` | New |
| `Sources/MacParakeet/Views/Settings/Tabs/AISettingsView.swift` | New (refactor of existing LLMSettingsView) |
| `Sources/MacParakeet/Views/Settings/Tabs/SystemSettingsView.swift` | New |
| `Sources/MacParakeet/Views/Settings/LanguagePickerPopover.swift` | Keep, used by Engine tab |
| `Sources/MacParakeetCore/WhisperLanguageCatalog.swift` | Keep, unchanged |
| `Sources/MacParakeetViewModels/SettingsViewModel.swift` | Split, eventually deleted |
| `Sources/MacParakeetViewModels/SettingsRootViewModel.swift` | New |
| `Sources/MacParakeetViewModels/Modes/{Dictation,Transcription,Meeting}SectionViewModel.swift` | New |
| `Sources/MacParakeetViewModels/EngineSettingsViewModel.swift` | New |
| `Sources/MacParakeetViewModels/SystemSettingsViewModel.swift` | New |

### Conventions to honor

- `DesignSystem` tokens (no bare `Color` / spacing literals)
- `@MainActor @Observable` on all VMs
- Async/await over Combine for new code
- ViewModels in `MacParakeetViewModels` target (testable without GUI)
- Inline `// MARK:` for major sections within each view file
- `#Preview` blocks for every new component, light + dark
- No `Task { ... }` fire-and-forget; surface errors as state

### Gotchas (from memory + earlier review)

- Don't blanket `@MainActor` on Core services; mark methods that need it (per architecture review)
- `KeylessPanel` + popover anti-pattern — Settings runs in a regular NSWindow, so `.popover` is fine here
- Tooltips: `.help()` for plain text; for keyboard-shortcut decorated tooltips, use NSTrackingArea
- Sparkle update preferences are bound to `SPUUpdater` — don't shadow them in `SystemSettingsViewModel`; pass the updater through
- Telemetry allowlist is a two-repo change — but no new telemetry events are introduced by this plan, so non-issue

### Cross-references

- `spec/00-vision.md` — needs follow-up rewrite (separate concern flagged in 2026-04-27 review)
- `plans/active/2026-04-viral-growth-playbook.md` — Section 4 ("First-60-Seconds Audit") includes Settings polish as part of cold-launch UX; this plan delivers the Settings half
- Architecture review punch list (2026-04-27 conversation): items #3 (SettingsViewModel god object), #4 (preferences namespace bloat), #6 (fire-and-forget Task pattern), #8 (no `@MainActor` on VMs) all addressed by this plan
