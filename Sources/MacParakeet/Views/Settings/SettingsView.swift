import Foundation
import SwiftUI
import AppKit
import MacParakeetCore
import MacParakeetViewModels

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    @State private var showClearAllAlert = false
    @State private var showClearYouTubeAudioAlert = false
    @State private var copiedBuildIdentity = false
    @State private var feedbackViewModel = FeedbackViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                headerCard
                generalCard
                dictationCard
                storageCard
                localModelsCard
                permissionsCard
                onboardingCard
                feedbackCard
                aboutCard
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .alert("Clear All Dictations?", isPresented: $showClearAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                viewModel.clearAllDictations()
            }
        } message: {
            Text("This will permanently delete all \(viewModel.dictationCount) dictation\(viewModel.dictationCount == 1 ? "" : "s") and their audio files. This cannot be undone.")
        }
        .alert("Clear Downloaded YouTube Audio?", isPresented: $showClearYouTubeAudioAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Audio", role: .destructive) {
                viewModel.clearDownloadedYouTubeAudio()
            }
        } message: {
            Text("This will permanently delete all downloaded YouTube audio files and detach them from existing transcriptions.")
        }
        .onAppear {
            viewModel.refreshPermissions()
            viewModel.refreshStats()
            viewModel.refreshEntitlements()
            viewModel.refreshModelStatus()
            feedbackViewModel.configure(feedbackService: FeedbackService())
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        settingsCard(
            title: "Workspace Controls",
            subtitle: "Local-first settings for dictation and transcription.",
            icon: "slider.horizontal.3"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: DesignSystem.Spacing.sm)],
                spacing: DesignSystem.Spacing.sm
            ) {
                statChip(
                    title: "Dictations",
                    value: "\(viewModel.dictationCount)"
                )

                statChip(
                    title: "YouTube Cache",
                    value: "\(formattedYouTubeStorageMB) MB"
                )

                statChip(
                    title: "Microphone",
                    value: viewModel.microphoneGranted ? "Granted" : "Missing",
                    isHealthy: viewModel.microphoneGranted
                )

                statChip(
                    title: "Accessibility",
                    value: viewModel.accessibilityGranted ? "Granted" : "Missing",
                    isHealthy: viewModel.accessibilityGranted
                )
            }
        }
    }

    // MARK: - General

    private var generalCard: some View {
        settingsCard(
            title: "General",
            subtitle: "App behavior and shell presence.",
            icon: "gearshape"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                settingsToggleRow(
                    title: "Menu bar only mode",
                    detail: "Hide the Dock icon and run from the menu bar only.",
                    isOn: $viewModel.menuBarOnlyMode
                )

                Divider()

                settingsToggleRow(
                    title: "Launch at login",
                    detail: "Start MacParakeet automatically when you sign in.",
                    isOn: $viewModel.launchAtLogin
                )
            }
        }
    }

    // MARK: - Dictation

    private var dictationCard: some View {
        settingsCard(
            title: "Dictation",
            subtitle: "Global hotkey and silence behavior.",
            icon: "waveform"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .center) {
                    rowText(
                        title: "Hotkey",
                        detail: "System-wide key used to start and stop dictation."
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    Picker("Hotkey", selection: $viewModel.hotkeyTrigger) {
                        ForEach(TriggerKey.allCases, id: \.rawValue) { key in
                            Text("\(key.shortSymbol) \(key.displayName)").tag(key.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }

                Divider()

                settingsToggleRow(
                    title: "Auto-stop after silence",
                    detail: "Stops recording when speech pauses for the selected delay.",
                    isOn: $viewModel.silenceAutoStop
                )

                if viewModel.silenceAutoStop {
                    Divider()
                    HStack(alignment: .center) {
                        rowText(
                            title: "Silence delay",
                            detail: "How long silence must persist before dictation stops."
                        )
                        Spacer(minLength: DesignSystem.Spacing.md)
                        Picker("Silence delay", selection: $viewModel.silenceDelay) {
                            Text("1 sec").tag(1.0)
                            Text("1.5 sec").tag(1.5)
                            Text("2 sec").tag(2.0)
                            Text("3 sec").tag(3.0)
                            Text("5 sec").tag(5.0)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                }
            }
        }
    }

    // MARK: - Storage

    private var storageCard: some View {
        settingsCard(
            title: "Storage",
            subtitle: "Retention and local helper runtime policy.",
            icon: "internaldrive"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                settingsToggleRow(
                    title: "Save audio recordings",
                    detail: "Keeps dictation audio alongside transcript history.",
                    isOn: $viewModel.saveAudioRecordings
                )

                Divider()

                settingsToggleRow(
                    title: "Keep downloaded YouTube audio",
                    detail: "Enabled by default. Turn off to auto-delete downloaded audio after transcription.",
                    isOn: $viewModel.saveTranscriptionAudio
                )

                Divider()

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: DesignSystem.Spacing.md)],
                    spacing: DesignSystem.Spacing.md
                ) {
                    metricTile(
                        title: "Dictation Records",
                        value: "\(viewModel.dictationCount)",
                        detail: viewModel.dictationCount == 1 ? "entry" : "entries"
                    )

                    metricTile(
                        title: "YouTube Downloads",
                        value: "\(viewModel.youtubeDownloadCount)",
                        detail: "\(formattedYouTubeStorageMB) MB"
                    )
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Maintenance")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Button("Clear All Dictations...", role: .destructive) {
                            showClearAllAlert = true
                        }
                        .buttonStyle(.bordered)

                        Button("Clear Downloaded YouTube Audio...", role: .destructive) {
                            showClearYouTubeAudioAlert = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(DesignSystem.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.errorRed.opacity(0.06))
                )
            }
        }
    }

    // MARK: - Permissions

    private var localModelsCard: some View {
        settingsCard(
            title: "Speech Model",
            subtitle: "Parakeet speech recognition status and repair.",
            icon: "cpu"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                modelStatusRow(
                    title: "Parakeet (Speech)",
                    detail: viewModel.parakeetStatusDetail,
                    status: viewModel.parakeetStatus,
                    isRepairing: viewModel.parakeetRepairing
                ) {
                    viewModel.repairParakeetModel()
                }

                Divider()

                HStack {
                    if let updatedAt = viewModel.modelStatusUpdatedAt {
                        Text("Updated \(updatedAt.formatted(date: .omitted, time: .shortened))")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Check Now") {
                        viewModel.refreshModelStatus()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.parakeetRepairing)

                    Button("Repair") {
                        viewModel.repairParakeetModel()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
                    .disabled(viewModel.parakeetRepairing)
                }
            }
        }
    }

    private var permissionsCard: some View {
        settingsCard(
            title: "Permissions",
            subtitle: "Required for recording and global paste automation.",
            icon: "lock.shield"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack {
                    rowText(title: "Microphone", detail: "Required for voice capture.")
                    Spacer()
                    permissionPill(granted: viewModel.microphoneGranted)
                }

                Divider()

                HStack {
                    rowText(title: "Accessibility", detail: "Required for global hotkey and paste.")
                    Spacer()
                    permissionPill(granted: viewModel.accessibilityGranted)
                }

                if !viewModel.accessibilityGranted {
                    Divider()
                    Button("Open System Settings") {
                        openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
                }
            }
        }
    }

    // MARK: - Onboarding

    private var onboardingCard: some View {
        settingsCard(
            title: "Onboarding",
            subtitle: "Re-run setup flow for permissions and local model warm-up.",
            icon: "list.number"
        ) {
            HStack {
                rowText(
                    title: "Run onboarding again",
                    detail: "Opens first-run setup with guided steps."
                )
                Spacer()
                Button("Open Setup...") {
                    NotificationCenter.default.post(name: .macParakeetOpenOnboarding, object: nil)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.accent)
            }
        }
    }

    // MARK: - Feedback

    private var feedbackCard: some View {
        settingsCard(
            title: "Help & Feedback",
            subtitle: "Report bugs, request features, or share feedback.",
            icon: "bubble.left.and.text.bubble.right"
        ) {
            if feedbackViewModel.submissionState == .success {
                feedbackSuccessBanner
            } else {
                feedbackFormContent
            }
        }
    }

    private var feedbackSuccessBanner: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
            Text("Thank you! Your feedback has been submitted.")
                .font(DesignSystem.Typography.body)
        }
        .foregroundStyle(DesignSystem.Colors.successGreen)
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.successGreen.opacity(0.08))
        )
    }

    private var feedbackFormContent: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            // Category picker
            HStack(alignment: .center) {
                rowText(
                    title: "Category",
                    detail: "What kind of feedback is this?"
                )
                Spacer(minLength: DesignSystem.Spacing.md)
                Picker("Category", selection: $feedbackViewModel.category) {
                    ForEach(FeedbackCategory.allCases, id: \.rawValue) { cat in
                        Text(cat.displayName).tag(cat)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)
            }

            Divider()

            // Message
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Message")
                    .font(DesignSystem.Typography.body)
                TextEditor(text: $feedbackViewModel.message)
                    .font(DesignSystem.Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(DesignSystem.Spacing.sm)
                    .frame(minHeight: 80)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .fill(DesignSystem.Colors.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
                    )
            }

            Divider()

            // Email (optional)
            HStack(alignment: .center) {
                rowText(
                    title: "Email (optional)",
                    detail: "Only if you'd like a reply."
                )
                Spacer(minLength: DesignSystem.Spacing.md)
                TextField("you@example.com", text: $feedbackViewModel.email)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }

            Divider()

            // Screenshot
            HStack(alignment: .center) {
                rowText(
                    title: "Screenshot (optional)",
                    detail: "PNG, JPEG, TIFF, or HEIC. Max 5 MB."
                )
                Spacer(minLength: DesignSystem.Spacing.md)
                if let filename = feedbackViewModel.screenshotFilename {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "photo")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(filename)
                            .font(DesignSystem.Typography.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Remove") {
                            feedbackViewModel.removeScreenshot()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    Button("Attach Screenshot") {
                        feedbackViewModel.attachScreenshot()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            // System info disclosure
            DisclosureGroup("System Info", isExpanded: $feedbackViewModel.showSystemInfo) {
                Text(feedbackViewModel.systemInfo.displaySummary)
                    .font(DesignSystem.Typography.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(DesignSystem.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .fill(DesignSystem.Colors.surfaceElevated)
                    )
            }
            .font(DesignSystem.Typography.body)

            // Error banner
            if case .error(let errorMessage) = feedbackViewModel.submissionState {
                feedbackErrorBanner(errorMessage)
            }

            // Action buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    feedbackViewModel.resetForm()
                }
                .buttonStyle(.bordered)

                Button(feedbackViewModel.submissionState == .submitting ? "Sending..." : "Send Feedback") {
                    feedbackViewModel.submit()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.accent)
                .disabled(!feedbackViewModel.canSubmit)
            }
        }
    }

    private func feedbackErrorBanner(_ error: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
            Text(error)
                .font(DesignSystem.Typography.caption)
                .lineLimit(2)
            Spacer()
            Button {
                feedbackViewModel.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(DesignSystem.Colors.errorRed)
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.errorRed.opacity(0.08))
        )
    }

    // MARK: - About

    private var aboutCard: some View {
        let identity = BuildIdentity.current
        return settingsCard(
            title: "About",
            subtitle: "Build identity and runtime posture.",
            icon: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    SpinnerRingView(size: 18, revolutionDuration: 8.0, tintColor: DesignSystem.Colors.accent)
                        .opacity(0.6)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacParakeet \(identity.version) (\(identity.buildNumber))")
                            .font(DesignSystem.Typography.body)
                        Text("Local-first transcription stack")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(copiedBuildIdentity ? "Copied" : "Copy Build Info") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(buildIdentityReport(identity), forType: .string)
                        copiedBuildIdentity = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.2))
                            copiedBuildIdentity = false
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                aboutRow(label: "Source", value: identity.buildSource)
                aboutRow(label: "Commit", value: identity.gitCommit)
                aboutRow(label: "Built", value: identity.buildDateUTC)
                aboutRow(label: "Executable", value: identity.executablePath)
            }
        }
    }

    // MARK: - Reusable UI

    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignSystem.Colors.accent.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignSystem.Typography.sectionTitle)
                    Text(subtitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    private func settingsToggleRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            rowText(title: title, detail: detail)
            Spacer(minLength: DesignSystem.Spacing.md)
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    private func rowText(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.body)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statChip(title: String, value: String, isHealthy: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignSystem.Typography.body.weight(.semibold))
                .foregroundStyle(isHealthy ? .primary : DesignSystem.Colors.errorRed)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private func metricTile(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignSystem.Typography.sectionTitle)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private func modelStatusRow(
        title: String,
        detail: String,
        status: SettingsViewModel.LocalModelStatus,
        isRepairing: Bool,
        onRepair: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            modelStatusPill(status)

            Button(isRepairing ? "Repairing..." : "Repair") {
                onRepair()
            }
            .buttonStyle(.bordered)
            .disabled(isRepairing)
        }
    }

    // MARK: - Helpers

    private var formattedYouTubeStorageMB: String {
        String(format: "%.1f", viewModel.youtubeDownloadStorageMB)
    }

    private func aboutRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignSystem.Typography.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func buildIdentityReport(_ identity: BuildIdentity) -> String {
        [
            "MacParakeet Build Identity",
            "Version: \(identity.version)",
            "Build: \(identity.buildNumber)",
            "Source: \(identity.buildSource)",
            "Commit: \(identity.gitCommit)",
            "Built: \(identity.buildDateUTC)",
            "Executable: \(identity.executablePath)",
            "Bundle: \(identity.bundlePath)",
        ]
        .joined(separator: "\n")
    }

    @ViewBuilder
    private func permissionPill(granted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
            Text(granted ? "Granted" : "Not Granted")
                .font(.caption2)
        }
        .foregroundStyle(granted ? DesignSystem.Colors.successGreen : DesignSystem.Colors.errorRed)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(granted ? DesignSystem.Colors.successGreen.opacity(0.1) : DesignSystem.Colors.errorRed.opacity(0.1))
        )
    }

    @ViewBuilder
    private func modelStatusPill(_ status: SettingsViewModel.LocalModelStatus) -> some View {
        let (icon, text, color): (String, String, Color) = switch status {
        case .unknown:
            ("questionmark.circle.fill", "Unknown", .secondary)
        case .checking:
            ("clock.fill", "Checking", DesignSystem.Colors.warningAmber)
        case .ready:
            ("checkmark.circle.fill", "Ready", DesignSystem.Colors.successGreen)
        case .notLoaded:
            ("pause.circle.fill", "Not Loaded", .secondary)
        case .notDownloaded:
            ("arrow.down.circle.fill", "Not Downloaded", DesignSystem.Colors.errorRed)
        case .repairing:
            ("wrench.and.screwdriver.fill", "Repairing", DesignSystem.Colors.warningAmber)
        case .failed:
            ("xmark.circle.fill", "Failed", DesignSystem.Colors.errorRed)
        }

        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.caption2)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
