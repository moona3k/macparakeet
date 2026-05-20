# Dictation First-Load Caption + Proactive Pre-warm

> Status: **COMPLETED** — archived from `plans/active/` during the
> 2026-05-16 docs/spec audit after verifying the pre-warm, loading-caption,
> runtime-preference, telemetry, and test surfaces are present on `main`.
>
> Owner: Daniel Moon (@moona3k) · 2026-05-10
>
> Branch: `feat/dictation-first-load-caption` (merged)
>
> Related ADRs: ADR-001 (Parakeet STT), ADR-005 (onboarding), ADR-016 (centralized STT runtime). No new ADR — implementation polish, not an architectural shift.

## Implementation status

Implemented on `feat/dictation-first-load-caption` and now present on `main`.

Decisions made during implementation:

- Pre-warm wiring lives in `AppDelegate`, scheduled after environment setup and again from `OnboardingCoordinator`'s completion callback. It is gated by `OnboardingViewModel.onboardingCompletedKey`, then calls the existing idempotent `STTRuntime.backgroundWarmUp()`.
- Caption spacing is an effective 6pt above the pill (4pt stack spacing plus 2pt caption bottom padding). The pill remains the bottom-anchored element.
- Animation timing stays at 220ms ease-in-out, with an opacity-only transition when Reduce Motion is enabled.
- Subcopy escalation stays at 4s, scoped to `hasCompletedFirstDictation == false`.

Programmatic verification performed:

- Baseline `swift test` before code changes: PASS, 2412 XCTest tests, 10 skipped, 0 failures.
- Focused caption coordinator tests: `swift test --filter DictationFlowCoordinatorLoadCaptionTests` PASS, 10 tests.
- Focused caption coordinator tests under parallel scheduling: `swift test --parallel --filter DictationFlowCoordinatorLoadCaptionTests` PASS, 10 tests.
- Focused first-dictation persistence tests: `swift test --filter DictationServiceTests` PASS, 13 tests.
- Focused telemetry serialization/contract tests: `swift test --filter TelemetryServiceTests` PASS, 41 tests.
- Swift 6 language-mode build without WhisperKit: `MACPARAKEET_SKIP_WHISPERKIT=1 swift build --build-path .build-swift6-no-whisper -Xswiftc -swift-version -Xswiftc 6` PASS.
- CI-style parallel suite: `swift test --parallel` PASS, 2424 XCTest tests plus 16 Swift Testing tests.
- Final full suite after cleanup: `swift test` PASS, 2425 XCTest tests, 10 skipped, plus 16 Swift Testing tests.

Instrumented app verification performed with `scripts/dev/run_app.sh`:

- Normal launch with prior successful dictation: deferred pre-warm won; a short push-to-talk dictation entered processing without showing the first-load caption.
- Forced slow STT load: first-install state showed `Preparing speech engine…`, then the first-time setup subcopy; subsequent cold-launch state showed only the main copy.
- Forced STT initialization failure: caption switched to the red `Couldn't load speech engine.` variant before the existing overlay error card appeared.
- Reduce Motion enabled: caption used the code path for opacity-only transition, with no slide offset.
- Screenshot-based geometry checks confirmed the pill's bottom-of-screen position did not shift when the caption appeared or disappeared.

Remaining human QA focus:

- Subjective animation feel on a physical display, especially the 6pt spacing and 220ms curve.
- Deployment order for the sibling website telemetry allowlist before any build containing these events ships.

## TL;DR

On the very first dictation after each cold app launch, the Parakeet model has not yet been loaded into memory, so the `.processing` spinner spins silently for ~5–15s (longer on a truly-first install) before the first transcript appears. Every subsequent dictation drops to ~500ms. This contradicts the "fast and snappy" brand promise and is the dominant first-impression friction.

This plan adds two changes:

1. **Proactive pre-warm at app launch.** A deferred `backgroundWarmUp()` runs ~1.5s after `applicationDidFinishLaunching`, so the model is usually ready by the time the user presses Fn.
2. **A floating caption above the dictation pill during `.processing`**, shown only when the engine wasn't ready at processing entry, with a 600ms grace to suppress flashes on the warm path. Copy escalates to a "first-time setup" subcopy after 4s on the truly-first-install case.

No audio-capture, state-machine, or cancellation logic is touched. The state machine stays pure; all readiness wiring lives in the coordinator.

## Context

The lazy-init path: `STTRuntime.transcribe()` → `ensureInitialized()` (`Sources/MacParakeetCore/STT/STTRuntime.swift:459`) loads the CoreML model into ANE the first time it's needed. There is no progress reporting on this path — the spinner just spins.

The existing dictation overlay (`Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift:540`) renders `SpinnerRingView` (two counter-rotating triangles, `Sources/MacParakeet/Views/Components/SacredGeometry.swift:24`) during `.processing`. There is an *inline* message slot beside the spinner (`HStack { Spinner; Text(message) }` at line 553), used today for the `"Still transcribing..."` hint when the user re-presses Fn during processing (`DictationOverlayController.swift:245`). This slot is **semantically reserved for user-triggered transient hints** and should not be repurposed for engine state.

Mic capture is already decoupled from model load: `DictationService.startRecording()` (`Sources/MacParakeetCore/Services/Dictation/DictationService.swift:182`) calls `audioProcessor.startCapture()` immediately on Fn press, regardless of model state. **No ring-buffer or capture-and-queue is needed** — the existing file-based flow already gives us "capture-and-queue" for free.

Pre-warm infrastructure already exists: `STTRuntime.backgroundWarmUp()` (`STTRuntime.swift:238`) is idempotent — short-circuits if state is already `.ready` (line 239), so it's safe to call concurrently with onboarding or meeting-recording warmup. Today the only caller is `MeetingRecordingFlowCoordinator.swift:807` when a meeting starts. We extend it to also fire on app launch.

## Goals

- **G1.** Most users on a normal cold launch never see a loading message — the model is pre-warmed in the background before they press Fn.
- **G2.** Users who beat the pre-warm (or who run on truly-first install) get a clear, premium "model loading" affordance during `.processing` with no flashing on the warm path.
- **G3.** No regression to existing dictation latency, cancellation, paste, history, or audio capture behavior.
- **G4.** Premium polish: 600ms grace before fade-in; copy escalates with elapsed time; failure state has its own caption; respects `accessibilityReduceMotion`; pill geometry stays constant.

## Non-goals

- Changing the STT engine, model, audio capture, or processing pipeline.
- Building a separate model-status UI in Settings.
- Adding tap-to-retry to the failure caption (the overlay's existing `.error` state already provides retry pathways).
- Touching meeting recording's pre-warm path (already done at `MeetingRecordingFlowCoordinator.swift:807`).
- Pre-warm progress percentage in the caption.
- Modifying `STTRuntime` to emit progress for the lazy `ensureInitialized()` path.

## Locked design

| Aspect | Decision |
|---|---|
| Pre-warm trigger | Unconditional after onboarding completion; deferred 1.5s post `applicationDidFinishLaunching` |
| Pre-warm mechanism | `await env.sttRuntime.backgroundWarmUp()` (existing API) |
| Caption trigger | Entering `.processing` with `await sttRuntime.isReady() == false` |
| Caption grace | 600ms — caption only fades in if `.processing` is still active 600ms after entry |
| Caption visual | Floating capsule positioned **above** the pill in the same NSPanel; pill geometry unchanged |
| Caption styling | `DesignSystem.Colors.pillBackground.opacity(0.55)` bg, `DesignSystem.Colors.pillBorder.opacity(0.6)` stroke, 11pt rounded `.medium`, white at 0.85 opacity |
| Caption copy (first-ever install) | After 600ms: `Preparing speech engine…`. After 4s: subcopy `First-time setup — this happens once` |
| Caption copy (subsequent cold launches) | `Preparing speech engine…` only (no subcopy — load is faster on warm disk cache, less explaining needed) |
| Failure caption | `Couldn't load speech engine.` — replaces caption, red foreground tint, dismisses with overlay's `.error` state |
| Spinner behavior | Unchanged (two counter-rotating triangles, normal speed, no opacity changes) |
| Audio buffering | None added — `audioProcessor.startCapture()` is already independent of model load |
| Install-age flag | `hasCompletedFirstDictation` Bool on `UserDefaults` (via `UserDefaultsAppRuntimePreferences`) — set on first successful dictation completion (idempotent) |
| Caption lifetime | Fades in 600ms after `.processing` entry (if model not ready at entry), fades out on `.processing` exit (any outcome) |
| Caption observability | Captured via two new telemetry events (see Telemetry section) |

### Why floating-above and not inline beside the spinner?

The existing inline-message slot is used for `"Still transcribing…"` — a *user-triggered* transient hint when the user re-presses Fn during processing. Reusing it for engine state would conflate two semantics:

- **Engine state** ("Preparing speech engine…") is passive, informational, persistent across the load.
- **Transcription hint** ("Still transcribing…") is user-triggered, transient, auto-clears after 1.1s.

Keeping them in separate visual regions preserves the distinction. The floating caption above the pill also keeps the pill geometry constant, which is the premium feel target. AC9 below explicitly requires both to coexist if both fire.

### Why 600ms grace?

Without grace, every cold start where the user dictated for 2s would briefly flash the caption even when the pre-warm finished 50ms before processing entry. 600ms means the caption is reserved for "this is actually taking a while" — never a flash on the warm path. Tuned for human-perceptible "noticing a wait" threshold (~500–800ms range; 600ms is the midpoint).

### Why a readiness snapshot plus grace-boundary recheck instead of polling?

We snapshot once on `.processing` entry to decide whether to arm the grace timer. At the 600ms grace boundary, we perform one final readiness check so AC3 stays true: if pre-warm lost at entry but finished before the grace expired, the caption never flashes. After the caption appears, we do not poll `isReady()` during the load because:

1. The caption should display for the *entire* model-load period, even if the load finishes 200ms before transcription completes. Hiding it mid-`.processing` would create a confusing flicker.
2. Polling adds complexity (timer, cancellation, race with `.processing` exit) for no UX gain.
3. `.processing` exit is the natural fade-out trigger and is already wired through the state machine.

Trade-off: if model loads in 1s and transcription takes 30s (long dictation, warm-cache load), the caption is shown for 30s when only the first 1s was actually "loading." Mitigation: this case is rare (model is almost always loaded before user dictates long, given pre-warm). If telemetry shows this is happening, we can add an explicit model-loaded signal later.

## Implementation surface

### 1. Pre-warm at app launch

**File:** `Sources/MacParakeet/AppDelegate.swift:225` (in `applicationDidFinishLaunching`)
   or `Sources/MacParakeet/App/AppEnvironmentConfigurer.swift:77` (in `configure`).

After environment setup, schedule a deferred `Task.detached`:

```swift
// Pseudocode — actual placement decided at implementation time
private func schedulePreWarm(env: AppEnvironment) {
    Task.detached(priority: .utility) {
        try? await Task.sleep(for: .milliseconds(1500))
        guard env.onboarding.hasCompleted else { return }
        await env.sttRuntime.backgroundWarmUp()
    }
}
```

`backgroundWarmUp()` is idempotent and gated on `.ready` state (`STTRuntime.swift:239`), so this is safe to call concurrently with onboarding or meeting-recording warmup. The 1.5s deferral prevents competition with first-paint and main-window layout.

**Constant:** `private let preWarmDeferralMs: Int = 1500` — named so we can tune.

**Gate:** skip if onboarding isn't complete (onboarding has its own download/warmup flow). Reference the existing onboarding-complete signal — locate during implementation (likely `OnboardingViewModel.hasCompleted` or a UserDefaults key already in use by `OnboardingCoordinator.swift:30`).

### 2. STT readiness snapshot at `.processing` entry

**File:** `Sources/MacParakeet/App/DictationFlowCoordinator.swift:322` (handler for `.showProcessingState`)

```swift
case .showProcessingState:
    overlayViewModel?.stopTimer()
    overlayViewModel?.processingMessage = nil
    overlayViewModel?.busyProcessingMessage = nil
    overlayViewModel?.state = .processing
    overlayViewModel?.processingLoadCaption = nil

    // NEW: snapshot readiness and arm caption timers
    armProcessingLoadCaption()
```

`armProcessingLoadCaption()` (new private method on the coordinator):

```swift
private func armProcessingLoadCaption() {
    captionGraceTimer?.cancel()
    captionEscalationTimer?.cancel()

    Task { @MainActor [weak self] in
        guard let self else { return }
        guard await !self.sttRuntime.isReady() else {
            // Pre-warm won — no caption ever shown for this dictation
            return
        }

        // Engine wasn't ready at processing entry. Arm 600ms grace.
        let grace = DispatchWorkItem { [weak self] in
            self?.fireCaption()
        }
        self.captionGraceTimer = grace
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600), execute: grace)
    }
}

private func fireCaption() {
    guard overlayViewModel?.state.isProcessing == true else { return }
    let firstInstall = !preferences.hasCompletedFirstDictation
    overlayViewModel?.processingLoadCaption = .preparing
    captionShownAt = Date()
    sendCaptionShownTelemetry(firstInstall: firstInstall)

    if firstInstall {
        let escalate = DispatchWorkItem { [weak self] in
            guard self?.overlayViewModel?.processingLoadCaption == .preparing else { return }
            self?.overlayViewModel?.processingLoadCaption = .preparingExtended
        }
        self.captionEscalationTimer = escalate
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(4000), execute: escalate)
    }
}

private func dismissCaption(outcome: CaptionOutcome) {
    captionGraceTimer?.cancel()
    captionEscalationTimer?.cancel()
    captionGraceTimer = nil
    captionEscalationTimer = nil

    if let shownAt = captionShownAt {
        let duration = Date().timeIntervalSince(shownAt)
        sendCaptionDurationTelemetry(durationMs: Int(duration * 1000), outcome: outcome)
        captionShownAt = nil
    }
    overlayViewModel?.processingLoadCaption = nil
}
```

Wire `dismissCaption(...)` into all `.processing` exit effect handlers in `DictationFlowCoordinator.swift`:
- `.showSuccess` → `dismissCaption(.success)`
- `.showNoSpeech` → `dismissCaption(.noSpeech)`
- `.showError` → if caption was in `.preparing`/`.preparingExtended`, transition to `.failed` for a 2s display, then dismiss; otherwise dismiss immediately
- `.hideOverlay` → `dismissCaption(.cancelled)` if still showing

### 3. New overlay VM state

**File:** `Sources/MacParakeet/Views/Dictation/DictationOverlayController.swift:179` (`DictationOverlayViewModel`)

Add:

```swift
enum ProcessingLoadCaption: Equatable {
    case preparing                  // 600ms+: "Preparing speech engine…"
    case preparingExtended          // 4s+ on first-ever install: + subcopy
    case failed                     // load error: "Couldn't load speech engine."
}

var processingLoadCaption: ProcessingLoadCaption?
```

Independent of `state` (`OverlayState`) — caption shows during `.processing` but doesn't constrain or extend it. `@Observable` mutation triggers SwiftUI re-render automatically.

### 4. New view: `LoadingCaptionView`

**New file:** `Sources/MacParakeet/Views/Dictation/LoadingCaptionView.swift`

A compact capsule:
- Background: `DesignSystem.Colors.pillBackground.opacity(0.55)`
- Stroke: `DesignSystem.Colors.pillBorder.opacity(0.6)`, 0.5pt
- Title: 11pt `.rounded` `.medium`, white at 0.85 opacity
- Subcopy: 9.5pt `.rounded` `.regular`, white at 0.55 opacity, appears below title with 1pt spacing
- Padding: 9pt horizontal, 5pt vertical
- Corner radius: 8pt
- Transition: `.opacity.combined(with: .offset(y: 4))`, 220ms ease-in-out
- Respects `accessibilityReduceMotion`: cross-fade only, no offset slide
- Failure variant: `DesignSystem.Colors.recordingRed` foreground tint on title; subcopy hidden

```swift
struct LoadingCaptionView: View {
    let caption: DictationOverlayViewModel.ProcessingLoadCaption
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(titleColor)
            if let subcopy {
                Text(subcopy)
                    .font(.system(size: 9.5, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignSystem.Colors.pillBackground.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DesignSystem.Colors.pillBorder.opacity(0.6), lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // title / subcopy / colors / accessibilityLabel switch on `caption`
}
```

### 5. Mount the caption in the overlay

**File:** `Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift`

Wrap the existing pill content in a `VStack` (or `ZStack` with `.alignmentGuide`) so the caption floats above without displacing the pill's bottom-anchored screen position:

```swift
VStack(spacing: 6) {
    Group {
        if let caption = viewModel.processingLoadCaption {
            LoadingCaptionView(caption: caption)
        } else {
            // empty placeholder preserves layout when caption absent
            Color.clear.frame(height: 0)
        }
    }
    .transition(.opacity)
    .animation(.easeInOut(duration: 0.22), value: viewModel.processingLoadCaption)

    pillContent  // existing pill rendering
}
```

The dictation overlay panel is already 300×160 (`DictationOverlayController.swift:77-79`), with the pill content centered. Ample vertical room above the pill exists for a caption without resizing the panel. The pill stays bottom-anchored in the panel; the caption fades in/out above it.

### 6. First-dictation flag

**File:** `Sources/MacParakeetCore/AppRuntimePreferences.swift:92` (`UserDefaultsAppRuntimePreferences`)

Add to `AppRuntimePreferencesProtocol`:

```swift
var hasCompletedFirstDictation: Bool { get }
func markFirstDictationCompleted()
```

Add to `UserDefaultsAppRuntimePreferences`:

```swift
public static let hasCompletedFirstDictationKey = "hasCompletedFirstDictation"

public var hasCompletedFirstDictation: Bool {
    defaults.bool(forKey: Self.hasCompletedFirstDictationKey)
}

public func markFirstDictationCompleted() {
    defaults.set(true, forKey: Self.hasCompletedFirstDictationKey)
}
```

`markFirstDictationCompleted()` is called from `DictationService.stopRecording(sessionID:)` in the success path **after the dictation history insert succeeds**, so failed dictations don't burn the first-time flag. Idempotent — UserDefaults `set(true)` is cheap.

### 7. Telemetry

Add to `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift`:

- **`dictationFirstLoadCaptionShown`** — payload: `first_install: Bool`. Fired when the caption fades in.
- **`dictationFirstLoadCaptionDuration`** — payload: `duration_ms: Int`, `outcome: "success" | "no_speech" | "failure" | "cancelled"`. Fired when caption fades out.

**Two-repo change required:** Add both event names to `ALLOWED_EVENTS` in `macparakeet-website/functions/api/telemetry.ts` **BEFORE** the app build ships. Per `memory/feedback_telemetry_allowlist.md`, the Worker rejects the entire batch if any event is unknown, silently dropping valid co-batched events. Verify with curl after deploy.

## State machine additions

**None.** The state machine (`DictationFlowStateMachine.swift`) stays pure — no new effects, no new events. All caption logic lives in the coordinator's effect handlers (§2 above), because the state machine has no STT dependency by design (ADR-016).

## Copy spec

| Time after `.processing` entry | First-ever install | Subsequent cold launches |
|---|---|---|
| 0–600ms | (none — suppressed by grace) | (none — suppressed by grace) |
| 600ms+ | `Preparing speech engine…` | `Preparing speech engine…` |
| 4s+ (caption visible 3.4s+) | + subcopy: `First-time setup — this happens once` | (main copy only — no subcopy) |
| On model-load failure | `Couldn't load speech engine.` (red tint) | `Couldn't load speech engine.` (red tint) |
| On `.processing` exit | (fade out, 220ms) | (fade out, 220ms) |

VoiceOver: caption text announced on appear via `accessibilityLabel`. No live region — we want a single announcement on first appearance, not a re-announce on subcopy change. Subcopy joins silently.

## Acceptance criteria

- **AC1.** Truly-first-install: after onboarding completes and the user reaches the main window, `backgroundWarmUp()` is invoked ~1.5s post-launch with no UI interaction required.
- **AC2.** Pre-warm wins (typical 2nd+ cold launch): user dictates 2s on cold launch, model is loaded by the time `.processing` is entered, no caption appears.
- **AC3.** Pre-warm loses by <600ms: caption never appears (grace suppression).
- **AC4.** Pre-warm loses by 600ms–4s: caption appears with `Preparing speech engine…`, no subcopy, fades out on `.processing` exit.
- **AC5.** First-ever install, model loads in 8s: caption appears at 600ms with main copy; at 4.6s the subcopy joins; both fade out at ~8s when transcription completes.
- **AC6.** Subsequent cold launch, model loads in 8s: caption shows main copy only (no subcopy) for the full duration.
- **AC7.** Model load fails mid-`.processing`: caption switches to failure variant (red) for ~2s before overlay transitions to `.error`.
- **AC8.** User cancels dictation while caption is showing (Escape, dismissal, or app close): caption fades out alongside overlay close — no orphaned caption visible.
- **AC9.** Existing "Still transcribing…" inline hint still works when user re-presses Fn during `.processing` — both messages can coexist (caption above, inline beside spinner).
- **AC10.** `accessibilityReduceMotion`: caption cross-fades only, no offset animation.
- **AC11.** `hasCompletedFirstDictation` flips from `false` to `true` exactly once, on the first successful dictation; remains `true` thereafter. Cancelled / failed dictations do not flip the flag.
- **AC12.** No regression in any existing dictation flow (cancellation, mode switches, paste, history, ready-pill auto-dismiss, command mode, formatting mode, no-speech outcome).
- **AC13.** Telemetry events fire correctly: `caption_shown` once on appear, `caption_duration` once on dismiss with accurate `duration_ms` and `outcome`.

## Test plan

### Unit / ViewModel

- `DictationOverlayViewModelTests` (existing) — verify `processingLoadCaption` set/clear, no timer leaks.
- `LoadingCaptionViewTests` (optional) — render verification per caption variant; low ROI, defer.

### Coordinator / integration

- **New file:** `Tests/MacParakeetTests/Dictation/DictationFlowCoordinatorLoadCaptionTests.swift`
- Mock `STTRuntime`'s `isReady()` to control readiness. Exercise:
  - Model ready at entry → no caption ever.
  - Model not ready, processing < 600ms → no caption (grace suppressed).
  - Model not ready, processing 1s, first install → caption with main copy, no subcopy at 1s; subcopy would have arrived at 4.6s.
  - Model not ready, processing 5s, first install → caption + subcopy at 4.6s mark; both clear at 5s.
  - Model not ready, processing 5s, subsequent launch → caption main copy only, no subcopy ever.
  - Failure: caption switches to failure variant; clears after 2s.
  - Cancellation during caption: clears without flash.
  - Second dictation in same session (model now warm): no caption regardless of duration.
- Use injected `Clock` if available (precedent: commit `65ec19b0` deferred Clock injection for meeting-recording duration tests).

### Manual / smoke

- Cold launch on a clean install (no `hasCompletedFirstDictation` flag) → first dictation should produce the full main + subcopy sequence.
- Force `STTRuntime` into a slow-load state (uninstall CoreML cache or insert artificial delay in `ensureInitialized`) → caption sequence as specified.
- Subsequent app launches with prior dictation history → main copy only, no subcopy.
- `Reduce Motion` enabled (System Settings → Accessibility → Display) → caption uses cross-fade with no slide.
- Concurrent meeting recording warmup → no double-warmup, no UI glitch.

## Telemetry validation

Once the allowlist update lands and a build ships, query D1 (per `reference_cloudflare_queries.md`):

```sql
SELECT
    COUNT(*) AS caption_shown_count,
    AVG(json_extract(payload, '$.duration_ms')) AS avg_duration_ms,
    SUM(CASE WHEN json_extract(payload, '$.first_install') = 'true' THEN 1 ELSE 0 END) AS first_install_shown,
    SUM(CASE WHEN json_extract(payload, '$.outcome') = 'failure' THEN 1 ELSE 0 END) AS failure_count
FROM events
WHERE name IN ('dictation_first_load_caption_shown', 'dictation_first_load_caption_duration')
  AND received_at >= ?;
```

**Success metric post-ship:** caption_shown_count / total_dictations < 10%. If higher (say, >25%), tune `preWarmDeferralMs` down or investigate warmup blockers. If `failure_count` is non-trivial, file a follow-up to surface tap-to-retry in the failure variant.

## Open questions / decision points

1. **Pre-warm deferral value (1.5s)** — pragmatic guess. Tune based on observed startup competition. Constant lives in code.
2. **Caption position offset above pill** — 6pt or 8pt of vertical spacing? Pick during implementation based on visual feel; document the choice in commit message.
3. **Failure copy actionability** — for v1, the failure caption is informational only. Revisit if telemetry shows failure caption being seen frequently — could add a retry button or "Open Settings" link.
4. **Pre-warm gating signal** — needs identification at implementation time: which Onboarding flag is authoritative? Likely lives in `OnboardingViewModel` or `OnboardingCoordinator`. If onboarding completion is observed via a delegate callback, schedule pre-warm there instead of a fixed timer.

## Out of scope / follow-ups

- **Settings toggle** for pre-warm gating (some users might want to disable to save RAM). Add only if requested via feedback.
- **Pre-warm progress in the caption** ("Loading speech engine… 47%"). Considered but adds visual noise; the 4s subcopy is already the escalation lever.
- **Idle pill warmup indicator** — the idle pill could subtly indicate "warming up" via the breathing animation rate, but this is a deeper redesign.
- **Whisper engine path** — Whisper isn't typically used for dictation today; if dictation-via-Whisper becomes common, revisit whether `isReady()` semantics differ per engine.
- **Lazy-init progress emission** — modify `STTRuntime.ensureInitialized()` to emit `STTWarmUpState` events so the caption can show real progress instead of "indefinite spinner." Larger refactor; defer unless telemetry shows we need it.

## References

- ADR-001 (Parakeet TDT 0.6B-v3 as primary STT) — `spec/adr/001-parakeet-stt.md`
- ADR-005 (Onboarding first-run) — `spec/adr/005-onboarding-first-run.md`
- ADR-016 (Centralized STT runtime and two-slot scheduler) — `spec/adr/016-centralized-stt-runtime-scheduler.md`
- `spec/06-stt-engine.md` — STT engine narrative
- `spec/04-ui-patterns.md` — Overlay UI patterns (to be updated)
- `memory/feedback_telemetry_allowlist.md` — two-repo telemetry change reminder
- `reference_cloudflare_queries.md` — D1 query patterns for telemetry validation

## Files touched

### Source

- `Sources/MacParakeet/AppDelegate.swift` — schedule deferred pre-warm
- `Sources/MacParakeet/App/AppEnvironmentConfigurer.swift` — wire pre-warm trigger (alternative location)
- `Sources/MacParakeet/App/DictationFlowCoordinator.swift` — readiness snapshot + caption timing + telemetry
- `Sources/MacParakeet/Views/Dictation/DictationOverlayController.swift` — `ProcessingLoadCaption` enum, VM property
- `Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift` — mount caption above pill via VStack
- `Sources/MacParakeet/Views/Dictation/LoadingCaptionView.swift` — **new**
- `Sources/MacParakeetCore/AppRuntimePreferences.swift` — `hasCompletedFirstDictation` accessor + setter
- `Sources/MacParakeetCore/Services/Dictation/DictationService.swift` — flip flag on first success
- `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` — two new event cases

### Tests

- `Tests/MacParakeetTests/Dictation/DictationFlowCoordinatorLoadCaptionTests.swift` — **new**

### Sibling repo (must land before app ship)

- `macparakeet-website/functions/api/telemetry.ts` — allowlist update for two new event names

### Spec

- `spec/04-ui-patterns.md` — document the loading caption pattern (dictation overlay section)
- `spec/kernel/requirements.yaml` — add requirement ID (e.g. `REQ-DICTATION-COLD-LOAD-FEEDBACK`)
- `spec/kernel/traceability.md` — map source files + test files to the requirement
