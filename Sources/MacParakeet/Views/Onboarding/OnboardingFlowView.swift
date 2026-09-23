import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct OnboardingFlowView: View {
    @Bindable var viewModel: OnboardingViewModel
    /// Source of the live dictation bindings and the Edit shortcut sheet.
    /// Nil in previews, where the sheet is hidden and bindings come from
    /// UserDefaults.
    var settingsViewModel: SettingsViewModel?
    let onFinish: () -> Void
    let onOpenSettings: () -> Void
    /// Arms/disarms the no-STT key rehearsal while the Try It card should
    /// light its keys. Defaults to no-ops so previews/tests can omit them.
    var onHotkeyPreviewArm: () -> Void = {}
    var onHotkeyPreviewDisarm: () -> Void = {}
    /// A shortcut recorder in the Edit shortcut sheet started or stopped.
    var onShortcutRecordingChanged: (Bool) -> Void = { _ in }
    /// A dictation binding changed from the Edit shortcut sheet.
    var onShortcutBindingsChanged: () -> Void = {}

    @State private var hoveredStep: OnboardingViewModel.Step?
    @State private var backButtonHovered = false
    @State private var isEditingShortcut = false

    // MARK: - Bindings

    private var handsFreeTrigger: HotkeyTrigger {
        settingsViewModel?.hotkeyTrigger ?? HotkeyTrigger.current
    }

    private var pushToTalkTrigger: HotkeyTrigger {
        settingsViewModel?.pushToTalkHotkeyTrigger
            ?? HotkeyTrigger.current(defaultsKey: HotkeyTrigger.pushToTalkDefaultsKey, fallback: .defaultPushToTalk)
    }

    /// Triggers shown in copy fall back to defaults when disabled so the
    /// instructional text stays readable.
    private var handsFreeDisplayTrigger: HotkeyTrigger {
        handsFreeTrigger.isDisabled ? .defaultDictation : handsFreeTrigger
    }

    private var pushToTalkDisplayTrigger: HotkeyTrigger {
        pushToTalkTrigger.isDisabled ? .defaultPushToTalk : pushToTalkTrigger
    }

    private var usesSharedDictationGesture: Bool {
        HotkeyTrigger.isSharedDictationGesture(
            handsFree: handsFreeDisplayTrigger,
            pushToTalk: pushToTalkDisplayTrigger
        )
    }

    private var handsFreeInstructionPhrase: String {
        "\(usesSharedDictationGesture ? "double-tap" : "tap") \(handsFreeDisplayTrigger.displayName)"
    }

    /// The gesture most people will use next: hold-to-talk when it is set.
    private var primaryGesturePhrase: String {
        if !pushToTalkTrigger.isDisabled || handsFreeTrigger.isDisabled {
            return "hold \(pushToTalkDisplayTrigger.displayName)"
        }
        return handsFreeInstructionPhrase
    }

    /// The rehearsal owns the key only on Try It, before the box listens, and
    /// never while a recorder is capturing (the sheet pauses it separately).
    private var shouldRehearse: Bool {
        viewModel.step == .practice && !viewModel.isPracticeListening
    }

    private let windowSize = OnboardingWindowController.windowSize

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
        .frame(width: windowSize.width, height: windowSize.height)
        .background(DesignSystem.Colors.background)
        .onAppear {
            viewModel.markOnboardingShown()
            viewModel.startPermissionPolling()
            // Kick the speech-model download off at onboarding open so it
            // overlaps permissions and the key rehearsal (ADR 005, 2026-06-14).
            // The Parakeet-vs-Whisper fork is already decided in the VM init,
            // and startEngineWarmUp() is idempotent.
            viewModel.startEngineWarmUp()
        }
        .onDisappear {
            viewModel.stopPermissionPolling()
            onHotkeyPreviewDisarm()
        }
        .onChange(of: shouldRehearse, initial: true) { _, rehearse in
            if rehearse {
                viewModel.refreshAccessibilityPermission()
                onHotkeyPreviewArm()
            } else {
                onHotkeyPreviewDisarm()
            }
        }
        .onChange(of: handsFreeTrigger) { _, _ in onShortcutBindingsChanged() }
        .onChange(of: pushToTalkTrigger) { _, _ in onShortcutBindingsChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refresh()
        }
        .sheet(isPresented: $isEditingShortcut) {
            if let settingsViewModel {
                OnboardingShortcutEditor(
                    settingsViewModel: settingsViewModel,
                    onRecordingStateChanged: onShortcutRecordingChanged,
                    onDone: { isEditingShortcut = false }
                )
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
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
                .animation(.easeInOut(duration: 0.3), value: onboardingProgress)

            Spacer()

            speechModelStatus
                .padding(.horizontal, DesignSystem.Spacing.xl)

            VStack(alignment: .leading, spacing: 6) {
                Label("Audio stays on your Mac.", systemImage: "lock.shield")
                Label("Non-identifying metrics.", systemImage: "chart.bar.xaxis")
            }
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DesignSystem.Spacing.xl)
            .padding(.bottom, DesignSystem.Spacing.xl)
        }
        .frame(width: 236, alignment: .leading)
        .background(DesignSystem.Colors.surfaceElevated)
    }

    /// The model download runs behind every step, so its status lives here
    /// instead of on a step of its own.
    private var speechModelStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                switch viewModel.engineState {
                case .ready:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.successGreen)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignSystem.Colors.warningAmber)
                case .idle, .working:
                    ProgressView().controlSize(.mini)
                }
                Text(speechModelStatusText)
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if case .working(_, let progress?) = viewModel.engineState {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(DesignSystem.Typography.micro.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if case .working(_, let progress) = viewModel.engineState {
                Group {
                    if let progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .tint(DesignSystem.Colors.accent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignSystem.Colors.cardBackground.opacity(0.7))
        )
        .accessibilityElement(children: .combine)
    }

    private var speechModelStatusText: String {
        let name = viewModel.whisperRecommendation == nil ? "Speech model" : "Whisper model"
        switch viewModel.engineState {
        case .idle, .working: return "\(name) downloading"
        case .ready: return "\(name) ready"
        case .failed: return "\(name) needs attention"
        }
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
                .fill(
                    isSelected
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
            // Jump back freely. Jumping ahead is limited to steps already done
            // so the Try It gates cannot be bypassed from the sidebar.
            if step.rawValue <= viewModel.step.rawValue {
                viewModel.jump(to: step)
            }
        }
    }

    private func stepIcon(_ step: OnboardingViewModel.Step) -> String {
        switch step {
        case .welcome: return "hand.wave"
        case .permissions: return "lock.open"
        case .practice: return "keyboard"
        case .done: return "checkmark.circle"
        }
    }

    private func stepIsCompleted(_ step: OnboardingViewModel.Step) -> Bool {
        switch step {
        case .welcome:
            return viewModel.step.rawValue > step.rawValue
        case .permissions:
            return viewModel.accessibilityGranted && viewModel.step.rawValue > step.rawValue
        case .practice:
            return viewModel.hasPracticeResult
        case .done:
            return viewModel.hasCompletedCurrentRun
        }
    }

    // MARK: - Content Area

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(DesignSystem.Typography.pageTitle)
                    .contentTransition(.opacity)
                Text(subtitle)
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .animation(.easeInOut(duration: 0.2), value: title)
            .padding(.horizontal, 28)
            .padding(.top, 24)

            SacredGeometryDivider()
                .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepBody(viewModel.step)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
            }
            .id(viewModel.step)
            .transition(
                .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                )
            )
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
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            HStack {
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

                if viewModel.step == .practice, !viewModel.hasPracticeResult {
                    Button("Skip for now") {
                        viewModel.skipPractice()
                    }
                    .parakeetAction(.subtle)
                    .padding(.trailing, 4)
                }

                if viewModel.step == .done {
                    OnboardingAccentButton(title: "Finish", icon: "checkmark", large: true, isDefault: true) {
                        _ = viewModel.markOnboardingCompleted()
                        onFinish()
                    }
                } else {
                    OnboardingAccentButton(
                        title: primaryButtonTitle,
                        icon: "arrow.right",
                        disabled: continueButtonDisabled,
                        // Return in the practice box is a newline, not Continue.
                        isDefault: !viewModel.isPracticeListening
                    ) {
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
        case .permissions:
            permissionsStep
        case .practice:
            OnboardingPracticeStepView(
                viewModel: viewModel,
                handsFreeTrigger: handsFreeTrigger,
                pushToTalkTrigger: pushToTalkTrigger,
                canEditShortcut: settingsViewModel != nil,
                onEditShortcut: { isEditingShortcut = true },
                onOpenSettings: onOpenSettings
            )
        case .done:
            doneStep
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            ZStack {
                SeedOfLifeBackdrop()
                    .frame(width: 124, height: 124)
                ParticleField(
                    particleCount: 8,
                    tintColor: DesignSystem.Colors.accent,
                    opacity: 0.3,
                    driftDirection: .orbital
                )
                .frame(width: 104, height: 104)

                MeditativeMerkabaView(size: 56, revolutionDuration: 5.0, tintColor: DesignSystem.Colors.accent)
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
                    detail:
                        "Hold \(pushToTalkDisplayTrigger.displayName) and talk, or \(handsFreeInstructionPhrase) for hands-free. Text appears where your cursor is."
                )
                featureRow(
                    icon: "keyboard",
                    title: "Try it before you leave",
                    detail:
                        "Two permissions, then your first dictation right here in this window. The speech model downloads while you set up."
                )
                featureRow(
                    icon: "lock.shield.fill",
                    title: "Private by default",
                    detail:
                        "Audio and transcripts stay on your Mac. Setup telemetry is limited to non-identifying step and timing signals."
                )
            }
        }
    }

    // MARK: - Permissions

    private var allPermissionsGranted: Bool {
        viewModel.accessibilityGranted && viewModel.micStatus == .granted
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            permissionRow(
                icon: "mic.fill",
                title: "Hear you while you dictate",
                detail:
                    "The microphone is used only while your dictation key is active. Skip this if you only transcribe files.",
                tag: "Optional",
                granted: viewModel.micStatus == .granted
            ) {
                if viewModel.micStatus == .denied {
                    Button("Open Settings") {
                        openPrivacySettings(anchor: "Privacy_Microphone")
                    }
                    .parakeetAction(.secondary)
                } else {
                    OnboardingAccentButton(
                        title: viewModel.isBusy ? "Asking..." : "Allow",
                        disabled: viewModel.isBusy
                    ) {
                        viewModel.requestMicrophoneAccess()
                    }
                }
            } footnote: {
                if viewModel.micStatus == .denied {
                    Text("Microphone access is off. Turn on MacParakeet in System Settings, or continue without it.")
                }
            }

            permissionRow(
                icon: "keyboard.fill",
                title: "Use your dictation key and type into any app",
                detail:
                    "Lets MacParakeet notice your dictation key from any app and paste your words where the cursor is.",
                tag: "Required",
                granted: viewModel.accessibilityGranted
            ) {
                OnboardingAccentButton(title: "Allow", disabled: viewModel.isBusy) {
                    viewModel.requestAccessibilityAccess(prompt: true)
                }
            } footnote: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("macOS opens Privacy & Security. Turn on MacParakeet there, and this page updates by itself.")
                    Button("Open System Settings") {
                        openPrivacySettings(anchor: "Privacy_Accessibility")
                    }
                    .buttonStyle(.link)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(DesignSystem.Colors.accent)
                Text("MacParakeet does not ask for screen recording, meeting audio, or your calendar during setup.")
                    .foregroundStyle(.secondary)
            }
            .font(DesignSystem.Typography.caption)
            .padding(.top, 4)
        }
    }

    private func permissionRow<Action: View, Footnote: View>(
        icon: String,
        title: String,
        detail: String,
        tag: String,
        granted: Bool,
        @ViewBuilder action: () -> Action,
        @ViewBuilder footnote: () -> Footnote
    ) -> some View {
        OnboardingCard(highlighted: granted) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(granted ? DesignSystem.Colors.successGreen : DesignSystem.Colors.accent)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(
                                    granted
                                        ? DesignSystem.Colors.successGreen.opacity(0.12)
                                        : DesignSystem.Colors.accent.opacity(0.1))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(DesignSystem.Typography.body.weight(.semibold))
                            Text(tag)
                                .font(DesignSystem.Typography.micro)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                        }
                        Text(detail)
                            .font(DesignSystem.Typography.bodySmall)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    if granted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .font(DesignSystem.Typography.caption.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.successGreen)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        action()
                    }
                }

                if !granted {
                    footnote()
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 46)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: granted)
        }
    }

    // MARK: - Done

    private var doneStep: some View {
        VStack(alignment: .center, spacing: 12) {
            ZStack {
                SeedOfLifeBackdrop(glow: true)
                    .frame(width: 120, height: 120)
                ParticleField(
                    particleCount: 12,
                    tintColor: DesignSystem.Colors.accent,
                    opacity: 0.35,
                    driftDirection: .orbital
                )
                .frame(width: 116, height: 116)

                MeditativeMerkabaView(size: 60, revolutionDuration: 4.0, tintColor: DesignSystem.Colors.accent)
                    .opacity(0.85)
            }
            .frame(maxWidth: .infinity)

            Text("You're all set.")
                .font(DesignSystem.Typography.heroTitle)
                .frame(maxWidth: .infinity)

            OnboardingCard {
                VStack(alignment: .leading, spacing: 12) {
                    doneResult

                    Divider()

                    doneLine(
                        icon: "arrow.up.forward.app",
                        text:
                            "Next, click into any app you use, like Mail or Notes, and \(primaryGesturePhrase) there. Your words land at the cursor."
                    )
                    doneLine(
                        icon: "menubar.rectangle",
                        text: "MacParakeet stays in your menu bar. Settings and your dictation history live there."
                    )
                }
                .padding(DesignSystem.Spacing.md)
            }
        }
    }

    @ViewBuilder
    private var doneResult: some View {
        if let transcript = viewModel.practiceTranscript, viewModel.hasPracticeResult {
            VStack(alignment: .leading, spacing: 8) {
                Label("Your first dictation worked", systemImage: "checkmark.seal.fill")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(DesignSystem.Colors.accent)
                        .frame(width: 3)
                    Text("\u{201C}\(transcript)\u{201D}")
                        .font(DesignSystem.Typography.bodySmall)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            switch viewModel.engineState {
            case .ready:
                doneLine(icon: "mic.fill", text: "Dictation is ready whenever you are.")
            case .failed:
                doneLine(
                    icon: "exclamationmark.triangle.fill",
                    text:
                        "The speech model did not finish. Open Settings > Speech Model to retry the download before you dictate."
                )
            case .idle, .working:
                doneLine(
                    icon: "arrow.down.circle",
                    text: "The speech model is still downloading. Dictation works as soon as it finishes."
                )
            }
        }
    }

    private func doneLine(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesignSystem.Colors.accent.opacity(0.1))
                )
            Text(text)
                .font(DesignSystem.Typography.bodySmall)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func openPrivacySettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Text

    private var title: String {
        switch viewModel.step {
        case .welcome: return "Welcome to MacParakeet"
        case .permissions:
            return allPermissionsGranted ? "Thanks for trusting MacParakeet" : "Give MacParakeet two permissions"
        case .practice:
            return viewModel.practicePhase == .hotkey ? "Try your dictation key" : "Now say something"
        case .done: return "All Set"
        }
    }

    private var subtitle: String {
        switch viewModel.step {
        case .welcome:
            return "Two permissions and one practice dictation. The speech model downloads in the background."
        case .permissions:
            return allPermissionsGranted
                ? "Your audio and transcripts stay on this Mac."
                : "macOS asks for each one. You stay on this page while it does."
        case .practice:
            if viewModel.practicePhase == .hotkey {
                return "Press the real key. It lights up in the card when MacParakeet hears it."
            }
            return "Use the key you just tried. Your words land in the box below."
        case .done:
            return "Finish closes this window. Dictation works in any app from here on."
        }
    }

    private var primaryButtonTitle: String {
        switch viewModel.step {
        case .permissions:
            return viewModel.accessibilityGranted && viewModel.micStatus != .granted
                ? "Continue without microphone" : "Continue"
        case .welcome, .practice, .done:
            return "Continue"
        }
    }

    private var continueHint: String? {
        if viewModel.isBusy {
            return "Working..."
        }
        guard !viewModel.canContinueFromCurrentStep() else {
            return nil
        }

        switch viewModel.step {
        case .welcome, .done:
            return nil
        case .permissions:
            return "Allow the dictation key and paste to continue."
        case .practice:
            if viewModel.practicePhase == .hotkey {
                return "Press your key once to continue."
            }
            switch viewModel.practiceBoxState {
            case .loading:
                return "The box opens when the speech model is ready."
            case .failed:
                return "Retry the download, or skip for now."
            case .waitingForKey, .clickToStart:
                return "Click the box, then use your key."
            case .listening:
                return "Continue unlocks when your words land in the box."
            }
        }
    }

    private var continueButtonDisabled: Bool {
        !viewModel.canContinueFromCurrentStep() || viewModel.isBusy
    }
}
