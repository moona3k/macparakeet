import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct OnboardingFlowView: View {
    @Bindable var viewModel: OnboardingViewModel
    let onFinish: () -> Void
    let onOpenMainApp: () -> Void
    let onOpenSettings: () -> Void
    /// Arms/disarms the no-STT hotkey rehearsal while the "Learn the Hotkey"
    /// step is on screen. Defaults to no-ops so previews/tests can omit them.
    var onHotkeyPreviewArm: () -> Void = {}
    var onHotkeyPreviewDisarm: () -> Void = {}

    /// Triggers shown in onboarding copy — fall back to defaults when disabled
    /// so instructional text stays readable.
    private var handsFreeDisplayTrigger: HotkeyTrigger {
        let current = HotkeyTrigger.current
        return current.isDisabled ? .defaultDictation : current
    }

    private var pushToTalkDisplayTrigger: HotkeyTrigger {
        let current = HotkeyTrigger.current(
            defaultsKey: HotkeyTrigger.pushToTalkDefaultsKey,
            fallback: .defaultPushToTalk
        )
        return current.isDisabled ? .defaultPushToTalk : current
    }

    private var usesSharedDictationGesture: Bool {
        HotkeyTrigger.isSharedDictationGesture(
            handsFree: handsFreeDisplayTrigger,
            pushToTalk: pushToTalkDisplayTrigger
        )
    }

    private var handsFreeGestureTitle: String {
        "\(usesSharedDictationGesture ? "Double-tap" : "Tap") \(handsFreeDisplayTrigger.shortSymbol)"
    }

    private var handsFreeInstructionPhrase: String {
        "\(usesSharedDictationGesture ? "Double-tap" : "Tap") \(handsFreeDisplayTrigger.displayName)"
    }

    private var handsFreeTryNowVerb: String {
        usesSharedDictationGesture ? "double-tap" : "tap"
    }

    private let windowWidth: CGFloat = 740
    private let windowHeight: CGFloat = 500

    @State private var hoveredStep: OnboardingViewModel.Step?
    @State private var backButtonHovered = false

    private var visibleSteps: [OnboardingViewModel.Step] { OnboardingViewModel.visibleSteps }
    private var totalSteps: Int { visibleSteps.count }
    private var currentStepIndex: Int {
        (visibleSteps.firstIndex(of: viewModel.step) ?? 0) + 1
    }
    private var onboardingProgress: Double {
        Double(currentStepIndex) / Double(max(totalSteps, 1))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(width: windowWidth, height: windowHeight)
        .background(DesignSystem.Colors.background)
        .onAppear {
            viewModel.startPermissionPolling()
        }
        .onDisappear {
            viewModel.stopPermissionPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refresh()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            // App header with warm merkaba
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    MeditativeMerkabaView(size: 28, revolutionDuration: 6.0, tintColor: DesignSystem.Colors.accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacParakeet")
                            .font(DesignSystem.Typography.sectionTitle)
                        Text("First-time setup")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Step \(currentStepIndex) of \(totalSteps)")
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(DesignSystem.Colors.accentDark)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(DesignSystem.Colors.accentLight)
                    )
            }
            .padding(.top, DesignSystem.Spacing.xl)
            .padding(.horizontal, DesignSystem.Spacing.xl)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(visibleSteps) { step in
                    stepRow(step)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)

            ProgressView(value: onboardingProgress)
                .progressViewStyle(.linear)
                .tint(DesignSystem.Colors.accent)
                .padding(.horizontal, DesignSystem.Spacing.xl)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Label("Local-first. No audio uploads.", systemImage: "lock.shield")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                Label("Paste needs Accessibility.", systemImage: "keyboard")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignSystem.Spacing.xl)
            .padding(.bottom, DesignSystem.Spacing.xl)
        }
        .frame(minWidth: 220, maxWidth: 260, alignment: .leading)
        .background(DesignSystem.Colors.surfaceElevated)
    }

    private func stepRow(_ step: OnboardingViewModel.Step) -> some View {
        let isSelected = viewModel.step == step
        let isCompleted = stepIsCompleted(step)
        let isHovered = hoveredStep == step

        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isSelected ? DesignSystem.Colors.accent.opacity(0.15) : Color.clear)
                    .frame(width: 26, height: 26)
                if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.accent)
                } else {
                    Image(systemName: stepIcon(step))
                        .foregroundStyle(isSelected ? DesignSystem.Colors.accent : .secondary)
                }
            }

            Text(step.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(isSelected
                      ? DesignSystem.Colors.accent.opacity(0.08)
                      : isHovered ? DesignSystem.Colors.rowHoverBackground : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hoveredStep = hovering ? step : nil
            }
        }
        .onTapGesture {
            if step.rawValue <= viewModel.step.rawValue || stepIsCompleted(step) {
                viewModel.jump(to: step)
            }
        }
    }

    private func stepIcon(_ step: OnboardingViewModel.Step) -> String {
        switch step {
        case .welcome: return "hand.wave"
        case .microphone: return "mic"
        case .accessibility: return "accessibility"
        case .meetingRecording: return "record.circle"
        case .calendar: return "calendar"
        case .hotkey: return "keyboard"
        case .engine: return "cpu"
        case .done: return "checkmark.circle"
        }
    }

    private func stepIsCompleted(_ step: OnboardingViewModel.Step) -> Bool {
        switch step {
        case .welcome:
            return viewModel.step.rawValue > step.rawValue
        case .microphone:
            return viewModel.micStatus == .granted
        case .accessibility:
            return viewModel.accessibilityGranted
        case .meetingRecording:
            return viewModel.screenRecordingGranted || viewModel.meetingRecordingSkipped
        case .calendar:
            return viewModel.calendarPermissionGranted || viewModel.calendarSkipped
        case .hotkey:
            return viewModel.step.rawValue > step.rawValue
        case .engine:
            if case .ready = viewModel.engineState { return true }
            return false
        case .done:
            return viewModel.hasCompletedOnboarding
        }
    }

    // MARK: - Content Area

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(titleForStep(viewModel.step))
                    .font(DesignSystem.Typography.pageTitle)
                Text(subtitleForStep(viewModel.step))
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                progressStrip
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)

            SacredGeometryDivider()
                .padding(.top, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepBody(viewModel.step)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
            .id(viewModel.step)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(.easeInOut(duration: 0.25), value: viewModel.step)

            Divider()

            footer
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if let hint = continueHint {
                Text(hint)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
            // Back button — hidden on welcome via opacity
                Button {
                    viewModel.goBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(backButtonHovered ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .fill(backButtonHovered ? DesignSystem.Colors.rowHoverBackground : .clear)
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.step == .welcome || viewModel.isBusy)
                .opacity(viewModel.step == .welcome ? 0 : 1)
                .onHover { hovering in
                    withAnimation(DesignSystem.Animation.hoverTransition) {
                        backButtonHovered = hovering
                    }
                }

                Spacer()

                if viewModel.step == .done {
                    accentButton("Open MacParakeet", icon: "arrow.right", large: true, disabled: false, isDefault: true) {
                        _ = viewModel.markOnboardingCompleted()
                        onFinish()
                        onOpenMainApp()
                    }
                } else {
                    let disabled = continueButtonDisabled
                    accentButton(primaryButtonTitle(for: viewModel.step), icon: "arrow.right", large: false, disabled: disabled, isDefault: true) {
                        viewModel.goNext()
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    // MARK: - Step Body

    @ViewBuilder
    private func stepBody(_ step: OnboardingViewModel.Step) -> some View {
        switch step {
        case .welcome:
            welcomeStep
        case .microphone:
            permissionCard(
                title: "Microphone access",
                status: micStatusText(viewModel.micStatus),
                statusStyle: micStatusStyle(viewModel.micStatus),
                detail: "Required to record your voice for dictation."
            ) {
                accentButton(
                    viewModel.isBusy ? "Requesting..." : "Grant Microphone Access",
                    disabled: viewModel.isBusy || viewModel.micStatus == .granted
                ) {
                    viewModel.requestMicrophoneAccess()
                }

                if viewModel.micStatus == .denied {
                    Button("Open System Settings") {
                        openPrivacySettings(anchor: "Privacy_Microphone")
                    }
                }
            }
        case .accessibility:
            permissionCard(
                title: "Accessibility access",
                status: viewModel.accessibilityGranted ? "Granted" : "Not granted",
                statusStyle: viewModel.accessibilityGranted ? .ok : .warn,
                detail: "Required for the global hotkey and Cmd+V paste automation."
            ) {
                accentButton(
                    "Enable Accessibility",
                    disabled: viewModel.isBusy || viewModel.accessibilityGranted
                ) {
                    viewModel.requestAccessibilityAccess(prompt: true)
                }

                Button("Open System Settings") {
                    openPrivacySettings(anchor: "Privacy_Accessibility")
                }
            }
        case .meetingRecording:
            meetingRecordingStep
        case .calendar:
            calendarStep
        case .hotkey:
            hotkeyStep
        case .engine:
            engineSetupView
                .onAppear {
                    viewModel.startEngineWarmUp()
                }
        case .done:
            doneStep
        }
    }

    // MARK: - Welcome Step

    private var welcomeStep: some View {
        VStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            // Hero merkaba with particle shimmer
            ZStack {
                ParticleField(
                    particleCount: 8,
                    tintColor: DesignSystem.Colors.accent,
                    opacity: 0.3,
                    driftDirection: .orbital
                )
                .frame(width: 120, height: 120)

                MeditativeMerkabaView(size: 64, revolutionDuration: 5.0, tintColor: DesignSystem.Colors.accent)
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity)

            Text("Your voice, instantly as text.")
                .font(DesignSystem.Typography.pageTitle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(
                    icon: "mic.fill",
                    title: "Dictate anywhere",
                    detail: "\(handsFreeInstructionPhrase) for hands-free dictation, or hold \(pushToTalkDisplayTrigger.displayName) and release to stop. Text appears where your cursor is."
                )
                featureRow(
                    icon: "bolt.fill",
                    title: "Blazing fast",
                    detail: "60 minutes of audio transcribed in ~23 seconds on Apple Silicon."
                )
                featureRow(
                    icon: "lock.shield.fill",
                    title: "100% local",
                    detail: "Audio never leaves your Mac. No cloud STT. No accounts. Non-identifying diagnostics only."
                )
            }
        }
    }

    // MARK: - Hotkey Step

    private var meetingRecordingStep: some View {
        onboardingCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Meeting Recording (Optional)")
                        .font(DesignSystem.Typography.sectionTitle)

                    Spacer()

                    Text(viewModel.screenRecordingGranted ? "Granted" : "Not granted")
                        .font(DesignSystem.Typography.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                viewModel.screenRecordingGranted
                                ? DesignSystem.Colors.successGreen.opacity(0.15)
                                : DesignSystem.Colors.warningAmber.opacity(0.15)
                            )
                        )
                        .foregroundStyle(
                            viewModel.screenRecordingGranted
                            ? DesignSystem.Colors.successGreen
                            : DesignSystem.Colors.warningAmber
                        )
                }

                Text("Grant access to let MacParakeet record audio from meetings and calls.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("You can skip this and enable meeting recording later from Settings.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    accentButton(
                        "Enable meeting recording",
                        disabled: viewModel.isBusy || viewModel.screenRecordingGranted
                    ) {
                        viewModel.requestScreenRecordingAccess()
                    }

                    Button("Skip — I'll set this up later") {
                        viewModel.skipMeetingRecordingStep()
                    }
                    .parakeetAction(.secondary)
                }

                if !viewModel.screenRecordingGranted {
                    Button("Open System Settings") {
                        viewModel.openScreenRecordingSystemSettings()
                    }
                    .buttonStyle(.link)
                }

                if viewModel.showRelaunchHint {
                    Text("If the status doesn't update, quit and reopen MacParakeet. macOS sometimes requires a restart after granting this permission.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .padding(DesignSystem.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                .fill(DesignSystem.Colors.warningAmber.opacity(0.08))
                        )
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    private var calendarStep: some View {
        onboardingCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Calendar Meetings (Optional)")
                        .font(DesignSystem.Typography.sectionTitle)
                    Spacer()
                    Text(viewModel.calendarPermissionGranted ? "Granted" : "Not granted")
                        .font(DesignSystem.Typography.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                viewModel.calendarPermissionGranted
                                ? DesignSystem.Colors.successGreen.opacity(0.15)
                                : DesignSystem.Colors.warningAmber.opacity(0.15)
                            )
                        )
                        .foregroundStyle(
                            viewModel.calendarPermissionGranted
                            ? DesignSystem.Colors.successGreen
                            : DesignSystem.Colors.warningAmber
                        )
                }

                Text("MacParakeet can read your macOS calendar to send a quiet notification before each scheduled meeting and, if you choose, start recording automatically.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Events are read on-device only and never uploaded. You can change the lead time, ignore specific calendars, or turn this off entirely from Settings.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    accentButton(
                        viewModel.isBusy ? "Requesting..." : "Enable Calendar Access",
                        disabled: viewModel.isBusy || viewModel.calendarPermissionGranted
                    ) {
                        viewModel.requestCalendarAccess()
                    }

                    Button("Skip — I'll set this up later") {
                        viewModel.skipCalendarStep()
                    }
                    .parakeetAction(.secondary)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    @State private var tapPhase = 0
    @State private var holdPhase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hotkeyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if HotkeyTrigger.current.isDisabled {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.accent)
                    Text("Your hands-free hotkey is currently disabled. The examples below show the default shortcuts. You can set hotkeys anytime in Settings.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(DesignSystem.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.accent.opacity(0.08))
                )
            }

            // Live rehearsal nudge — only when Accessibility is granted, since
            // the preview taps can't arm without it (and dictation won't work
            // anyway). No model is needed: this is a visual preview only.
            if viewModel.accessibilityGranted {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill")
                        .foregroundStyle(DesignSystem.Colors.accent)
                    Text("Try it now — \(handsFreeTryNowVerb) \(handsFreeDisplayTrigger.shortSymbol) or hold \(pushToTalkDisplayTrigger.shortSymbol). A live preview appears at the bottom of your screen.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DesignSystem.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.accent.opacity(0.08))
                )
            }

            // Hands-free mode card
            onboardingCard {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    handsFreeIllustration
                        .frame(width: 80)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Hands-free mode")
                            .font(DesignSystem.Typography.micro)
                            .foregroundStyle(DesignSystem.Colors.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(DesignSystem.Colors.accent.opacity(0.12)))

                        Text(handsFreeGestureTitle)
                            .font(DesignSystem.Typography.sectionTitle)

                        Text("Starts persistent recording.\nTap \(handsFreeDisplayTrigger.shortSymbol) once more to stop and paste.")
                            .font(DesignSystem.Typography.bodySmall)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }

            // Push-to-Talk card
            onboardingCard {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    holdIllustration
                        .frame(width: 80)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Push-to-Talk")
                            .font(DesignSystem.Typography.micro)
                            .foregroundStyle(DesignSystem.Colors.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(DesignSystem.Colors.accent.opacity(0.12)))

                        Text("Hold \(pushToTalkDisplayTrigger.shortSymbol)")
                            .font(DesignSystem.Typography.sectionTitle)

                        Text("Records while you hold the key.\nRelease to stop and paste.")
                            .font(DesignSystem.Typography.bodySmall)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }

            // Escape row
            HStack(spacing: 10) {
                keyCap("Esc")
                Text("Press Escape to cancel")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("5-second undo window")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
            }

            Text("Click Next to keep these hotkeys for now. You can change them later in Settings > Dictation; if Fn is unavailable, file transcription still works from the main app.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            startAnimations()
            onHotkeyPreviewArm()
        }
        .onDisappear {
            stopAnimations()
            onHotkeyPreviewDisarm()
        }
    }

    // MARK: - Hotkey Gesture Illustrations

    @State private var animationTask: Task<Void, Never>?

    private var handsFreeIllustration: some View {
        keyCap(handsFreeDisplayTrigger.shortSymbol)
            .scaleEffect(tapPhase == 1 ? 0.9 : 1.0)
            .opacity(reduceMotion || tapPhase == 1 ? 1.0 : 0.5)
            .animation(.easeInOut(duration: 0.15), value: tapPhase)
            .overlay(alignment: .topTrailing) {
                if usesSharedDictationGesture {
                    Text("x2")
                        .font(DesignSystem.Typography.caption.weight(.semibold))
                        .foregroundStyle(DesignSystem.Colors.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DesignSystem.Colors.accent.opacity(0.14)))
                        .offset(x: 14, y: -10)
                }
            }
    }

    private var holdIllustration: some View {
        VStack(spacing: 6) {
            keyCap(pushToTalkDisplayTrigger.shortSymbol)
                .scaleEffect(holdPhase > 0 ? 0.93 : 1.0)
                .opacity(reduceMotion || holdPhase > 0 ? 1.0 : 0.5)
                .animation(.easeInOut(duration: 0.15), value: holdPhase > 0)

            // Hold bar that grows
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(DesignSystem.Colors.accent.opacity(0.5))
                    .frame(width: geo.size.width * (reduceMotion ? 1.0 : holdPhase))
                    .animation(.linear(duration: holdPhase > 0 ? 1.0 : 0.15), value: holdPhase)
            }
            .frame(height: 4)
        }
    }

    private func startAnimations() {
        guard !reduceMotion else { return }
        animationTask?.cancel()
        let tapCount = usesSharedDictationGesture ? 2 : 1
        animationTask = Task { @MainActor in
            while !Task.isCancelled {
                // Hands-free gesture.
                for tapIndex in 0..<tapCount {
                    tapPhase = 1
                    try? await Task.sleep(for: .milliseconds(160))
                    guard !Task.isCancelled else { return }
                    tapPhase = 0
                    if tapIndex < tapCount - 1 {
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled else { return }
                    }
                }

                // Hold: press and grow bar
                holdPhase = 0.01 // trigger "pressed" state
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                holdPhase = 1.0
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                holdPhase = 0

                // Pause before repeat
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func stopAnimations() {
        animationTask?.cancel()
        animationTask = nil
    }

    // MARK: - Engine Setup

    private var engineSetupView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let recommendation = viewModel.whisperRecommendation {
                onboardingCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "globe.asia.australia.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.accent)
                            .frame(width: 34, height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                    .fill(DesignSystem.Colors.accent.opacity(0.1))
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(recommendation.languageName) setup")
                                .font(DesignSystem.Typography.sectionTitle)
                            Text("Your Mac language suggests \(recommendation.languageName). MacParakeet will set up local Whisper instead of Parakeet so dictation works for this language from the first run.")
                                .font(DesignSystem.Typography.bodySmall)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }

            onboardingCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        switch viewModel.engineState {
                        case .ready:
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(DesignSystem.Colors.successGreen)
                        case .failed:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(DesignSystem.Colors.warningAmber)
                        case .idle, .working(_, _):
                            SpinnerRingView(size: 20, revolutionDuration: 2.5, tintColor: DesignSystem.Colors.accent)
                        }

                        Text(engineHeadline(viewModel.engineState))
                            .font(DesignSystem.Typography.sectionTitle)

                        Spacer()
                    }

                    Text(engineDetail(viewModel.engineState))
                        .font(DesignSystem.Typography.bodySmall)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if case .working(_, let progress) = viewModel.engineState {
                        if let progress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .tint(DesignSystem.Colors.accent)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(DesignSystem.Colors.accent)
                        }
                    }

                    if case .failed(let msg) = viewModel.engineState {
                        Text(msg)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(DesignSystem.Spacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                    .fill(DesignSystem.Colors.warningAmber.opacity(0.08))
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Try this:")
                                .font(DesignSystem.Typography.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(engineRecoveryTips(for: msg), id: \.self) { tip in
                                Text("• \(tip)")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            accentButton("Retry", disabled: false) {
                                viewModel.retryEngineWarmUp()
                            }

                            Button("Open Settings") {
                                onOpenSettings()
                            }
                            .parakeetAction(.secondary)
                        }
                    }

                    if case .working(let message, _) = viewModel.engineState {
                        Text(message)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(.default, value: message)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }

            if case .ready = viewModel.engineState {
                Text("Setup complete. You can start dictating immediately.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Done Step

    private var doneStep: some View {
        VStack(alignment: .center, spacing: DesignSystem.Spacing.lg) {
            // Celebration merkaba with particles
            ZStack {
                ParticleField(
                    particleCount: 12,
                    tintColor: DesignSystem.Colors.accent,
                    opacity: 0.35,
                    driftDirection: .orbital
                )
                .frame(width: 180, height: 180)

                MeditativeMerkabaView(size: 96, revolutionDuration: 4.0, tintColor: DesignSystem.Colors.accent)
                    .opacity(0.85)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("You're all set.")
                    .font(DesignSystem.Typography.heroTitle)
                Text("MacParakeet is ready to turn your voice into text.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            onboardingCard {
                VStack(alignment: .leading, spacing: 14) {
                    quickTip(icon: "mic.fill", text: HotkeyTrigger.current.isDisabled
                        ? "Click the dictation pill or set a hotkey in Settings to start dictating"
                        : "\(handsFreeInstructionPhrase) to start dictating anywhere")
                    quickTip(icon: "doc.fill", text: "Drop an audio file onto the main window to transcribe")
                    quickTip(icon: "gearshape", text: "Visit Settings to customize your experience")
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }

    // MARK: - Reusable Helpers

    private func onboardingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(DesignSystem.Colors.cardBackground)
                    .cardShadow(DesignSystem.Shadows.cardRest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
            )
    }

    private func accentButton(_ title: String, icon: String? = nil, large: Bool = false, disabled: Bool, isDefault: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .foregroundStyle(DesignSystem.Colors.onAccent)
            .padding(.horizontal, large ? 20 : 14)
            .padding(.vertical, large ? 10 : 7)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius)
                    .fill(disabled ? DesignSystem.Colors.accent.opacity(0.4) : DesignSystem.Colors.accent)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .keyboardShortcut(isDefault ? .defaultAction : nil)
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DesignSystem.Colors.surfaceElevated)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(DesignSystem.Colors.surfaceElevated)
                    .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
            )
    }

    private func quickTip(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.accent.opacity(0.1))
                )
            Text(text)
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Permission Card

    private enum StatusStyle {
        case ok
        case warn
    }

    private func permissionCard(
        title: String,
        status: String,
        statusStyle: StatusStyle,
        detail: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        onboardingCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title)
                        .font(DesignSystem.Typography.sectionTitle)
                    Spacer()
                    Text(status)
                        .font(DesignSystem.Typography.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(statusStyle == .ok ? DesignSystem.Colors.successGreen.opacity(0.15) : DesignSystem.Colors.warningAmber.opacity(0.15))
                        )
                        .foregroundStyle(statusStyle == .ok ? DesignSystem.Colors.successGreen : DesignSystem.Colors.warningAmber)
                }

                Text(detail)
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    actions()
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Text Helpers

    private func titleForStep(_ step: OnboardingViewModel.Step) -> String {
        switch step {
        case .welcome: return "Welcome to MacParakeet"
        case .microphone: return "Enable Microphone Access"
        case .accessibility: return "Enable Accessibility"
        case .meetingRecording: return "Meeting Recording (Optional)"
        case .calendar: return "Calendar Meetings (Optional)"
        case .hotkey: return "Learn the Hotkey"
        case .engine: return "Prepare Speech Model"
        case .done: return "All Set"
        }
    }

    private func subtitleForStep(_ step: OnboardingViewModel.Step) -> String {
        switch step {
        case .welcome:
            return "A fast, private voice app for Mac. Completely free."
        case .microphone:
            return "MacParakeet needs microphone permission to record your voice."
        case .accessibility:
            return "Accessibility is required for the global hotkey and reliable paste automation."
        case .meetingRecording:
            return "Optional. This is only needed to capture system audio during meeting recording."
        case .calendar:
            return "Optional. Lets MacParakeet remind you before scheduled meetings and enable opt-in auto-start."
        case .hotkey:
            return "Two ways to dictate — pick whichever feels natural."
        case .engine:
            if let recommendation = viewModel.whisperRecommendation {
                return "Preparing local Whisper for \(recommendation.languageName) so dictation works for your Mac language."
            }
            return "The speech model (~6 GB) downloads once. Usually takes 2–5 minutes on broadband, longer on slower connections."
        case .done:
            return "You're all set. Start dictating or transcribe your first file."
        }
    }

    private func primaryButtonTitle(for step: OnboardingViewModel.Step) -> String {
        switch step {
        case .welcome: return "Continue"
        case .microphone: return "Continue"
        case .accessibility: return "Continue"
        case .meetingRecording: return "Continue"
        case .calendar: return "Continue"
        case .hotkey: return "Continue"
        case .engine: return "Continue"
        case .done: return "Finish"
        }
    }

    private func micStatusText(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        }
    }

    private func micStatusStyle(_ status: PermissionStatus) -> StatusStyle {
        switch status {
        case .granted: return .ok
        case .denied, .notDetermined: return .warn
        }
    }

    private func engineHeadline(_ state: OnboardingViewModel.EngineState) -> String {
        switch state {
        case .idle: return "Not started"
        case .working(_, _): return "Working\u{2026}"
        case .ready: return "Ready"
        case .failed: return "Needs attention"
        }
    }

    private func engineDetail(_ state: OnboardingViewModel.EngineState) -> String {
        if let recommendation = viewModel.whisperRecommendation {
            switch state {
            case .idle:
                return "Whisper Large v3 Turbo (~632 MB) will download once, then run fully on-device with \(recommendation.languageName) selected."
            case .working(_, _):
                return "Preparing local Whisper for \(recommendation.languageName). Audio stays on this Mac; no cloud STT is used."
            case .ready:
                return "Whisper is ready for \(recommendation.languageName) dictation and transcription."
            case .failed:
                return "Whisper setup failed. Please retry to complete multilingual speech setup."
            }
        }

        switch state {
        case .idle:
            return "The speech model (~6 GB) will download now. Internet is required this one time only."
        case .working(_, _):
            return "Downloading the speech model (~6 GB). This is a one-time download — dictation and transcription work fully offline after this."
        case .ready:
            return "Parakeet speech model is ready."
        case .failed:
            return "Setup failed. Please retry to complete model preparation."
        }
    }

    private func engineRecoveryTips(for message: String) -> [String] {
        let lower = message.lowercased()

        if lower.contains("network") || lower.contains("internet") || lower.contains("timed out") {
            return [
                "Check your internet connection, then retry setup.",
                "Use a stable network until the speech model finishes downloading.",
                "If it keeps failing, open Settings > Engine > Local Models and run Repair."
            ]
        }

        if lower.contains("space") || lower.contains("disk") || lower.contains("no space") {
            return [
                "Free at least 7 GB of disk space.",
                "Retry setup after storage is available.",
                "You can also run Repair in Settings > Engine > Local Models."
            ]
        }

        if lower.contains("permission denied") || lower.contains("operation not permitted") || lower.contains("read-only") {
            return [
                "Confirm the app can write to your user Library folder.",
                "Restart MacParakeet, then retry setup.",
                "If needed, run Repair in Settings > Engine > Local Models."
            ]
        }

        if lower.contains("unsupported") || lower.contains("apple silicon") {
            return [
                "MacParakeet requires an Apple Silicon Mac (M1 or newer).",
                "Unfortunately, Intel-based Macs aren't supported."
            ]
        }

        return [
            "Retry setup first (temporary failures are common).",
            "If it keeps failing, open Settings > Engine > Local Models and run Repair.",
            "If the error persists, restart the app and retry once."
        ]
    }

    private func openPrivacySettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private var progressStrip: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Setup Progress")
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(currentStepIndex)/\(totalSteps)")
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(.tertiary)
            }

            ProgressView(value: onboardingProgress)
                .progressViewStyle(.linear)
                .tint(DesignSystem.Colors.accent)
        }
        .padding(.top, 4)
    }

    private var continueHint: String? {
        if viewModel.isBusy {
            return "Working..."
        }
        guard !viewModel.canContinueFromCurrentStep() else {
            return nil
        }

        switch viewModel.step {
        case .microphone:
            return "Grant microphone access to continue."
        case .accessibility:
            return "Enable Accessibility to continue."
        case .meetingRecording, .calendar:
            return nil
        case .engine:
            if viewModel.whisperRecommendation != nil {
                return "Preparing Whisper — this can take several minutes. Everything works offline after setup."
            }
            return "Downloading — this can take several minutes. Everything works offline after setup."
        case .welcome, .hotkey, .done:
            return nil
        }
    }

    private var continueButtonDisabled: Bool {
        return !viewModel.canContinueFromCurrentStep() || viewModel.isBusy
    }
}
