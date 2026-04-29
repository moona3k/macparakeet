# Settings IA Overhaul — Agent Handoff

> **For:** the next Claude Code agent picking up this work.
> **From:** the 2026-04-27 IA design session with Daniel; updated 2026-04-28 after the picker merged, the engine-attribution polish merged, the single-PR strategy was settled, and five design decisions were locked in.
> **Mission:** Execute the Settings IA Overhaul per `2026-04-settings-ia-overhaul.md`. **One branch, one PR, ordered commits.** Read this brief before doing anything else.

---

## 1. Read order (do this first, in order)

1. `/Users/dmoon/code/macparakeet/CLAUDE.md` — project conventions, locked decisions, gotchas
2. `~/.claude/projects/-Users-dmoon-code-macparakeet/memory/MEMORY.md` — auto-loaded user memory; pay attention to feedback entries
3. `/Users/dmoon/code/macparakeet/plans/active/2026-04-settings-ia-overhaul.md` — the plan you'll execute (~470 lines, 13 sections). This is the source of truth.
4. `/Users/dmoon/code/macparakeet/Sources/MacParakeet/Views/Settings/SettingsView.swift` — the current 1,411-line monolith you're decomposing
5. `/Users/dmoon/code/macparakeet/Sources/MacParakeetViewModels/SettingsViewModel.swift` — the 1,265-line VM you're splitting

Do not skip these. Especially the plan — it contains all 9 PR specs, the 4 final tabs, the 7 sub-VMs, the 10 component primitives, the search architecture, and acceptance criteria. If something here conflicts with the plan, the plan wins.

---

## 2. Current state of the world (last updated 2026-04-28)

### What's on `main`

- **PR #170 — `feat/whisper-language-picker` — MERGED 2026-04-28** (squash `d3d06179`). Whisper language picker shipped: `LanguagePickerPopover.swift`, `WhisperLanguageCatalog.swift`, `WhisperLanguageCatalogTests.swift`.
- **PR #171 — `feat/engine-attribution-polish` — MERGED 2026-04-28** (squash `46128653`, archived in `d89f08e0`). `engine` + `engineVariant` columns + `SpeechEnginePreference.friendlyVariantName(_:)` + engine-aware progress/status copy + CLI JSON output all landed.

### What's on `feat/settings-ia`

- **Foundation commit (`7ef48294`)** — 9 component primitives in `Sources/MacParakeet/Views/Settings/Components/`, `SettingsTab` enum, `SettingsRootViewModel` (with persistence), tabbed shell wrapping the existing 15 cards under the Modes tab. 1,853 XCTest + 13 Swift Testing pass (1846 baseline + 7 new). Zero functional UX change beyond the visible tab pill + search field.

### Verify before acting

```bash
git -C <worktree> fetch origin --quiet
git -C <worktree> log origin/main --oneline -3
git -C <worktree> log origin/feat/settings-ia --oneline -10  # if pushed
```

---

## 3. Locked decisions (DO NOT re-open)

These were decided in conversation and codified in the plan. If the user surfaces any again, push back and reference this handoff.

| Decision | Choice |
|---|---|
| Number of tabs | **4: Modes / Engine / AI / System** (order locked 2026-04-28) |
| Branch / merge strategy | **One feature branch `feat/settings-ia`, one PR to `main` at end, ordered commits in between.** No long-lived integration branch with internal sub-PRs. No `kSettingsV2Enabled` feature flag. (Updated 2026-04-28.) |
| `headerCard` "Workspace Controls" | **Eliminated** (decided 2026-04-28). Stat-chips redundant with Storage / Permissions / per-mode chips. Tabs + status badges *are* the at-a-glance summary. |
| `audioInputCard` placement | **Top of Modes tab as its own card; mic permission chip in header status slot** (decided 2026-04-28). Single source of truth shared by Dictation + Meeting; chip lives where users configure input. |
| `generalCard` split | **Split** (decided 2026-04-28): "Show idle pill" → Dictation card. "Launch at login" + "Menu bar only" → System "Startup" card at top of System (frequency-of-use ahead of Permissions). |
| Calendar card | **Folded into Meeting Recording card** as inline section (no longer standalone) |
| Permissions card | **Stays as System dashboard** AND mirrored as inline status chips in per-mode cards (single VM, two view sites) |
| Onboarding-redo | **Stays as System card.** It's a procedural audit-walk-through, not redundant. |
| Storage card | **Slimmed** to read-only stats + audio-retention toggle. The three destructive actions (Clear All Dictations / Reset Lifetime Stats / Clear YouTube Audio) move to Reset & Cleanup. |
| Destructive actions location | **Reset & Cleanup card at bottom of System tab, behind a visual divider.** Not in Library/History data panels. |
| AI tab status semantics | **Yellow only when last actual attempt failed; otherwise silent; never red** (decided 2026-04-28). Don't probe speculatively — cache the outcome of real user activity. AI is opt-in, so red is never appropriate. Adds one "last attempt outcome" field on the LLM service. |
| Vestigial `SettingsViewModel` license UI plumbing | **Drop in a follow-up PR after the IA branch merges** (decided 2026-04-28). The actual `EntitlementsService` is wired into `DictationFlowCoordinator`, `AppEnvironmentConfigurer`, and CLI — keep that. Only the dead UI plumbing on the VM (`isUnlocked`, `licenseKeyInput`, `activateLicense()`, etc.) goes, in a focused follow-up. |
| Picker coordination | Picker landed first (PR #170 merged); the Engine tab commit on `feat/settings-ia` reparents `LanguagePickerPopover` into the Engine tab's Language card. |
| Modes VM composition | **Composition over inheritance.** `ModesSettingsViewModel` owns three `@Observable` child VMs as properties. (Sub-VM split deferred — initial Modes view reads `SettingsViewModel` directly; sub-VM split lands in a later commit on the branch.) |

---

## 4. Still-open questions (do NOT pre-emptively decide)

Deferred to polish-phase commits:

| Question | Surface during |
|---|---|
| Search highlight style — yellow range vs. bold substring | Search commit |
| Reset & Cleanup confirmations — native `.alert` vs. custom modal with checkbox | Reset & Cleanup commit |
| Engine downloading-state badge color — blue (info) vs. yellow (action) | Engine status commit |

Don't ask about these out of order. Surface them when their commit is in flight.

---

## 5. First concrete action

**Verify before assuming.** Run:

```bash
git -C <worktree> fetch origin --quiet
git -C <worktree> log origin/main --oneline -3
git -C <worktree> log feat/settings-ia --oneline -10
gh pr list --repo moona3k/macparakeet --state open
```

Foundation commit (`7ef48294`) is already on the branch. The next chunk is **Modes tab composition** with the five 2026-04-28 design decisions baked in (eliminate headerCard, hoist Audio Input, split generalCard, fold Calendar into Meeting Recording, defer license-UI cleanup to a follow-up PR).

### Carry-forward checklist for Engine tab composition

The picker (#170) and engine attribution (#171) introduced surfaces the Engine tab commit must preserve:

- [ ] `LanguagePickerPopover` (currently invoked from `SettingsView.swift`) → reparent into Engine tab's Language card
- [ ] `WhisperLanguageCatalog` → no move needed (lives in Core)
- [ ] `SpeechEnginePreference.friendlyVariantName(_:)` → reused for Models card variant labels
- [ ] Engine-aware Whisper status strings (`"Whisper Large v3 Turbo · …"` etc., currently in `SettingsViewModel`) → migrate into `EngineSettingsViewModel` during Engine tab commit
- [ ] `engine` / `engineVariant` columns on `Dictation` and `Transcription` → no IA-side change; just don't accidentally regress the History/Transcription panel chips that read them

---

## 6. Quality bar — what "premium" means here

This is not a stock-SwiftUI overhaul. The reference is **Linear / Raycast / 1Password 8**, not Apple System Settings (too sprawling) and not stock SwiftUI (too generic).

Concretely:
- Every new component gets a `#Preview` block, light + dark
- All UI uses `DesignSystem` tokens — no bare `Color.red`, no numeric spacing literals
- Status chip semantics are strict: yellow = recommended, red = required, gray = informational, green = OK. Never mix.
- Microinteractions: 200ms spring on tab switch, 80ms hover lift on cards, 200ms accent-color flash on search-result-tap
- Search transcends tabs (flat results grouped by tab badge), not "filter current tab"
- Tab badges fed by the same VM that drives the inside cards — single source of truth
- All new VMs are `@MainActor @Observable`. **No bare `Task { }` fire-and-forget.** Errors surface as state (`.idle / .loading / .error(message)`).

---

## 7. PR 1 brief (Foundation) — when picker has merged

Scope:
1. Create directory `Sources/MacParakeet/Views/Settings/Components/`
2. Add new primitives:
   - `SettingsTabBar` (pill segmented control with status badges, ⌘1–⌘4 shortcuts)
   - `SettingsSearchField` (⌘F focus, x-clears, results-as-you-type)
   - `SettingsStatusChip` (green/yellow/red dot + label)
   - `SettingsDestructiveButton` (red-tinted bordered with confirmation alert wrapper)
   - `SettingsCardSkeleton` (loading placeholder)
   - `SettingsEmptyState` (no-config CTA)
   - `SettingsErrorBanner` (inline error with retry CTA)
3. Refactor existing inline helpers (`settingsCard` at `SettingsView.swift:1071`, `settingsToggleRow` at `:1080`) into real `SettingsCard<Content>` and `SettingsRow<Trailing>` components in `Components/`.
4. Add `SettingsTab` enum (`.modes`, `.engine`, `.ai`, `.system`).
5. Add `SettingsRootViewModel` skeleton in `Sources/MacParakeetViewModels/` — owns `activeTab` and `searchQuery` for now.
6. Wrap current `SettingsView` body in a tabbed shell — but show **ALL 15 cards under a single tab**. No reorganization yet. **Zero functional change to the user.**

Acceptance for PR 1:
- All 1,700 existing tests pass (`swift test`)
- Settings looks indistinguishable to the user except for the (single) tab pill at the top
- New components have `#Preview` blocks, light + dark
- No bare `Color.*` literals introduced (verify via grep on `Sources/MacParakeet/Views/Settings/Components/`)

PR 1 is intentionally boring. It exists so PRs 2–9 can move cards around without each reinventing primitives.

---

## 8. Operating-mode notes (Daniel's preferences)

Daniel is decisive, prefers simplicity, and explicitly values critical pushback.

**Do:**
- Push back with reasoning when something is wrong, before complying
- Concede directly when you've made a mistake — Daniel appreciates honest correction over face-saving
- Verify state before acting (`git status`, file reads, tests) — don't assume
- Surface the still-open questions only when their PR is in flight
- Run `swift test` before declaring any PR ready
- Use the rich commit message format from `docs/commit-guidelines.md` for non-trivial commits
- Update the plan file's checklists as items complete

**Don't:**
- Re-litigate locked decisions in Section 3
- Pre-emptively answer the still-open questions in Section 4
- Add features beyond the plan's scope — this is reorganization, not new functionality
- Use emojis in code, commit messages, or PR descriptions
- Write planning docs into `Sources/` — those go in `plans/`
- Leave dead code, half-finished implementations, or `_ = unused` artifacts
- Sycophantic preambles ("Great question!"). Just answer.

---

## 9. Coordination & risk reminders

- **Picker dependency** is the only hard blocker for starting PR 1. If picker is delayed, IA work waits.
- **Long-lived `feat/settings-ia` integration branch** — rebase onto `main` weekly to catch unrelated work. Drift is the main risk.
- **PR 9 (accessibility audit)** is the gate before final squash to `main`. Don't skip.
- **Test count baseline** is 1,700 XCTest + 13 Swift Testing as of 2026-04-26. New sub-VM tests should add to this, not replace.
- **VoiceOver / keyboard nav** are first-class — don't defer to "later." PR 9 verifies, but every component primitive should consider focus + announcement during PR 1.

---

## 10. Cross-references

| Doc | Why |
|---|---|
| `plans/active/2026-04-settings-ia-overhaul.md` | The plan. Source of truth. |
| `plans/active/2026-04-viral-growth-playbook.md` | Section 4 ("First-60-Seconds Audit") includes Settings polish — this work delivers the Settings half |
| `spec/00-vision.md` | Outdated; flagged in 2026-04-27 review for separate rewrite. Don't cite as authority. |
| `docs/commit-guidelines.md` | Rich commit message format |
| `CLAUDE.md` § "Known Pitfalls" | Swift / AppKit / DB / GRDB gotchas |
| `MEMORY.md` § "Lessons Learned" | Project-specific incidents and patterns |

---

## 11. When in doubt

- Re-read the plan file. It's likely answered there.
- If still ambiguous, ask Daniel before deciding.
- If a locked decision in Section 3 above seems wrong on closer inspection, raise it explicitly — don't just do something else.
- If something feels like scope creep, it probably is. This is reorganization, not new features.
