---
title: Outlook Calendar Support - Plan
type: feature
date: 2026-09-13
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
deepened: 2026-09-13
---

# Outlook Calendar Support - Plan

## Goal Capsule

- **Objective:** People who use Outlook or Microsoft 365 can find and configure MacParakeet's calendar integration without mistaking Apple Calendar for the only supported provider.
- **Means:** Keep EventKit as the single local calendar source and add accurate setup, account-management, refresh, search, and documentation affordances (KTD1-KTD4).
- **Authority:** Current repository behavior and Apple/Microsoft platform contracts outrank implementation preference; issues #502 and #1013 establish the user problem.
- **Execution profile:** Standard, user-visible feature across Settings, Meetings discovery copy, search, and governing documentation.
- **Stop conditions:** Stop before adding Microsoft Graph, OAuth, provider-specific persistence, or unverified shared-calendar promises.
- **Delivery:** Implement, verify, independently review, and open one PR that references both issues.

---

## Product Contract

### Summary

MacParakeet already reads every event calendar exposed by EventKit, including Exchange sources configured in macOS Internet Accounts. The product must explain that Outlook and Microsoft 365 work through that local account setup, provide a direct recovery path when an account is missing, and refresh visible calendars after the user returns from System Settings.

### Problem Frame

Issues #502 and #1013 independently ask for Outlook calendar integration after calendar support shipped. Neither report demonstrates an EventKit failure; both describe the current surface as “macOS Calendar,” which hides the fact that Outlook and Microsoft 365 calendars are supported when the same account is enabled for Calendar in macOS Internet Accounts.

### Requirements

**Provider boundary**

- R1. MacParakeet must continue to use EventKit as its only calendar backend and must not add a Microsoft sign-in or cloud calendar data path.
- R2. User-facing copy must state that Microsoft 365 and Exchange calendars work when added to Calendar on this Mac, while avoiding a blanket promise for Outlook-only local data or unverified shared calendars.

**Setup and recovery**

- R3. Calendar settings must expose an Internet Accounts action and an explicit calendar refresh whether the current visible-calendar list is empty or populated.
- R4. Calendar settings must distinguish initial loading from a loaded empty result and show actionable guidance when EventKit returns no calendars.
- R5. Returning to MacParakeet after account or permission changes must refresh Calendar authorization and the visible-calendar list without requiring an app restart.
- R6. A denied Calendar permission must keep the existing Privacy & Security recovery path distinct from the Internet Accounts setup path.

**Discovery and documentation**

- R7. Settings search and the Meetings calendar entry point must recognize and explain Outlook, Microsoft 365, Exchange, and Internet Accounts terminology.
- R8. README, spec-index, and ADR documentation must describe the supported setup path, the local-first boundary, and the limits of current runtime evidence.

### Key Flows

- F1. **Outlook-only setup**
  - **Trigger:** A user searches Settings for Outlook or opens Meeting Recording calendar settings.
  - **Steps:** The UI explains the macOS account requirement, opens Internet Accounts, and refreshes permission and calendars after the user returns.
  - **Outcome:** A newly enabled Exchange calendar appears in MacParakeet without restarting the app.
  - **Covered by:** R2-R5, R7
- F2. **Existing calendars plus Exchange**
  - **Trigger:** A user already has iCloud, Google, or another EventKit calendar but wants to add Microsoft 365.
  - **Steps:** The account-management action remains visible beside the populated calendar controls, and refresh preserves the current include/exclude choices.
  - **Outcome:** The user can add Exchange without MacParakeet introducing a second provider model.
  - **Covered by:** R1, R3-R5
- F3. **Permission recovery**
  - **Trigger:** Calendar authorization is denied or revoked.
  - **Steps:** MacParakeet directs the user to the Calendar privacy pane; account-management guidance does not replace that permission fix.
  - **Outcome:** Authorization and account setup remain understandable as separate prerequisites.
  - **Covered by:** R5-R6

### Acceptance Examples

- AE1. **Covers F1.** Given Calendar access and no visible calendars, when the first EventKit lookup completes, Settings shows a no-calendars message with Manage Accounts and Refresh actions rather than hiding the section or flashing the empty state during loading.
- AE2. **Covers F2.** Given one visible iCloud calendar, when the calendar controls render, the user can still open Internet Accounts to add Microsoft 365 and can refresh without losing the existing calendar selection.
- AE3. **Covers F3.** Given denied Calendar access, Settings continues to open Privacy & Security > Calendars and does not present Internet Accounts as a substitute for permission recovery.
- AE4. **Covers R7.** Given the query “Outlook,” “Microsoft 365,” “Exchange,” or “Internet Accounts,” Settings search returns the Meeting Recording calendar destination while the calendar feature flag remains enabled.

### Scope Boundaries

#### Deferred to Follow-Up Work

- Physical Microsoft 365 and oldest-supported-macOS smoke testing when suitable accounts and hardware are available.
- Shared and delegated Exchange calendar claims after representative runtime verification.
- Microsoft Graph/OAuth only if users still cannot use required calendars after the EventKit setup path is documented and tested.

#### Out of Scope

- Reading Outlook's private local database or Outlook-only “On My Computer” calendars.
- Adding provider enums, new calendar persistence, event-source deduplication, or a second calendar service.
- Changing meeting filtering, calendar polling, event conversion, or Teams-link parsing; current code already consumes all EventKit calendars and recognizes `teams.microsoft.com` links.
- Treating “no matching upcoming events” in Meetings as proof that no calendar accounts are configured.

### Sources and Research

- `docs/research/2026-09-13-issues-502-1013-outlook-calendar.md` records the issue review, repository evidence, Apple EventKit/Exchange contracts, Microsoft setup boundary, Graph comparison, and verification limits.
- `Sources/MacParakeetCore/Calendar/CalendarService.swift` is the provider-neutral EventKit implementation and already enumerates all event calendars.
- `spec/adr/017-calendar-meeting-auto-start.md` owns the local-first calendar architecture.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Retain one provider-neutral EventKit path.** This follows the accepted architecture and avoids Graph authentication, tenant-consent, network, token, merge, and privacy failure modes that the two reports do not justify. Governs R1-R2.
- KTD2. **Put account guidance in the always-reachable Calendar settings surface.** Provider explanation must not exist only inside controls hidden by permission or mode state; loaded empty and populated states both expose recovery. Governs R2-R4, R6.
- KTD3. **Use one ordered, latest-result-wins refresh operation.** Initial appearance, app activation, permission changes, and the explicit action all invoke the same operation. It reads authorization first, clears visible calendars immediately unless access is granted, and only applies an awaited calendar result when that refresh is still the newest generation and authorization remains granted. Refresh never requests permission, changes auto-start mode, or mutates calendar exclusions. Governs R3-R5.
- KTD4. **Treat Internet Accounts deep links as best-effort navigation.** Try current and legacy pane URLs in order through an injected URL-opening seam, stop on the first success, and finally open generic System Settings. Keep the written “System Settings > Internet Accounts” path visible because a successful URL open does not prove that macOS selected the intended pane. Governs R3, R6.
- KTD5. **Open the PR without physical Microsoft-account certification.** (session-settled: user-directed — chosen over requiring a real Microsoft 365 smoke test before PR: no suitable account is available, and the documented EventKit contract plus existing provider pattern is acceptable evidence.) The PR must state this limit instead of implying runtime certification. Governs R8.

### Implementation Constraints

- Preserve `CalendarService`, `CalendarServicing`, `CalendarEvent`, and persisted calendar identifiers unchanged.
- Keep Calendar and Internet Accounts navigation separate because they resolve different failure states.
- Keep new buttons on the existing `.parakeetAction(...)` styling path and preserve accessibility labels and hints.
- Prevent an initial “No calendars found” flash by representing loading separately from a completed empty lookup.
- Guard asynchronous reload completion against permission changes before applying the result.

### Risks and Dependencies

- **System Settings deep-link drift:** Pane identifiers can vary across macOS releases. Multiple known candidates plus a generic System Settings fallback prevent a dead action, while persistent written instructions cover misrouting; runtime verification is limited to the current development Mac.
- **Overclaiming Outlook support:** Outlook is a client that can hold non-Exchange or local-only data. Copy must name Microsoft 365/Exchange through macOS Calendar rather than promise every Outlook calendar.
- **Stale async state:** Account and permission changes can overlap a reload. The UI must not apply a visible-calendar result after Calendar permission is no longer granted.
- **External synchronization:** EventKit exposes the Mac's synchronized state; Refresh Calendars cannot force an Exchange server sync and should not claim to do so.

### System-Wide Impact

- **Privacy:** No new network request, credential, token, telemetry field, persisted calendar data, or account identifier is introduced.
- **App lifecycle:** The Settings app-active handler additionally refreshes Calendar permission, and the calendar subsection reloads its visible list when active.
- **Documentation:** Public and architectural docs gain the same provider boundary so support guidance does not drift from the product.
- **Release evidence:** Automated and review evidence can establish code correctness; physical Microsoft 365 behavior remains explicitly unverified in this environment.

---

## Implementation Units

### U1. Add account setup and refresh UX

- **Goal:** Make Microsoft calendar setup and visible-calendar recovery actionable from Calendar settings.
- **Requirements:** R2-R6; covers F1-F3 and AE1-AE3.
- **Dependencies:** None.
- **Files:**
  - `Sources/MacParakeet/Views/Settings/CalendarSettingsView.swift`
  - `Sources/MacParakeetViewModels/SettingsViewModel.swift`
  - `Sources/MacParakeet/Views/Settings/SettingsView.swift`
  - `Tests/MacParakeetTests/ViewModels/SettingsViewModelTests.swift`
  - `Tests/MacParakeetTests/Calendar/MockCalendarService.swift`
- **Approach:**
  1. Add accurate Microsoft 365/Exchange-through-macOS guidance to the calendar connection surface.
  2. Put loading/completed state and visible calendars in the existing `SettingsViewModel`, inject the existing `CalendarServicing` boundary, and keep the view declarative instead of adding another state object.
  3. Keep Microsoft guidance, Manage Accounts, and Refresh outside the auto-start-only controls so they remain available when the mode is off and in both empty and populated states.
  4. Open Internet Accounts through a small injected URL opener, with ordered current/legacy pane candidates and a generic System Settings fallback.
  5. Route initial appearance, app activation, permission changes, and explicit refresh through the KTD3 operation; invalidate older in-flight results and clear calendars as soon as access is absent.
- **Patterns to follow:** Existing Calendar permission recovery and notification-settings URL candidates in `SettingsViewModel`; `NSApplication.didBecomeActiveNotification` handling in `SettingsView`; `.parakeetAction(...)` buttons in Settings views.
- **Test scenarios:**
  - Covers AE1. Initial loading does not render a completed empty diagnosis; a completed empty result exposes both account-management and refresh recovery.
  - Covers AE2. A populated list retains the existing per-calendar selection controls and keeps account management discoverable.
  - Covers AE3. Denied permission retains the Calendar privacy recovery action and does not use Internet Accounts as its replacement.
  - A reload that completes after permission is revoked does not install stale calendars in the view.
  - Two overlapping reloads can only apply the newer result.
  - A denied-to-granted permission transition loads the visible calendars without changing auto-start or exclusion preferences.
  - Returning from System Settings triggers permission and visible-calendar refresh without restarting MacParakeet.
  - Internet Accounts URL candidates are attempted in order, stop after success, and fall back to generic System Settings when none resolves.
- **Verification:** The Settings view builds with Swift 6 concurrency checks, existing calendar-focused tests remain green, and manual source inspection confirms every permission/load state has one accurate recovery action.

### U2. Add Outlook discovery terms

- **Goal:** Let users find the existing calendar integration using Microsoft vocabulary and understand the setup path from Meetings.
- **Requirements:** R2, R7; covers F1 and AE4.
- **Dependencies:** U1.
- **Files:**
  - `Sources/MacParakeetViewModels/SettingsSearchIndex.swift`
  - `Tests/MacParakeetTests/ViewModels/SettingsSearchIndexTests.swift`
  - `Sources/MacParakeet/Views/Meetings/MeetingsView.swift`
- **Approach:** Add Outlook, Microsoft 365, Exchange, and Internet Accounts search synonyms, and revise the Meetings connection description without diagnosing an empty event list as a missing account.
- **Patterns to follow:** The feature-flag-aware `meeting.calendar` search entry and the existing Meetings-to-Settings navigation.
- **Test scenarios:**
  - Covers AE4. Each Microsoft term returns `meeting.calendar` when the calendar feature is enabled.
  - The same terms do not reveal the calendar row when the feature flag disables it.
  - Existing generic calendar and auto-start queries continue to return the same destination.
- **Verification:** Focused Settings search tests pass and the Meetings view builds without changing calendar fetch or filter behavior.

### U3. Align public and governing documentation

- **Goal:** Make the supported setup path and evidence boundary consistent across user and architecture documentation.
- **Requirements:** R1-R2, R8; implements KTD5.
- **Dependencies:** U1-U2.
- **Files:**
  - `README.md`
  - `spec/README.md`
  - `spec/adr/017-calendar-meeting-auto-start.md`
  - `docs/research/2026-09-13-issues-502-1013-outlook-calendar.md`
- **Approach:** Document Microsoft 365/Exchange support through macOS Internet Accounts, the lack of a MacParakeet Microsoft sign-in, the in-product recovery path, and the absence of physical Microsoft-account certification in this environment.
- **Patterns to follow:** Release-state language in `README.md` and `spec/README.md`; amendment-style decision history in ADR-017.
- **Test scenarios:** Test expectation: none -- these files document the implemented behavior and its verification boundary without changing runtime behavior.
- **Verification:** Documentation agrees with the final code, does not claim Graph/OAuth or universal Outlook coverage, and distinguishes development-source behavior from the stable DMG.

### U4. Run the branch quality gate

- **Goal:** Verify the exact implementation state and converge independent review before publication.
- **Requirements:** R1-R8.
- **Dependencies:** U1-U3.
- **Files:** All task-owned files from U1-U3 plus this plan.
- **Approach:** Run focused tests during implementation, lint changed Swift files, build, then let the repository's no-mistakes gate own the single final full `swift test` run when available (otherwise run it once directly). Finish with exact-diff independent review before opening the PR; repository-wide formatter output is advisory unless a changed Swift file is implicated.
- **Patterns to follow:** `docs/pr-review-workflow.md`, `.no-mistakes.yaml`, and `AGENTS.md` completion rules.
- **Test scenarios:**
  - Existing Calendar service, meeting monitor, link parser, coordinator, and Settings search tests remain green.
  - The app and CLI compile under Swift 6 with no public calendar contract change.
  - Review confirms the diff introduces no new calendar network path, persistence, provider abstraction, or misleading runtime claim.
- **Verification:** The exact commit intended for push has passing required gates, review findings are resolved or documented, and the PR body records the missing physical Microsoft-account test.

---

## Verification Contract

| Gate | Scope | Done signal |
|---|---|---|
| Focused Settings search tests | `SettingsSearchIndexTests` | Microsoft synonyms route to the gated Calendar destination and existing queries stay green. |
| Focused Calendar tests | Calendar service consumers, monitor, parser, and coordinator | Existing provider-neutral behavior remains unchanged. |
| Swift build | App, core, view-model, and CLI targets | The branch compiles cleanly under Swift 6 concurrency checks. |
| Swift format lint | All changed Swift files | No formatting violations. |
| Full test suite / no-mistakes | Exact final branch state | No-mistakes owns the single final `swift test` run when available; otherwise `swift test` passes once directly. |
| Current-macOS navigation smoke | Development Mac without a Microsoft account | Manage Accounts reaches Internet Accounts (or generic Settings with the written path still visible), denied Calendar permission reaches Privacy & Security > Calendars, and returning refreshes Calendar state. |
| Independent review | Exact committed diff against `origin/main` | Valid findings are fixed, remaining limitations are explicit, and the PR is ready for hosted CI/review. |
| Physical Microsoft calendar smoke test | Microsoft 365/Exchange account and oldest supported macOS | Deferred by KTD5; absence blocks runtime-certification claims, not PR creation. |

---

## Definition of Done

- U1-U3 satisfy their stated requirements and verification outcomes without changing the provider-neutral EventKit data path.
- The loaded-empty, populated, denied-permission, app-reactivation, and explicit-refresh states are represented accurately.
- Settings search recognizes Outlook, Microsoft 365, Exchange, and Internet Accounts without bypassing the feature flag.
- README, spec index, ADR-017, research findings, and PR description agree on setup, privacy, and verification boundaries.
- Focused checks, changed-file formatting, build, one final full `swift test` (owned by no-mistakes when available), current-macOS navigation smoke testing, and independent exact-diff review pass for the final commit.
- The PR references issues #502 and #1013 and does not claim physical Microsoft 365, shared-calendar, or oldest-supported-macOS certification.
- Dead-end experiments and unused abstractions are absent from the diff; unrelated work remains untouched.
