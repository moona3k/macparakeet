import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct OnboardingFlowView: View {
    @Bindable var viewModel: OnboardingViewModel
    let onFinish: () -> Void
    let onOpenMainApp: () -> Void

    private let windowWidth: CGFloat = 740
    private let windowHeight: CGFloat = 480

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(width: windowWidth, height: windowHeight)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).opacity(0.92),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onAppear { viewModel.refresh() }
        // When the user grants permissions in System Settings, they return to the app.
        // Refresh so badges and "Continue" enablement update immediately.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refresh()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.ultraThinMaterial))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacParakeet")
                            .font(.system(size: 15, weight: .semibold))
                        Text("First-time setup")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, DesignSystem.Spacing.xl)
            .padding(.horizontal, DesignSystem.Spacing.xl)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(OnboardingViewModel.Step.allCases) { step in
                    stepRow(step)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Label("Local-first. No audio uploads.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("Cmd+V paste requires Accessibility.", systemImage: "keyboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignSystem.Spacing.xl)
            .padding(.bottom, DesignSystem.Spacing.xl)
        }
        .frame(minWidth: 220, maxWidth: 260, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func stepRow(_ step: OnboardingViewModel.Step) -> some View {
        let isSelected = viewModel.step == step
        let isCompleted = stepIsCompleted(step)

        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                    .frame(width: 26, height: 26)
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isCompleted ? Color.accentColor : .secondary)
            }

            Text(step.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Only allow forward navigation to already-completed steps; otherwise keep it linear.
            if step.rawValue <= viewModel.step.rawValue || stepIsCompleted(step) {
                viewModel.jump(to: step)
            }
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

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(titleForStep(viewModel.step))
                    .font(.system(size: 22, weight: .semibold))
                Text(subtitleForStep(viewModel.step))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)

            Divider()
                .padding(.top, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepBody(viewModel.step)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }

            Divider()

            footer
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") {
                viewModel.goBack()
            }
            .disabled(viewModel.step == .welcome || viewModel.isBusy)

            Spacer()

            if viewModel.step == .done {
                Button("Open MacParakeet") {
                    _ = viewModel.markOnboardingCompleted()
                    onFinish()
                    onOpenMainApp()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(primaryButtonTitle(for: viewModel.step)) {
                    if viewModel.step == .engine {
                        viewModel.goNext()
                        return
                    }
                    viewModel.goNext()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canContinueFromCurrentStep() || viewModel.isBusy)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func stepBody(_ step: OnboardingViewModel.Step) -> some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 12) {
                featureRow(
                    icon: "waveform.and.mic",
                    title: "Dictate anywhere",
                    detail: "Double-tap Fn to start. Press Fn again to stop and paste."
                )
                featureRow(
                    icon: "bolt.fill",
                    title: "Fast loop",
                    detail: "You’ll get text where your cursor is, without switching apps."
                )
                featureRow(
                    icon: "lock.shield.fill",
                    title: "Local-first",
                    detail: "Audio stays on your Mac. No uploads."
                )
            }

        case .microphone:
            permissionCard(
                title: "Microphone access",
                status: micStatusText(viewModel.micStatus),
                statusStyle: micStatusStyle(viewModel.micStatus),
                detail: "Required to record your voice for dictation."
            ) {
                Button(viewModel.isBusy ? "Requesting..." : "Grant Microphone Access") {
                    viewModel.requestMicrophoneAccess()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || viewModel.micStatus == .granted)

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
                detail: "Required for the global Fn hotkey and Cmd+V paste automation."
            ) {
                Button("Enable Accessibility") {
                    viewModel.requestAccessibilityAccess(prompt: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || viewModel.accessibilityGranted)

                Button("Open System Settings") {
                    openPrivacySettings(anchor: "Privacy_Accessibility")
                }
            }

        case .hotkey:
            VStack(alignment: .leading, spacing: 14) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Start dictation: double-tap Fn", systemImage: "hand.tap")
                        Label("Stop & paste: press Fn again", systemImage: "arrow.down.doc")
                        Label("Cancel: Esc", systemImage: "escape")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Tip: If your keyboard doesn’t send Fn events, you can still use file transcription from the main app window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .engine:
            engineSetupView
                .onAppear {
                    let venvPython = URL(fileURLWithPath: AppPaths.pythonVenvDir, isDirectory: true)
                        .appendingPathComponent("bin/python", isDirectory: false)
                    let isFirstRun = !FileManager.default.fileExists(atPath: venvPython.path)
                    viewModel.startEngineWarmUp(isFirstRun: isFirstRun)
                }

        case .done:
            VStack(alignment: .leading, spacing: 12) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("You’re ready.")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Double-tap Fn to start dictation. The transcript will paste into your active app.")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("You can revisit this setup anytime from Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var engineSetupView: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        switch viewModel.engineState {
                        case .ready:
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        case .failed:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        case .skipped:
                            Image(systemName: "clock.fill")
                                .foregroundStyle(.secondary)
                        case .idle, .working:
                            ProgressView()
                                .controlSize(.small)
                        }

                        Text(engineHeadline(viewModel.engineState))
                            .font(.system(size: 13, weight: .semibold))

                        Spacer()
                    }

                    Text(engineDetail(viewModel.engineState))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if case .failed(let msg) = viewModel.engineState {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        HStack {
                            Button("Retry") {
                                let venvPython = URL(fileURLWithPath: AppPaths.pythonVenvDir, isDirectory: true)
                                    .appendingPathComponent("bin/python", isDirectory: false)
                                let isFirstRun = !FileManager.default.fileExists(atPath: venvPython.path)
                                viewModel.retryEngineWarmUp(isFirstRun: isFirstRun)
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Do This Later") {
                                viewModel.skipEngineWarmUp()
                            }
                        }
                    } else if case .working = viewModel.engineState {
                        HStack {
                            Button("Continue in Background") {
                                viewModel.skipEngineWarmUp()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if case .working(let message) = viewModel.engineState {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if case .ready = viewModel.engineState {
                Text("Setup complete. You can start dictating immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

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
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(status)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(statusStyle == .ok ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                        )
                        .foregroundStyle(statusStyle == .ok ? Color.green : Color.orange)
                }

                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    actions()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func titleForStep(_ step: OnboardingViewModel.Step) -> String {
        switch step {
        case .welcome: return "Welcome to MacParakeet"
        case .microphone: return "Enable microphone access"
        case .accessibility: return "Enable Accessibility"
        case .hotkey: return "Learn the hotkey"
        case .engine: return "Prepare local speech engine"
        case .done: return "All set"
        }
    }

    private func subtitleForStep(_ step: OnboardingViewModel.Step) -> String {
        switch step {
        case .welcome:
            return "A premium, local-first dictation tool that stays out of your way."
        case .microphone:
            return "MacParakeet needs microphone permission to record your voice."
        case .accessibility:
            return "Accessibility is required for the global Fn hotkey and reliable paste automation."
        case .hotkey:
            return "You can start dictating from any app without switching context."
        case .engine:
            return "First run may install dependencies. After this, startup is fast."
        case .done:
            return "You’re ready to dictate and transcribe locally on your Mac."
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
        case .working: return "Working…"
        case .ready: return "Ready"
        case .failed: return "Needs attention"
        case .skipped: return "Will set up later"
        }
    }

    private func engineDetail(_ state: OnboardingViewModel.EngineState) -> String {
        switch state {
        case .idle:
            return "We’ll start the speech engine now."
        case .working:
            return "This can take a few minutes on first run. Keep this window open."
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
}
