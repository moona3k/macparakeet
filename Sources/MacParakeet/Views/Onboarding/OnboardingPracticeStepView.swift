import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// The Try It step: prove the real key inside the card, then dictate into a
/// real text box on the same screen. The box stays closed until the speech
/// model is ready, so the download fills the time spent on the key.
struct OnboardingPracticeStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    let handsFreeTrigger: HotkeyTrigger
    let pushToTalkTrigger: HotkeyTrigger
    let canEditShortcut: Bool
    let onEditShortcut: () -> Void
    let onOpenSettings: () -> Void

    @FocusState private var boxFocused: Bool
    @State private var clickTargetHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var usesSharedGesture: Bool {
        HotkeyTrigger.isSharedDictationGesture(handsFree: handsFreeTrigger, pushToTalk: pushToTalkTrigger)
    }

    private var hasAnyKey: Bool {
        !handsFreeTrigger.isDisabled || !pushToTalkTrigger.isDisabled
    }

    private var handsFreeCaption: String {
        usesSharedGesture ? "Double-tap" : "Tap"
    }

    private var isDictationPhase: Bool {
        viewModel.practicePhase == .dictation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isDictationPhase {
                compactKeyCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                keyCard
                    .transition(.opacity)
            }
            boxCard
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: isDictationPhase)
        .onChange(of: viewModel.practiceBoxState) { _, state in
            if state == .listening {
                focusBoxSoon()
            }
        }
        .onChange(of: viewModel.practiceActivity) { _, activity in
            // Keep the box as the paste target for the dictation that just
            // started, even if focus wandered after the click.
            if case .recording = activity {
                boxFocused = true
            }
        }
        .onAppear {
            if viewModel.practiceBoxState == .listening {
                focusBoxSoon()
            }
        }
    }

    private func focusBoxSoon() {
        DispatchQueue.main.async { boxFocused = true }
    }

    // MARK: - Key card

    private var keyCard: some View {
        OnboardingCard(highlighted: viewModel.litKey != nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    OnboardingBeatBadge(number: 1, done: viewModel.hasLitHotkey)
                    Text("Press your dictation key")
                        .font(DesignSystem.Typography.sectionTitle)
                    Spacer()
                    keyStatusPill
                }

                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
                    SeedOfLifeBackdrop(glow: viewModel.litKey != nil)
                        .padding(8)
                    if hasAnyKey {
                        HStack(spacing: 36) {
                            if !pushToTalkTrigger.isDisabled {
                                OnboardingKeyCap(
                                    trigger: pushToTalkTrigger,
                                    caption: "Hold",
                                    isLit: viewModel.litKey == .pushToTalk
                                )
                            }
                            if !handsFreeTrigger.isDisabled {
                                OnboardingKeyCap(
                                    trigger: handsFreeTrigger,
                                    caption: handsFreeCaption,
                                    isLit: viewModel.litKey == .handsFree
                                )
                            }
                        }
                    } else {
                        Text("No dictation key is set. Choose one with Edit shortcut.")
                            .font(DesignSystem.Typography.bodySmall)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 108)

                Text(keyInstruction)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    if canEditShortcut {
                        Button(action: onEditShortcut) {
                            Label("Edit shortcut", systemImage: "pencil")
                        }
                        .parakeetAction(.secondary)
                    }
                    Spacer()
                    escapeRow
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private var keyStatusPill: some View {
        Group {
            if !viewModel.accessibilityGranted {
                statusPill(
                    "Needs hotkey access", icon: "exclamationmark.triangle.fill",
                    color: DesignSystem.Colors.warningAmber)
            } else if viewModel.hasLitHotkey {
                statusPill("Your key works", icon: "checkmark.circle.fill", color: DesignSystem.Colors.successGreen)
            } else {
                statusPill("Waiting for a press", icon: "hand.tap", color: .secondary)
            }
        }
    }

    private func statusPill(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(DesignSystem.Typography.micro.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var keyInstruction: String {
        guard viewModel.accessibilityGranted else {
            return "The key can't reach MacParakeet without hotkey access. Go Back to Permissions to allow it."
        }
        guard hasAnyKey else {
            return "Pick a key for dictation, then press it here."
        }
        var parts: [String] = []
        if !pushToTalkTrigger.isDisabled {
            parts.append("Hold \(pushToTalkTrigger.displayName) to talk")
        }
        if !handsFreeTrigger.isDisabled {
            parts.append("\(handsFreeCaption.lowercased()) \(handsFreeTrigger.displayName) for hands-free")
        }
        let joined = parts.joined(separator: ", or ")
        return
            "\(joined.prefix(1).uppercased() + joined.dropFirst()). The key lights up while it's active. Nothing is recorded yet."
    }

    private var escapeRow: some View {
        HStack(spacing: 6) {
            InlineKeyCap(label: "esc")
            Text("cancels")
            Text("·").foregroundStyle(.tertiary)
            Text("5-second undo").foregroundStyle(.tertiary)
        }
        .font(DesignSystem.Typography.caption)
        .foregroundStyle(.secondary)
    }

    private var compactKeyCard: some View {
        OnboardingCard {
            HStack(spacing: 10) {
                OnboardingBeatBadge(number: 1, done: true)
                Text("Your key works")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                HStack(spacing: 4) {
                    if !pushToTalkTrigger.isDisabled {
                        InlineKeyCap(label: pushToTalkTrigger.shortSymbol, isLit: litInBox == .pushToTalk)
                    }
                    if !handsFreeTrigger.isDisabled && !usesSharedGesture {
                        InlineKeyCap(label: handsFreeTrigger.shortSymbol, isLit: litInBox == .handsFree)
                    }
                }
                Spacer()
                if canEditShortcut {
                    Button(action: onEditShortcut) {
                        Label("Edit shortcut", systemImage: "pencil")
                    }
                    .parakeetAction(.subtle)
                    // Recording a new shortcut stands the production taps
                    // down; never do that under a live dictation.
                    .disabled(viewModel.practiceActivity != .idle)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, 10)
        }
    }

    /// The key that is active in the real dictation flow while the box listens.
    private var litInBox: OnboardingViewModel.PracticeKey? {
        if case .recording(let key) = viewModel.practiceActivity { return key }
        return nil
    }

    // MARK: - Box card

    private var boxCard: some View {
        OnboardingCard(highlighted: viewModel.practiceBoxState == .listening) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    OnboardingBeatBadge(number: 2, done: viewModel.hasPracticeResult)
                    Text("Dictate into this box")
                        .font(DesignSystem.Typography.sectionTitle)
                        .foregroundStyle(isDictationPhase ? .primary : .secondary)
                    Spacer()
                    if viewModel.whisperRecommendation != nil {
                        Text("Whisper · \(viewModel.whisperRecommendation?.languageName ?? "")")
                            .font(DesignSystem.Typography.micro)
                            .foregroundStyle(.secondary)
                    }
                }

                box
                    .frame(height: isDictationPhase ? boxHeight : 76)

                if isDictationPhase, viewModel.hasPracticeResult {
                    HStack(spacing: 10) {
                        Label("Those words came from your voice, on this Mac.", systemImage: "checkmark.seal.fill")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.successGreen)
                        Spacer()
                        Button {
                            viewModel.resetPracticeResult()
                            boxFocused = true
                        } label: {
                            Label("Try again", systemImage: "arrow.counterclockwise")
                        }
                        .parakeetAction(.secondary)
                    }
                    .transition(.opacity)
                } else if isDictationPhase, viewModel.practiceBoxState == .listening, viewModel.micStatus != .granted {
                    Label("macOS will ask for the microphone the first time you dictate.", systemImage: "mic")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private var boxHeight: CGFloat {
        if case .failed = viewModel.practiceBoxState { return 176 }
        return 150
    }

    @ViewBuilder
    private var box: some View {
        switch viewModel.practiceBoxState {
        case .loading(let message, let progress):
            boxFrame(dashed: true) {
                if isDictationPhase {
                    loadingContent(message: message, progress: progress)
                } else {
                    compactLoadingContent(progress: progress)
                }
            }
        case .failed(let failure):
            boxFrame(dashed: true) { failureContent(failure) }
        case .waitingForKey:
            boxFrame(dashed: true) {
                boxMessage(
                    icon: "keyboard",
                    title: "Ready when your key is",
                    detail: "Press your key above, then Continue."
                )
            }
        case .clickToStart:
            Button {
                viewModel.armPracticeBox()
            } label: {
                boxFrame(dashed: false, emphasized: true) {
                    VStack(spacing: 8) {
                        Image(systemName: "cursorarrow.click.2")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(DesignSystem.Colors.accent)
                        Text("Click here to start")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Your words land wherever the cursor is. Here, that's this box.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .onHover { clickTargetHovered = $0 }
            .accessibilityLabel("Click here to start dictating into the practice box")
        case .listening:
            listeningBox
        }
    }

    private func boxFrame<Content: View>(
        dashed: Bool,
        emphasized: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        emphasized && clickTargetHovered
                            ? DesignSystem.Colors.accent.opacity(0.06)
                            : DesignSystem.Colors.contentBackground.opacity(dashed ? 0.4 : 1)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        emphasized
                            ? DesignSystem.Colors.accent.opacity(clickTargetHovered ? 0.9 : 0.55)
                            : DesignSystem.Colors.border,
                        style: StrokeStyle(lineWidth: emphasized ? 1.5 : 1, dash: dashed ? [5, 4] : [])
                    )
            )
    }

    private func boxMessage(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, DesignSystem.Spacing.md)
    }

    /// One line while the key card is the focus: the box is visibly on its
    /// way without competing with the rehearsal above it.
    private func compactLoadingContent(progress: Double?) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Getting the speech model ready")
                    .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                if let progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(DesignSystem.Typography.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text("One-time download. Try your key above while it finishes.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
    }

    private func loadingContent(message: String, progress: Double?) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Getting the speech model ready")
                    .font(DesignSystem.Typography.bodySmall.weight(.semibold))
            }
            Group {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .tint(DesignSystem.Colors.accent)
            .frame(maxWidth: 260)
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.default, value: message)
            Text("One-time download. This box opens as soon as it's ready.")
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
    }

    private func failureContent(_ failure: OnboardingViewModel.EngineFailure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The speech model needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.warningAmber)
            Text(failure.message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
            ForEach(failure.recovery.tips.prefix(2), id: \.self) { tip in
                Text("• \(tip)")
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                OnboardingAccentButton(title: "Retry") {
                    viewModel.retryEngineWarmUp()
                }
                Button("Open Settings", action: onOpenSettings)
                    .parakeetAction(.secondary)
                Spacer()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    // MARK: - Listening box

    private var listeningBox: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $viewModel.practiceText)
                .font(DesignSystem.Typography.bodyLarge)
                .scrollContentBackground(.hidden)
                .focused($boxFocused)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .accessibilityLabel("Practice dictation box")

            if viewModel.practiceText.isEmpty {
                listeningPlaceholder
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }

            activityBadge
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(8)
                .allowsHitTesting(false)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignSystem.Colors.contentBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    litInBox != nil
                        ? DesignSystem.Colors.accent : DesignSystem.Colors.accent.opacity(boxFocused ? 0.6 : 0.3),
                    lineWidth: litInBox != nil ? 2 : 1.2
                )
        )
        .shadow(color: litInBox != nil ? DesignSystem.Colors.accent.opacity(0.25) : .clear, radius: 8)
        .animation(.easeOut(duration: 0.15), value: litInBox)
    }

    private var listeningPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pushToTalkTrigger.isDisabled {
                HStack(spacing: 5) {
                    Text("Hold")
                    InlineKeyCap(label: pushToTalkTrigger.shortSymbol, isLit: litInBox == .pushToTalk)
                    Text("and say something. Let go when you're done.")
                }
            }
            if !handsFreeTrigger.isDisabled {
                HStack(spacing: 5) {
                    Text(pushToTalkTrigger.isDisabled ? handsFreeCaption : "Or \(handsFreeCaption.lowercased())")
                    InlineKeyCap(label: handsFreeTrigger.shortSymbol, isLit: litInBox == .handsFree)
                    Text("to talk hands-free, then tap it again to finish.")
                }
                .foregroundStyle(.tertiary)
            }
            Text("Try: \u{201C}This is my first dictation, and it stays on my Mac.\u{201D}")
                .italic()
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .font(DesignSystem.Typography.bodySmall)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var activityBadge: some View {
        switch viewModel.practiceActivity {
        case .recording:
            HStack(spacing: 6) {
                ListeningWave()
                Text("Listening")
            }
            .badgeStyle(color: DesignSystem.Colors.accent)
        case .processing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Transcribing")
            }
            .badgeStyle(color: .secondary)
        case .idle:
            EmptyView()
        }
    }
}

private extension View {
    func badgeStyle(color: Color) -> some View {
        self
            .font(DesignSystem.Typography.micro.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(DesignSystem.Colors.cardBackground))
            .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - Shortcut editor

/// Edit shortcut from inside the lesson: the same recorder and conflict rules
/// as Settings, for the two keys the card draws.
struct OnboardingShortcutEditor: View {
    @Bindable var settingsViewModel: SettingsViewModel
    let onRecordingStateChanged: (Bool) -> Void
    let onDone: () -> Void

    private var snapshot: HotkeyConflictPolicy.SettingsSnapshot {
        HotkeyConflictPolicy.SettingsSnapshot(
            handsFree: settingsViewModel.hotkeyTrigger,
            pushToTalk: settingsViewModel.pushToTalkHotkeyTrigger,
            meeting: settingsViewModel.meetingHotkeyTrigger,
            fileTranscription: settingsViewModel.fileTranscriptionHotkeyTrigger,
            youtubeTranscription: settingsViewModel.youtubeTranscriptionHotkeyTrigger,
            dictationAIPolish: settingsViewModel.dictationAIPolishHotkeyTrigger,
            dictationClipboard: settingsViewModel.dictationClipboardHotkeyTrigger,
            transformHotkeys: [],
            meetingRecordingEnabled: AppFeatures.meetingRecordingEnabled
        )
    }

    private var usesSharedGesture: Bool {
        HotkeyTrigger.isSharedDictationGesture(
            handsFree: settingsViewModel.hotkeyTrigger,
            pushToTalk: settingsViewModel.pushToTalkHotkeyTrigger
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dictation shortcuts")
                    .font(DesignSystem.Typography.sectionTitle)
                Text("Pick keys you can reach without looking. External keyboards can use keys like F13 or End.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            row(
                title: "Push to talk",
                detail: "Hold to say something short. Release to paste."
            ) {
                HotkeyRecorderView(
                    trigger: $settingsViewModel.pushToTalkHotkeyTrigger,
                    defaultTrigger: .defaultPushToTalk,
                    displayLabelOverride: SettingsDictationHotkeyDisplay.pushToTalkDisplayLabelOverride(
                        pushToTalk: settingsViewModel.pushToTalkHotkeyTrigger,
                        handsFree: settingsViewModel.hotkeyTrigger
                    ),
                    additionalValidation: { candidate in
                        HotkeyConflictPolicy.settingsValidation(
                            candidate: candidate, surface: .pushToTalk, snapshot: snapshot)
                    },
                    onRecordingStateChanged: onRecordingStateChanged
                )
            }

            row(
                title: "Hands-free",
                detail: usesSharedGesture
                    ? "Double-tap to start, tap again to stop and paste."
                    : "Tap to start, tap again to stop and paste."
            ) {
                HotkeyRecorderView(
                    trigger: $settingsViewModel.hotkeyTrigger,
                    defaultTrigger: .defaultDictation,
                    displayLabelOverride: SettingsDictationHotkeyDisplay.handsFreeDisplayLabelOverride(
                        handsFree: settingsViewModel.hotkeyTrigger,
                        pushToTalk: settingsViewModel.pushToTalkHotkeyTrigger
                    ),
                    defaultLabelOverride: SettingsDictationHotkeyDisplay.handsFreeDefaultLabelOverride(
                        pushToTalk: settingsViewModel.pushToTalkHotkeyTrigger
                    ),
                    additionalValidation: { candidate in
                        HotkeyConflictPolicy.settingsValidation(
                            candidate: candidate, surface: .handsFreeDictation, snapshot: snapshot)
                    },
                    onRecordingStateChanged: onRecordingStateChanged
                )
            }

            HStack {
                Button("Reset to default") {
                    settingsViewModel.pushToTalkHotkeyTrigger = .defaultPushToTalk
                    settingsViewModel.hotkeyTrigger = .defaultDictation
                }
                .parakeetAction(.secondary)
                .disabled(
                    settingsViewModel.pushToTalkHotkeyTrigger == .defaultPushToTalk
                        && settingsViewModel.hotkeyTrigger == .defaultDictation
                )
                Spacer()
                OnboardingAccentButton(title: "Done", isDefault: true, action: onDone)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 480)
    }

    private func row<Recorder: View>(
        title: String,
        detail: String,
        @ViewBuilder recorder: () -> Recorder
    ) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.body.weight(.semibold))
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            recorder()
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }
}
