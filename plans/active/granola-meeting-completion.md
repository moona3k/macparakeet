# Granola-style Meeting Recording Completion

**Status:** Active (Ask half shipped 2026-04-24; Calendar half remaining)
**Date:** 2026-04-19 · Updated 2026-04-24
**ADRs:** ADR-017 (calendar auto-start), ADR-018 (live Ask tab — Insights dropped per amendment)
**Blocks:** GitHub #57 "meeting recording v0.6" final closeout

## What this plan closes out

ADR-014 shipped the bones of meeting recording. ADR-015 let it run alongside dictation. ADR-016 centralized STT ownership. What's left before we call this feature *done*:

1. **Calendar-driven auto-start** (ADR-017) — users forget to press record; the calendar already knows their meetings
2. ~~**Live Insights tab** (ADR-018)~~ — **dropped** in the ADR-018 amendment of 2026-04-24. Pull-on-demand Ask pills replace the "glance view" use case at zero idle LLM cost. See `spec/adr/018-live-meeting-insights-and-ask.md` § Amendment.
3. **Live Ask tab** (ADR-018) — ✅ shipped 2026-04-24. Mid-meeting chat against the rolling transcript with thinking-partner pills.
4. **Onboarding + settings surface** for the calendar half.

This plan is the file-by-file breakdown. It is sequenced in phases so each phase is an independently shippable slice; nothing is a big-bang.

## Scope boundaries

### In scope
- Calendar EventKit integration, polling coordinator, reminder + auto-start + auto-stop
- Port `CalendarService` / `MeetingMonitor` / `MeetingLinkParser` from `oatmeal` repo
- ~~Add tabs to `MeetingRecordingPanelView`: Transcript / Insights / Ask~~ → shipped as **Transcript / Ask** (two tabs)
- ~~New `MeetingLiveInsightsService` actor + viewmodel + pane~~ → dropped per ADR-018 amendment
- Reuse `TranscriptChatViewModel` in the panel; add live-→-persisted promotion helper — ✅ shipped
- Settings UI (Calendar section) + onboarding step
- Telemetry cases + website allowlist mirror

### Out of scope
- Cross-meeting RAG, entity extraction, person graph (Oatmeal territory)
- Custom live prompts (lives on the post-meeting Results tab via ADR-013)
- ScreenCaptureKit / per-app audio isolation (ADR-014 locked Core Audio Taps)
- Late-join UI for meetings already in progress (enum case exists, UI deferred)
- Non-English starter / follow-up pill copy
- Auto-refreshing Insights pane (dropped per ADR-018 amendment 2026-04-24)
- LLM-generated follow-up suggestions per response (curated static set won — see ADR-018 Rationale)
- Transcription-failure chat recovery via JSON sidecar (Future Work in ADR-018 — defer until telemetry justifies)

### Invariants
- Dictation continues to work unchanged, concurrently (ADR-015)
- Users without an LLM provider see no regression — recording still works end-to-end
- No new SQLite tables; reuse `prompt_results` and `chat_conversations`
- Local-first posture preserved — EventKit reads are on-device only
- STT scheduler (ADR-016) is untouched; LLM calls do not go through it

## Phased rollout

### Phase A — Tab shell in the live panel ✅ shipped 2026-04-24 (commit `e574135a`)

Tab bar inserted between header and pane content (`Transcript` default, `Ask`). Per the ADR-018 amendment the panel is **two-tab**, not three. Implementation diverged from the original plan in two ways:
- Tab bar built inline in `MeetingRecordingPanelView.swift` rather than as a separate `LivePanelTabBar.swift` file (inline was 30 lines; extracting would have been overengineering).
- The transcript body was kept inline in `MeetingRecordingPanelView.swift` rather than extracted into `LiveTranscriptPaneView.swift` for the same reason.

Files actually touched:
- `Sources/MacParakeetViewModels/MeetingRecordingPanelViewModel.swift` — added `LivePanelTab` enum, `selectedTab`, composed `chatViewModel`, `chatTranscript` projection.
- `Sources/MacParakeet/Views/MeetingRecording/MeetingRecordingPanelView.swift` — inline tab bar + `paneContent` switch.

### Phase B — Live Insights service + pane ❌ dropped 2026-04-24

Removed per the ADR-018 amendment of 2026-04-24. Auto-refreshing four-section insights with debounce policy and section-parsing was out of step with the "thinking partner, not stenographer" framing the design landed on. Pull-on-demand pills in the Ask tab cover the same use cases (Summarize / What did I miss? / Action items) at zero idle LLM cost. See `spec/adr/018-live-meeting-insights-and-ask.md` § Amendment for full rationale.

The original Phase B plan content is preserved in git history (this plan, pre-2026-04-24).

### ~~Phase B-old — Live Insights service + pane~~ (DROPPED, see above)

Introduces the `MeetingLiveInsightsService` actor, the viewmodel, and the rendered pane. Finalization wiring included.

| File | Change |
|------|--------|
| `Sources/MacParakeetCore/MeetingRecording/MeetingLiveInsightsService.swift` *(new)* | Actor. Debounce (25s minimum interval, 50-word delta, 45s first-run floor). Uses `LLMService.generatePromptResultStream(transcript:systemPrompt:)`. Emits `AsyncStream<MeetingInsightsSnapshot>`. Exposes `update(...)`, `refreshNow()`, `finalize() async -> MeetingInsights`. |
| `Sources/MacParakeetCore/MeetingRecording/MeetingInsights.swift` *(new)* | `MeetingInsights` (four optional section strings), `MeetingInsightsSnapshot`, parsing from the LLM response. |
| `Sources/MacParakeetCore/MeetingRecording/MeetingInsightsPrompt.swift` *(new)* | Static built-in system prompt (returns fixed markdown sections). |
| `Sources/MacParakeetViewModels/MeetingInsightsViewModel.swift` *(new)* | `@MainActor @Observable`. Subscribes to service. Exposes `snapshot`, `isRefreshing`, `hasLLM`, `providerDisplayName`, `refresh()`. |
| `Sources/MacParakeetViewModels/MeetingRecordingPanelViewModel.swift` | Compose `insightsViewModel`. Expose to panel view. |
(See above — original Phase B content lives in git history.)

### Phase C — Live Ask ✅ shipped 2026-04-24 (commit `e574135a` + polish `80317e70`)

What landed:

- `TranscriptChatViewModel` extended with in-memory live mode in `sendMessage(richPrompt:)` (skip ChatConversation creation when both `transcriptionId` and `conversationRepo` are nil), `updateTranscriptText(_:)` (set transcript without clearing history), `bindPersistedConversation(transcriptionId:transcriptionRepo:conversationRepo:)` (promote in-memory thread at finalize). Optional `richPrompt` parameter so pills can ship a comprehensive instruction while the bubble shows the short label.
- `MeetingRecordingPanelViewModel` composes `chatViewModel: TranscriptChatViewModel`, exposes a clean `chatTranscript` projection (no bracketed timestamps), pushes it to the chat VM on every `updatePreviewLines(...)` tick.
- `LiveAskPaneView` (new) — scrollable thread, vertical "Quick prompts" stack of 6 starter pills in the empty state, horizontal-scroll row of 8 follow-up pills above the input once messages exist, polished input bar (14pt corners, hairline border), `TypingIndicator` (three accent dots, 1.4s wave), no-LLM empty state with Settings CTA. `LiveAskPrompt(label:prompt:)` model carries both the bubble label and the LLM-side prompt for every pill.
- Pills (English-first, hardcoded):
  - **Starters** (6): Summarize so far · What did I miss? · What question is worth asking? · What's worth pushing back on? · Where are we going in circles? · What's unresolved?
  - **Follow-ups** (8): Tell me more · Summarize so far · What did I miss? · Why? · Give an example · Counter-argument? · Action items? · TL;DR
- `MeetingRecordingFlowCoordinator` — accepts `transcriptionRepo`, `conversationRepo`, `configStore`, `cliConfigStore`, `llmService?` at init. Configures the panel's chatViewModel for in-memory live mode at `.showRecordingPill`. Calls `bindPersistedConversation(...)` at `.navigateToTranscription` so the live thread carries onto `TranscriptResultView`'s Chat tab. New `updateLLMService(_:)` forwards provider changes from `AppEnvironmentConfigurer.refreshLLMAvailability(in:)`.
- Convenience polish: auto-focus on Ask tab appearance (~100ms delay), `.onKeyPress(.escape)` cancels in-flight responses, `Cmd+1` / `Cmd+2` switch tabs, footer (Copy/Auto-scroll/Stop) hidden on Ask tab, input field stays enabled while streaming so focus survives Enter.

What was deferred:

- **Telemetry events** (`.meetingLiveAskUsed(provider:messageCount:)` and the website allowlist mirror) — not shipped in this pass; add later if usage data is needed.
- **Dedicated `TranscriptChatViewModelLivePersistenceTests.swift`** — not added; the existing 40-test `TranscriptChatViewModelTests` suite still passes and exercises the shared chat-VM surface. Add focused live-mode tests when we touch this surface again.
- **Transcription-failure chat recovery** (JSON sidecar) — Future Work in ADR-018 § Future Work.

### Phase D — Calendar auto-start: notify-only (ADR-017 phase 1) ✅ shipped 2026-04-25

Ported the four core files from Oatmeal (`MeetingMonitor`, `MeetingLinkParser`, `CalendarService`, `CalendarEvent` — GRDB stripped per ADR-017 §6), wired a notify-only `MeetingAutoStartCoordinator` with adaptive 60s/15s/5s polling + `.EKEventStoreChanged` observer + daily stale-id cleanup. Settings card (mode/lead/filter/per-calendar checkboxes/permission CTA) and skippable onboarding step both shipped. CLI surface (`macparakeet-cli calendar upcoming` + `health` extension) shipped alongside for headless verification by AI agents and CI. **Amendment:** the per-calendar include list (originally Phase 3) landed in Phase D — only ~30 lines and made onboarding feel finished.

**Original plan (kept for reference):**

| File | Change |
|------|--------|
| `Sources/MacParakeetCore/Calendar/CalendarService.swift` *(new, ported)* | EventKit wrapper. Permission check + request, `fetchUpcomingEvents(withinDays:)`, `availableCalendars()`. Strip Oatmeal's telemetry category prefixes. |
| `Sources/MacParakeetCore/Calendar/CalendarEvent.swift` *(new, ported)* | `CalendarEvent`, `EventParticipant`, `CalendarInfo` — plain `Sendable` structs, no GRDB. |
| `Sources/MacParakeetCore/Calendar/MeetingLinkParser.swift` *(new, ported verbatim)* | Zoom/Meet/Teams/Webex/Around regex extractor. |
| `Sources/MacParakeetCore/Calendar/MeetingMonitor.swift` *(new, ported verbatim)* | Pure state machine: `evaluate(events, now, config, activeRecording, dismissedIds, remindedIds, countdownShownIds) -> [MonitorEvent]`. |
| `Sources/MacParakeetCore/Calendar/CalendarAutoStartMode.swift` *(new)* | `.off` / `.notify` / `.autoStart`. |
| `Sources/MacParakeetCore/Calendar/MeetingTriggerFilter.swift` *(new)* | `.withLink` / `.withParticipants` / `.allEvents`. |
| `Sources/MacParakeetViewModels/SettingsViewModel.swift` | New properties: `calendarAutoStartMode`, `calendarReminderMinutes`, `meetingTriggerFilter`, `calendarAutoStopEnabled`, `calendarIncludedIdentifiers: Set<String>`. Persist via `UserDefaults` under a `CalendarAutoStart.*` namespace. `didSet` posts a new notification. |
| `Sources/MacParakeetCore/AppNotifications.swift` | Add `macParakeetCalendarSettingsDidChange`. |
| `Sources/MacParakeet/App/MeetingAutoStartCoordinator.swift` *(new)* | `@MainActor` class. 60s poll (5s near events). Subscribes to `.EKEventStoreChanged`. Calls `MeetingMonitor.evaluate`, fires `UNUserNotificationCenter` notifications for `.reminderDue`. Does **not** start recordings in this phase. Owned by `AppDelegate`, configured in `AppEnvironmentConfigurer`, observed via `AppSettingsObserverCoordinator`. |
| `Sources/MacParakeet/Views/Settings/CalendarSettingsView.swift` *(new)* | Mode picker + reminder lead time picker + trigger filter picker + per-calendar checkboxes + permission CTA. |
| `Sources/MacParakeet/Views/Settings/SettingsView.swift` | Mount `CalendarSettingsView` as a new section. |
| `Sources/MacParakeet/Views/Onboarding/OnboardingCalendarView.swift` *(new)* | Explainer + "Grant Calendar access" button + "Skip" button. Sets `calendarAutoStartMode = .off` on skip. |
| `Sources/MacParakeet/Views/Onboarding/OnboardingFlowView.swift` | Slot the new step after permissions, before model download. |
| `Sources/MacParakeetCore/Services/TelemetryEvent.swift` | Add `.calendarPermissionGranted`, `.calendarPermissionDenied`, `.settingChanged(.calendarAutoStartMode)` etc. |
| `../macparakeet-website/functions/api/telemetry.ts` | Mirror all new event names. |
| `Tests/MacParakeetTests/Calendar/MeetingMonitorTests.swift` *(new)* | Ported from Oatmeal if available; otherwise write: reminder fires exactly once per event, auto-start window is T±30s, dismissed ids suppress further events, trigger filter correctness. |
| `Tests/MacParakeetTests/Calendar/MeetingLinkParserTests.swift` *(new)* | Zoom/Meet/Teams URL extraction from location/notes/url fields. |

**Ship criteria:** User grants Calendar permission through onboarding or Settings. At T-5min of a calendar event with a video link, a macOS notification appears. `.autoStart` mode is exposed in the UI but is a no-op (shows a "Coming soon" hint if selected, or clamp the picker to not expose it yet — plan says clamp).

### Phase E — Calendar auto-start: countdown + auto-stop (ADR-017 phase 2) ✅ shipped 2026-04-25

Built `MeetingCountdownToastController` (5s pre-meeting + 30s end-of-meeting countdowns, `KeylessPanel` non-activating top-center floating panel with progress bar + Cancel/Start Now actions). Coordinator wires `.autoStartDue` → countdown → `MeetingRecordingFlowCoordinator.startFromCalendar()` and `.autoStopDue` (only for auto-started recordings) → countdown → `toggleRecording()`. Tracks `autoStartedEventId` binding; manual-stop detection via next-poll `isRecordingActive() == false` with binding still held. Settings Picker unclamped to all three modes; auto-stop toggle visible when mode == `.autoStart`. `CalendarServicing` protocol + `MockCalendarService` extracted; 8 new `MeetingAutoStartCoordinatorTests` cover routing, lifecycle, and the binding state machine. Four new telemetry events allowlisted on the website worker (`calendar_auto_start_triggered`, `calendar_auto_start_cancelled`, `calendar_auto_stop_shown`, `calendar_auto_stop_cancelled`); `meeting_recording_started` gained optional `trigger` prop.

**Original plan (kept for reference):**

Add the countdown toast and the actual recording triggers.

| File | Change |
|------|--------|
| `Sources/MacParakeet/Views/MeetingRecording/MeetingCountdownToastController.swift` *(new)* | `NSPanel` subclass via `KeylessPanel`. 5-second countdown with cancel button. Public `show(title:subtitle:onConfirm:onCancel:)`. |
| `Sources/MacParakeet/Views/MeetingRecording/MeetingCountdownToastView.swift` *(new)* | SwiftUI view for the toast body. Fills a progress bar over 5s. |
| `Sources/MacParakeet/App/MeetingAutoStartCoordinator.swift` | Handle `.autoStartDue` → show countdown toast → on confirm, call `MeetingRecordingFlowCoordinator.startRecording(triggeredBy: .calendar(event))`. Handle `.autoStopDue` → show "meeting ending" toast → on confirm, call `stopRecording()`. Respect `activeRecording` — do not fire a second start if manual start already took. |
| `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` | Accept an optional `triggeredBy: MeetingRecordingTrigger` parameter (`.manual` / `.hotkey` / `.calendar(CalendarEvent)`). Stash it on the session so title defaults use the calendar event title. |
| `Sources/MacParakeet/Views/Settings/CalendarSettingsView.swift` | Unclamp `.autoStart` option and expose the auto-stop toggle. |
| `Sources/MacParakeetCore/Services/TelemetryEvent.swift` | Add `.calendarAutoStartTriggered(mode:)`, `.calendarAutoStartCancelled(reason:)`, `.meetingRecordingStarted(trigger:)` (if not already present). |
| `../macparakeet-website/functions/api/telemetry.ts` | Mirror. |
| `Tests/MacParakeetTests/App/MeetingAutoStartCoordinatorTests.swift` *(new)* | Countdown countdown-cancel does not start recording. Active recording suppresses subsequent `.autoStartDue` for the same event. Auto-stop confirmation stops an active recording. |

**Ship criteria:** End-to-end: calendar event at T-5min fires notification; at T-0 shows a 5s cancellable toast; on confirm (or timeout) starts meeting recording; at event-end shows auto-stop toast; on confirm stops recording and runs the normal finalize pipeline.

### Phase F — Copy polish, naming unification, changelog

Low-value-per-unit cleanup that's better done in one pass.

| File | Change |
|------|--------|
| All calendar-related copy | Unify on "Auto-record" (not "Auto-start") or vice versa — pick and grep. |
| `README.md`, `CLAUDE.md`, `spec/02-features.md`, `spec/README.md` | Update test counts, mark meeting recording as shipped, add calendar section to feature list. |
| `docs/commit-guidelines.md` | No change. |
| `CHANGELOG` (website release notes) | v0.6.x bullet points for each phase that shipped. |

## Testing matrix

- `swift test` baseline before each phase; all green after.
- Manual smoke per phase in the ship criteria above.
- Calendar smoke requires a test calendar with a Zoom-link event 5 minutes out; confirm notification, then confirm auto-start with countdown.
- No-LLM-key smoke: verify the Ask tab shows the empty-state CTA and recording still works.

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Calendar poll fires during sleep | Low | Low | EventKit reads on wake are cheap; `.EKEventStoreChanged` catches missed changes |
| Oatmeal ports drift | Low | Low | No shared packaging; local copies can evolve |
| User denies Calendar permission mid-onboarding then can't find it | Low | Medium | Permission CTA in `CalendarSettingsView` handles denied state with deep-link to System Settings |
| Auto-start fires for a declined event | Medium | Low | Trigger filter defaults to `.withLink`; countdown toast is a 5-second safety valve |
| Live Ask chat lost on transcription failure | Low | Medium | Future Work in ADR-018 § Future Work — JSON sidecar persistence sketched, deferred until telemetry justifies |

## Timeline estimate (revised)

- Phase A (tab shell) — ✅ shipped 2026-04-24
- ~~Phase B (Insights)~~ — dropped per ADR-018 amendment
- Phase C (Live Ask) — ✅ shipped 2026-04-24
- Phase D (Calendar notify-only) — ✅ shipped 2026-04-25
- Phase E (Calendar countdown + auto-stop) — ✅ shipped 2026-04-25
- Phase F (Polish, naming, changelog) — 0.5 day remaining

Total remaining: ~0.5 engineering days for Phase F polish.

## Changelog line (when all phases land)

> **Meeting Recording (completed):** Meetings now open with live Transcript and Ask tabs so you can chat with the rolling transcript and use one-tap thinking-partner pills ("What did I miss?", "What's worth pushing back on?", "Action items?") without leaving the panel. Calendar-driven auto-start can remind you before a meeting begins and (optionally) start recording for you. Works with Zoom, Google Meet, Microsoft Teams, and Webex links on your macOS calendar.
