# GUI, onboarding, and interaction audit

Audit date: 2026-10-02. Baseline: `f43f4bed2`. This report evaluates implementation and available verification; it does not claim that every screen, permission prompt, audio route, or assistive technology was exercised.

## Assessment

The app has a substantial working interaction model: real dictation practice, recoverable model setup, SQL-backed paginated Library, transcript corrections shared with export, explicit bulk deletion confirmation, contextual meeting permissions, and tested lazy rendering for long transcripts. A redesign from scratch would discard useful work. The strongest opportunities are closing stale-state races, finishing keyboard access, making setup readiness honest and consistent across engines, and qualifying a small set of complete native journeys.

The most concrete correctness issue found in this slice is an older Library query overwriting a subsequent favorite or deletion. The most consequential setup architecture issue is that Parakeet and locale-selected Whisper do not share the same download lifetime and stall-recovery behavior. Native rendering also confirmed that recoverable setup failure overlapped the hotkey-phase card heading and cropped its buttons against the footer. Narrow fixes for the Library race and setup layout are included in this audit branch; the remaining recommendations are explicitly outstanding.

Production personal app state was not inspected. Native evidence is limited to synthetic data rendered by the actual SwiftUI onboarding views in an offscreen `NSHostingView`. No real microphone, Accessibility prompt, screen recording, model download, paste into another application, or VoiceOver session is implied by such rendering.

## Findings

### [GUI-01] Reject stale Library query results after mutations

- **Type / priority:** Confirmed source defect; P1 correctness.
- **Trigger:** A refresh has already read its database snapshot, then the user favorites a visible recording, deletes it, or deletes its retained meeting audio before that query publishes.
- **Evidence:** `Sources/MacParakeetViewModels/TranscriptionLibraryViewModel.swift:394` updates favorites without invalidating the load generation; `:626` and `:642` do the same for item/audio deletion. `:824` launches the detached query and `:829-838` publishes its snapshot if generation still matches. `Sources/MacParakeet/Views/Transcription/TranscriptionLibraryView.swift:143` retains existing rows while loading; their actions remain available. The same view model already handles stale reads for rename at `:675-682` and retry refresh at `:760-764`.
- **Impact:** A removed row can reappear, a favorite can visibly revert although persisted correctly, and deleted audio can regain a misleading playback affordance. During pagination, deleting a preceding row can also shift the next offset and skip a recording.
- **Effort:** S, including deterministic tests.
- **Risk:** MED. Invalidating a query must preserve the user's requested page window and current filters rather than silently discard a pending Load More action.
- **Confidence:** HIGH. The five-case paused-snapshot fixture produced four failing tests / six failed assertions on baseline. The favorite-pagination case passed as a control; it remains covered to prevent a fix from discarding pending pagination.
- **Fix sketch:** On successful mutation, invalidate an active query and refresh its requested window using the current query. Preserve the existing cheap idle mutation path. Keep database persistence and visible state assertions separate.
- **Change included:** Single-item mutations now invalidate an active older snapshot and reload its requested window; completed idle paths retain their existing behavior. Refresh failure is reported separately from successful persistence. The fixed focused Library suite passed all 71 tests, including the five new regression cases.
- **PR review follow-up:** [PR #1205 review](https://github.com/moona3k/macparakeet/pull/1205) identified that the initial repair performed its replacement query synchronously on the main actor. Five added thread assertions reproduced that concern. The replacement now reuses the existing asynchronous `loadPage` path with the full requested window, cancellation and generation checks. Successful mutations publish immediately; a failed replacement retains the updated rows, selection, pagination and displayed source attribution. All 74 focused Library tests pass, including deterministic checks for superseded results/errors during filter changes and preserved state after replacement failure. This proves thread ownership and state ordering, not a measured latency improvement.

### Landing review: bulk mutations and GUI completion ownership

The same pending-query defect also affected bulk recording deletion and bulk
audio detachment. Five additional regressions produced three failed cases/five
assertions before the repair; the two audio-pagination controls already passed.
Bulk success now uses the same generation-checked asynchronous replacement,
retains the requested window, and preserves failed-item selection and both
operation/refresh error messages when partial failures coincide.

A separate GUI retranscription defect remained in `TranscriptionViewModel`:
a second metadata-preserving save after Core's completion could overwrite a
transcript correction made after that commit. A real Core/SQLite fixture
reproduced the lost corrected text and edit marker (one of two cases failed,
two assertions). Concurrent notes/chat/audio metadata controls across four
source types passed before the fix; those fields were already protected by
the GUI's metadata merge. The repair removes the second GUI save and publishes
Core's committed result. It protects database durability; it does not promise
that the current view automatically reflects a later external correction.

Final focused verification passes 264 cases: 80 Library, 166 transcription
view-model, 16 batch and two real Core/SQLite GUI cases. Audio/STT are injected
in these persistence tests; the meeting fixture exercises canonical mixed-audio
fallback. This is separate from physical capture qualification.

### [GUI-02] Give failed onboarding setup enough room before key confirmation

- **Type / priority:** Confirmed native-render layout defect; P2 recovery quality.
- **Trigger:** Model preflight or download fails while Try It still shows the full key rehearsal card.
- **Evidence:** `Sources/MacParakeet/Views/Onboarding/OnboardingPracticeStepView.swift:241-242` assigns every box a 76-point height in the hotkey phase. The `.failed` case at `:285-286` renders `failureContent`, whose `:415-441` includes a heading, up to two error lines, two recovery tips, and Retry / Open Settings controls. The larger failure height at `:269-272` is only selected after the dictation phase begins.
- **Impact:** The actual rendered failure overlaps the second card's heading, truncates error text, and crops its recovery buttons against the footer. A user who has not yet confirmed a working hotkey needs this retry guidance most.
- **Effort:** S.
- **Risk:** LOW. Select an appropriate failure height in both phases or let the failure card size to content; the enclosing onboarding content already scrolls.
- **Confidence:** HIGH. [Baseline native render](evidence/gui-onboarding/before/03-offline-hotkey-phase.png) shows the overlap and cropped controls; [the dictation-phase control](evidence/gui-onboarding/before/04-offline-dictation-phase.png) shows the same error content without that compression.
- **Fix sketch:** Measure/render the actual failed view at 760 × 600 in both practice phases. Give failure content intrinsic height and ensure Retry remains reachable even when error text wraps.
- **Change included:** Failure content now uses intrinsic vertical height in both practice phases. [The fixed hotkey phase](evidence/gui-onboarding/after/03-offline-hotkey-phase.png) has a separate heading and readable wrapped error text. [The fixed dictation phase](evidence/gui-onboarding/after/04-offline-dictation-phase.png) exposes both recovery buttons. The hotkey-phase card extends below the initial viewport; [the hosted scroll proof](evidence/gui-onboarding/after/03b-offline-hotkey-phase-scrolled.png) verifies both buttons become fully visible. Other box states retain their compact/expanded fixed sizes.

### [GUI-03] Make Whisper setup survive the promised Skip / Finish path

- **Type / priority:** Confirmed ownership asymmetry; P1 follow-up, runtime dependency cancellation outcome still needs qualification.
- **Trigger:** A user whose preferred languages select Whisper finishes or closes onboarding while the initial Whisper download is still running.
- **Evidence:** `Sources/MacParakeetViewModels/OnboardingViewModel.swift:862-921` owns the Whisper download inside `warmUpObserverTask`; `:881-885` directly awaits it. `:1186-1205` cancels that task on observation shutdown, called by `Sources/MacParakeet/Onboarding/OnboardingWindowController.swift:173`. In contrast, Parakeet calls shared `backgroundWarmUp()` at `OnboardingViewModel.swift:795`. `spec/adr/005-onboarding-first-run.md`, September 23 amendment, promises the background download continues after Skip / Finish. `OnboardingFlowView.swift:711-717` tells users dictation will work once the download finishes.
- **Impact:** A cancellation-aware Whisper downloader stops when the onboarding window closes; the promise of completing setup in the background is not engine-independent. English and CJK first-use behavior diverges at a sensitive moment.
- **Effort:** M.
- **Risk:** MED. A persistent setup task must retain correct engine selection and user intent while allowing explicit cancellation/retry; simply detaching the current task risks stale writes.
- **Confidence:** HIGH for task ownership and contract drift; MED for the exact installed WhisperKit cancellation symptom without real download qualification.
- **Fix sketch:** Give model preparation a service-owned operation lifetime, distinct from window observation, or explicitly change the UI contract and recovery behavior. Test a controlled cancellation-aware downloader, close/finish while blocked, then verify whether completion and language/engine selection still occur.

### [GUI-04] Apply stall recovery to locale-selected Whisper setup

- **Type / priority:** Confirmed missing recovery mechanism; P2.
- **Trigger:** Whisper download or engine activation makes no progress and does not return an error.
- **Evidence:** The Parakeet branch installs/resets its watchdog at `OnboardingViewModel.swift:746` and `:815`; `:1251-1277` transitions stalled setup to actionable failure. The Whisper branch at `:862-921`, downloader at `:924-1012`, and activation at `:1015-1071` have no equivalent watchdog reset/ownership token.
- **Impact:** Whisper users can remain in a loading state indefinitely while Parakeet users receive Retry. Skip avoids trapping the entire app, but does not repair the speech route.
- **Effort:** M; best addressed with GUI-03.
- **Risk:** MED. A timeout must observe real progress and avoid cancelling a healthy slow model compilation.
- **Confidence:** HIGH for absence of the existing watchdog in this branch; stall frequency is unmeasured.
- **Fix sketch:** Use the same operation-state and progress deadline policy for both branches, with separate network download and compilation bounds if evidence warrants them. Add fake downloader/switcher tests that intentionally stop producing progress.

### [GUI-05] Restore keyboard and assistive access to transcript actions

- **Type / priority:** Confirmed source-level interaction gaps; P2 accessibility.
- **Trigger:** A user navigates without a pointer and wants to seek by transcript timestamp, select a prompt, or switch/delete a saved chat conversation.
- **Evidence:** `Sources/MacParakeet/Views/Transcription/TranscriptTimestampedContentView.swift:1076-1114` implements `TranscriptTimestampChip` as `Text.onTapGesture` with no button, focus handling, or named accessibility action. A separate semantic Play from here button exists at `:990-991`, but its containing controls are invisible and non-hittable until pointer hover at `:921-925`; actual AX reachability of that alternative remains untested. `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift:3940-3980` implements prompt selection as a gesture-only capsule. `:4192-4238` implements chat selection as a gesture-only row and creates its unlabeled trash button only while hovered. By comparison `:3321-3330` explicitly supplies accessibility actions/traits for the result tabs and documents why tap gestures alone are insufficient. `spec/04-ui-patterns.md:1849` requires keyboard navigation and named interactive elements.
- **Impact:** Visible transcript, prompt, and chat affordances depend on pointer hover/click. Alternative hidden actions mean this is not proof that every operation is impossible through AX; it is a concrete inconsistency that needs keyboard/VoiceOver qualification.
- **Effort:** S–M, including native keyboard/AX verification.
- **Risk:** LOW/MED. Replace gesture controls with semantic buttons or explicit keyboard and AX actions without causing nested-button hit testing or changing text selection.
- **Confidence:** HIGH for missing semantic/focus implementation; exact VoiceOver narration remains untested.
- **Fix sketch:** Give timestamp and prompt actions a real button role and predictable focus. Keep chat deletion discoverable on focus as well as hover, label it with the conversation action, and make switching keyboard-operable. Validate disabled/unseekable timestamps as inert.

### [GUI-06] Decouple first dictation readiness from speaker-model readiness

- **Type / priority:** UX / architecture recommendation; P2, requires a deliberate product decision.
- **Evidence:** After the speech engine becomes ready, `OnboardingViewModel.swift:821-842` still waits for `prepareDiarizationModelsIfNeeded()` before publishing `.ready`; `:1074-1100` can fail preparation independently. `:482-502` makes that aggregate state the practice gate. The coupling is intentional in ADR-005 / ADR-010 because speaker detection defaults on for file transcription.
- **Impact:** A speaker-model failure prevents the first in-window dictation even when dictation's own speech model is usable. The only bypass is Skip, which loses the activation event the new onboarding was designed to produce.
- **Effort:** M.
- **Risk:** MED. File/meeting transcription must continue reporting speaker setup accurately, and the UI must not claim every capability is ready.
- **Confidence:** HIGH for the dependency; activation benefit is a hypothesis to measure, not a quantified result.
- **Fix sketch:** Track speech-ready and speakers-ready separately. Let practice prove dictation as soon as speech is ready; continue speaker preparation with explicit status on the relevant file/meeting path. Match completion copy to the resulting capability state: the [skipped-offline render](evidence/gui-onboarding/after/05-skipped-offline-ready.png) currently combines “You're all set” / “Dictation works in any app from here on” with a failed-model warning. Measure successful first delivery by setup engine and speaker-preparation outcome.

### [GUI-07] Send model recovery directly to the relevant Settings destination

- **Type / priority:** Confirmed navigation friction; P2.
- **Evidence:** The failure button at `OnboardingPracticeStepView.swift:434` calls a generic `onOpenSettings`. `Sources/MacParakeet/AppDelegate.swift:170-171` routes it to `openMainWindowToSettings()` without a destination. `Sources/MacParakeetViewModels/SettingsTab.swift:22` defaults to Capture; `SettingsRootViewModel.swift:75-81` may instead restore any prior tab. The needed Local Models destination already exists as `.engine` / `engine.models` in `SettingsSearchIndex.swift:489-497`, and Settings supports requested tab/anchor at `SettingsView.swift:210-223`.
- **Impact:** A first-time user sent to repair a model can land on microphone/dictation settings or an unrelated restored tab, requiring a second search to find the promised recovery action.
- **Effort:** S.
- **Risk:** LOW.
- **Confidence:** HIGH.
- **Fix sketch:** Route this particular recovery action to the Engine tab and Local Models anchor using the existing requested-destination mechanism. Keep generic Settings navigation unchanged elsewhere.

### [GUI-08] Extract cohesive transcript surfaces before further expansion

- **Type / priority:** Maintainability recommendation; P2, incremental work only.
- **Evidence:** `TranscriptResultView.swift` contains 6,814 lines at baseline and owns header/title editing, transcript modes and find, prompt selection/result generation, chat conversation selection, speaker corrections, notes, media, export, and retranscription confirmation. Its already-extracted `TranscriptTimestampedContentView`, `TranscriptFindModel`, `TranscriptReadingEditSession`, and `TranscriptResultActions` show viable boundaries. `SettingsView.swift` is 4,313 lines despite the four-tab root state model.
- **Impact:** Unrelated interaction changes share large stateful compilation/review units; the uneven button/gesture implementations in GUI-05 are one observed consequence of dispersed interaction ownership. File size alone is not a runtime-performance finding.
- **Effort:** L across several narrowly scoped changes.
- **Risk:** MED/HIGH for a sweeping rewrite; LOW/MED per characterization-backed extraction.
- **Confidence:** HIGH for coupling; no compilation-time benefit is asserted without measurement.
- **Fix sketch:** Extract chat conversation selection and prompt selection first because their state and accessibility requirements are cohesive. Preserve source revisions, cancellation, and correction ownership in existing view models; avoid adding another generic application framework.

### [GUI-09] Measure mutation-triggered main-thread work before optimizing

- **Type / priority:** Performance investigation; P2/P3 depending measured latency.
- **Evidence:** `TranscriptionLibraryViewModel` is `@MainActor`; single favorite/delete/audio-delete methods synchronously call repositories and asset cleanup at `:398`, `:630`, and `:647`. Rename/retry refresh calls `reloadLoadedWindow` / `fetchLibraryItem` synchronously at `:741-768`; ordinary page load and bulk operations already run detached at `:826` and `:576` / `:600`.
- **Impact:** Slow storage, lock contention, or expensive cleanup can block GUI interaction during those actions. The mechanism is established, but no observed user-facing latency or frequency is claimed.
- **Effort:** S to measure, M to change safely.
- **Risk:** MED. Moving mutations asynchronously creates additional ordering concerns; fix and characterize stale ownership first.
- **Confidence:** MED for practical impact, HIGH for main-actor I/O.
- **Fix sketch:** Add operation durations and a main-actor heartbeat measurement around representative large-library rename/delete workloads with synthetic artifacts. Move measured offenders behind awaited service APIs while preserving latest-query and mutation ordering.
- **Follow-up boundary:** GUI-01's newly introduced replacement query was moved off the main actor during PR review. The existing synchronous mutation, cleanup, rename and retry paths above remain candidates for measurement; this repair does not qualify those paths as responsive under contention.

## Coverage and evidence boundaries

| Journey / surface | Reviewed evidence | Observed strengths | Remaining qualification |
|---|---|---|---|
| First launch and reopen | `OnboardingCoordinator`, `OnboardingWindowController`, ADR-005 | Explicit incomplete-setup confirmation; window teardown cancels practice before an alert can become a paste target; persisted completion remains separate from a rerun | Clean disposable-account launch; relaunch after defer; smallest supported display |
| Microphone and Accessibility | `OnboardingFlowView:512-573`, `OnboardingViewModel:600-675`, permission tests | Microphone is skippable; denied mic has a Settings link; refresh polling and activation refresh exist | Real TCC deny/grant/revoke, browser/terminal launch identities, VoiceOver announcements |
| Download / offline / retry | VM preflight, failure classifier, watchdog, recovery tips, synthetic renders | Disk/runtime/network preflight; failure remains visible; retry is explicit; permission controls have separate busy state | Real interrupted/resumed downloads, throttled network, full disk, CJK close/cancel ownership |
| Key rehearsal and practice | Hotkey preview controller, practice view, VM tests, dictation flow practice tests | Production gesture state machine, editable shortcuts, no recording during rehearsal, real dictation integration, Escape and practice ownership cleanup | Physical Fn variants, macOS dictation conflict, keyboard-only flow, paste to another app and clipboard fallback |
| Completion | Finish handler, `.done` content, completion telemetry | Shows delivered synthetic/practice transcript; discloses download failure or ongoing work | Whether users can find menu bar / first next action; CJK background-completion promise |
| Library / search / pagination | Library VM/view, existing stale-rename tests, new mutation tests | SQL-backed pages; 300 ms search debounce; generation guards on page loads; summary rows avoid loading full timing metadata | Mutation races addressed by GUI-01; large-database measured responsiveness and rapid filter/rename/delete sequences |
| Export / deletion | `TranscriptResultActionsTests`, Library confirmation flows | Collision-safe exports, corrected speaker projection, partial failure reporting, cancellation ownership tests, distinct audio-only deletion | Native save-panel cancellation, permission-denied folders, external-volume disconnect, bulk action keyboard focus |
| Long transcript / find / edit | `TranscriptTimestampedLayoutSmokeTests`, `TranscriptReadingEditorLayoutTests`, correction view models | Real hosting/layout tests include 10,000-word lazy realization, far-away find anchors, cancellable refinement, edit retention after scrolling | VoiceOver reading order, text selection across cards, actual scroll FPS and editing latency on supported low-memory hardware |
| Speaker editing | Timestamped content, result view, speaker correction tests; separate diarization report | Edits flow through a shared effective projection into downstream consumers | Human correction cost and reliable seek controls; speaker accuracy/DER belongs to the diarization audit |
| Meeting capture / recovery | MeetingRecordingPanelView; meeting UI spec; health presentation models | Distinct live-preview-off vs unavailable states; partial/source-health indications; ongoing controls in pill/menu | Real mic + system permissions, headphone/Bluetooth changes, pause/recovery, minimized app, long recording |
| Settings | SettingsRootViewModel, SettingsSearchIndex, SettingsView requested destination | Searchable named destinations, preserved tab/workflow, clear tab search exit behavior | Anchor navigation after cross-tab render, all model repair states, keyboard traversal through every card |
| Accessibility / visual design | Source controls, UI accessibility contract, onboarding native render probe, historical committed capture-hub image | Semantic buttons and labels are widely used; result tabs explicitly expose AX actions; reduced-motion-aware components exist | GUI-05 gaps; actual VoiceOver, Increase Contrast, Reduce Motion, Full Keyboard Access, dark/light and display scaling |

`Assets/screenshots/transcribe.png` was inspected only as a historical design reference. Its sidebar and capture copy do not establish current UI state. No personal transcript or personal app screenshot was used as evidence.

## Highest-value native journey suite

Use an isolated signed app identity plus a disposable console user, isolated preferences/database, synthetic audio, and recorded model revisions. A successful process launch or offscreen render is not sufficient for these checks.

1. **First delivery:** clean launch → deny mic → grant Accessibility → prove configured key → grant mic on first dictation → deliver a known phrase → verify box, durable history, and non-sensitive activation event. Repeat with hotkey changed during rehearsal.
2. **Failed setup recovery:** block network before download → verify readable failure and reachable Retry in both practice phases → allow network → retry → prove delivery. Repeat with Skip / Finish during download for Parakeet and Whisper.
3. **Cross-app focus:** arm practice → switch to a synthetic text-editor fixture → dictate → verify only the intended target receives text. Close setup while processing and verify no delayed insertion into the confirmation dialog or next window.
4. **Library state ownership:** open a synthetic large library → load more / change search while favoriting and deleting → verify database, visible rows, selection, and next-page completeness. The deterministic snapshot tests catch this cheaply before native qualification.
5. **Speaker correction to artifact:** load synthetic two-speaker recording → timestamp seek → rename/reassign speaker → Undo / Redo → export → verify playback position and speaker labels in every output. Include keyboard-only execution.
6. **Meeting resilience:** deny one capture source → recover it → record known separated sources → pause → switch audio route → stop → verify durable audio/transcript and honest partial-capture indicators. This remains hardware/runtime qualification.

Prefer these bounded journeys over a screenshot count or a generic coverage percentage. Existing host-render/layout tests are valuable and should remain a separate, faster lane.

## Cross-report dependencies

The onboarding analytics receiver/funnel compatibility issue is documented and fixed in the [telemetry report](telemetry-observability.md). It must be resolved before treating the current funnel as a trustworthy basis for further onboarding experiments. Speaker-model quality, matching, and evaluation coverage belong in the separate diarization report; this report focuses on their user-facing readiness and correction workflow.

## Verification receipt

- The root-coordinated baseline run executed five new Library mutation tests: four failed, with six failed assertions; the favorite-pagination control passed.
- The temporary `OnboardingAuditRenderTests` probe rendered eight actual-view states at 760 × 600 points, using synthetic dependency state and no-op telemetry. All baseline images are retained in `evidence/gui-onboarding/before/`. The failed hotkey-phase image confirmed GUI-02.
- The fixed `TranscriptionLibraryViewModelTests` suite passed all 71 tests in the root-coordinated run. This proves the state/persistence fixture behavior, not native database-scale latency.
- PR #1205 follow-up: `swift test --jobs 8 --filter 'TranscriptionLibraryViewModelTests/.*Mutation.*'` failed all five cases on the initial synchronous replacement read. After moving that read through the existing asynchronous loader and adding failure/filter coverage, `swift test --jobs 8 --filter TranscriptionLibraryViewModelTests` passed all 74 cases. Local logs: `.build/audit-evidence/library-async-refresh-red.log` and `.build/audit-evidence/library-async-refresh-green.log`. No second full suite was run.
- Nine after renders were generated. The reviewed permission-denied state, both failure phases, skipped-offline completion, and synthetic successful-practice state render with the actual view code. The fixed hotkey failure no longer overlaps its heading; its recovery buttons extend below the initial scroll viewport and become fully visible in the successful hosted scroll-to-bottom capture. That probe asserts the native scroll viewport changed; it does not rely on arbitrary pixel comparisons.
- The final root-coordinated focused batch passed 22 tests, including the render/scroll probe and separate CLI regressions. The temporary render test was then removed from the permanent test target and archived with [reproduction instructions and image hashes](evidence/gui-onboarding/README.md). Eight byte-identical generated duplicates were removed only after verifying their `before/` copies matched SHA-256.
- No standalone app or full test suite was launched by this audit slice. The broader audit controls the shared build and final suite gate.
