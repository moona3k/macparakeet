import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct OnboardingFlowView: View {
    @Bindable var viewModel: OnboardingViewModel
    let onFinish: () -> Void
    let onOpenMainApp: () -> Void

    private let windowWidth: CGFloat = 740
    private let windowHeight: CGFloat = 500

    @State private var hoveredStep: OnboardingViewModel.Step?
    @State private var backButtonHovered = false

    private var totalSteps: Int { OnboardingViewModel.Step.allCases.count }
    private var currentStepIndex: Int { viewModel.step.rawValue + 1 }
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
        .onAppear { viewModel.refresh() }
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
                ForEach(OnboardingViewModel.Step.allCases) { step in
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
                    accentButton("Open MacParakeet", icon: "arrow.right", large: true, disabled: false) {
                        _ = viewModel.markOnboardingCompleted()
                        onFinish()
                        onOpenMainApp()
                    }
                } else {
                    let disabled = !viewModel.canContinueFromCurrentStep() || viewModel.isBusy
                    accentButton(primaryButtonTitle(for: viewModel.step), icon: "arrow.right", large: false, disabled: disabled) {
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
        case .hotkey:
            hotkeyStep
        case .engine:
            engineSetupView
                .onAppear {
                    let isFirstRun = !STTClient.isModelCached(version: .v3)
                    viewModel.startEngineWarmUp(isFirstRun: isFirstRun)
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
                    detail: "Double-tap \(TriggerKey.current.displayName) for persistent dictation, or hold-to-talk and release to stop. Text appears where your cursor is."
                )
                featureRow(
                    icon: "bolt.fill",
                    title: "155x realtime",
                    detail: "60 minutes of audio transcribed in ~23 seconds on Apple Silicon."
                )
                featureRow(
                    icon: "lock.shield.fill",
                    title: "100% local",
                    detail: "Audio never leaves your Mac. No cloud. No accounts. No tracking."
                )
            }
        }
    }

    // MARK: - Hotkey Step

    private var hotkeyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            onboardingCard {
                VStack(alignment: .leading, spacing: 0) {
                    hotkeyFlowStep(
                        number: 1,
                        key: TriggerKey.current.displayName,
                        label: "Double-tap \(TriggerKey.current.displayName)",
                        detail: "Start dictation from any app",
                        isLast: false
                    )
                    hotkeyFlowStep(
                        number: 2,
                        key: TriggerKey.current.displayName,
                        label: "Tap \(TriggerKey.current.displayName) again",
                        detail: "Stop recording and paste text",
                        isLast: false
                    )
                    hotkeyFlowStep(
                        number: 3,
                        key: TriggerKey.current.displayName,
                        label: "Hold \(TriggerKey.current.displayName)",
                        detail: "Push-to-talk dictation",
                        isLast: false
                    )
                    hotkeyFlowStep(
                        number: 4,
                        key: TriggerKey.current.displayName,
                        label: "Release \(TriggerKey.current.displayName)",
                        detail: "Stop recording and paste text",
                        isLast: false
                    )
                    hotkeyFlowStep(
                        number: 5,
                        key: "Esc",
                        label: "Press Escape",
                        detail: "Cancel (5-second undo window)",
                        isLast: true
                    )
                }
                .padding(DesignSystem.Spacing.lg)
            }

            Text("Tip: If your keyboard doesn't send \(TriggerKey.current.displayName) events, you can still use file transcription from the main app window.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Engine Setup

    private var engineSetupView: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                        case .skipped:
                            Image(systemName: "clock.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
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

                        HStack {
                            accentButton("Retry", disabled: false) {
                                let isFirstRun = !STTClient.isModelCached(version: .v3)
                                viewModel.retryEngineWarmUp(isFirstRun: isFirstRun)
                            }

                            Button("Do This Later") {
                                viewModel.skipEngineWarmUp()
                            }
                        }
                    } else if case .working(_, _) = viewModel.engineState {
                        HStack {
                            Button("Continue in Background") {
                                viewModel.skipEngineWarmUp()
                            }
                            .buttonStyle(.bordered)
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
                    quickTip(icon: "mic.fill", text: "Double-tap \(TriggerKey.current.displayName) to start dictating anywhere")
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

    private func accentButton(_ title: String, icon: String? = nil, large: Bool = false, disabled: Bool, action: @escaping () -> Void) -> some View {
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

    private func hotkeyFlowStep(number: Int, key: String, label: String, detail: String, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                // Number circle
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(DesignSystem.Colors.accent.opacity(0.1))
                    )

                // Key cap
                keyCap(key)

                // Label + detail
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 14, weight: .semibold))
                    Text(detail)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Connecting line
            if !isLast {
                Rectangle()
                    .fill(DesignSystem.Colors.border)
                    .frame(width: 1, height: 16)
                    .padding(.leading, 12) // center under number circle
                    .padding(.vertical, 4)
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
        case .hotkey: return "Learn the Hotkey"
        case .engine: return "Prepare Local Speech Engine"
        case .done: return "All Set"
        }
    }

    private func subtitleForStep(_ step: OnboardingViewModel.Step) -> String {
        switch step {
        case .welcome:
            return "A premium, local-first dictation tool that stays out of your way."
        case .microphone:
            return "MacParakeet needs microphone permission to record your voice."
        case .accessibility:
            return "Accessibility is required for the global hotkey and reliable paste automation."
        case .hotkey:
            return "You can start dictating from any app without switching context."
        case .engine:
            return "First run may download local speech assets. After setup, startup is fast."
        case .done:
            return "You're ready to dictate and transcribe locally on your Mac."
        }
    }

    private func primaryButtonTitle(for step: OnboardingViewModel.Step) -> String {
        switch step {
        case .welcome: return "Continue"
        case .microphone: return "Continue"
        case .accessibility: return "Continue"
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
        case .skipped: return "Will set up later"
        }
    }

    private func engineDetail(_ state: OnboardingViewModel.EngineState) -> String {
        switch state {
        case .idle:
            return "We'll prepare the local speech engine now."
        case .working(_, _):
            return "This can take a few minutes on first run while speech assets download and initialize."
        case .ready:
            return "Local speech engine is running."
        case .failed:
            return "Setup failed. You can retry now, or continue and let the app set up on first use."
        case .skipped:
            return "You can set this up later. Dictation may take longer the first time you use it."
        }
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
        case .engine:
            return "Wait for engine setup to finish, or choose Do This Later."
        case .welcome, .hotkey, .done:
            return nil
        }
    }
}
