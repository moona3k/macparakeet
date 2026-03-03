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
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        settingsCard(
            title: "Workspace Controls",
            subtitle: "Everything runs locally on your Mac.",
            icon: "slider.horizontal.3"
        ) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: DesignSystem.Spacing.md), count: 4),
                spacing: DesignSystem.Spacing.md
            ) {
                statChip(
                    title: "Dictations",
                    value: "\(viewModel.dictationCount)"
                )

                statChip(
                    title: "YouTube Cache",
                    value: formattedYouTubeStorage
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
            subtitle: "How MacParakeet shows up on your Mac.",
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

                Divider()

                settingsToggleRow(
                    title: "Show dictation pill at all times",
                    detail: "When off, the pill hides until you press the hotkey.",
                    isOn: $viewModel.showIdlePill
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
                    HotkeyRecorderView(trigger: $viewModel.hotkeyTrigger)
                }

                Divider()

                dictationModeGuide

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
            subtitle: "Manage recordings and disk usage.",
            icon: "internaldrive"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                settingsToggleRow(
                    title: "Save audio recordings",
                    detail: "Keep audio alongside your dictation history.",
                    isOn: $viewModel.saveAudioRecordings
                )

                Divider()

                settingsToggleRow(
                    title: "Keep downloaded YouTube audio",
                    detail: "Turn off to auto-delete downloaded audio after transcription.",
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
                        detail: formattedYouTubeStorage
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
            subtitle: "Parakeet powers all speech recognition on your Mac.",
            icon: "cpu"
        ) {
            modelStatusRow(
                title: "Parakeet (Speech)",
                detail: viewModel.parakeetStatusDetail,
                status: viewModel.parakeetStatus,
                isRepairing: viewModel.parakeetRepairing
            ) {
                viewModel.repairParakeetModel()
            }
        }
    }

    private var permissionsCard: some View {
        settingsCard(
            title: "Permissions",
            subtitle: "Required for dictation and pasting text into apps.",
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
            title: "Setup",
            subtitle: "Re-run the guided setup if something isn't working.",
            icon: "arrow.counterclockwise"
        ) {
            HStack {
                rowText(
                    title: "Run setup again",
                    detail: "Re-opens guided setup for permissions and model download."
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

    // MARK: - About

    private var aboutCard: some View {
        let identity = BuildIdentity.current
        return settingsCard(
            title: "About",
            subtitle: "Version info and diagnostics.",
            icon: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    SpinnerRingView(size: 18, revolutionDuration: 8.0, tintColor: DesignSystem.Colors.accent)
                        .opacity(0.6)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacParakeet \(identity.version) (\(identity.buildNumber))")
                            .font(DesignSystem.Typography.body)
                        Text("Fast, private voice for Mac")
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

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SettingsCardContainer(title: title, subtitle: subtitle, icon: icon, content: content)
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
                .toggleStyle(.switch)
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
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignSystem.Typography.sectionTitle)
                .foregroundStyle(isHealthy ? .primary : DesignSystem.Colors.errorRed)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
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

    // MARK: - Dictation Mode Guide

    private var dictationModeGuide: some View {
        VStack(spacing: 0) {
            modeShortcutRow(
                keys: [viewModel.hotkeyTrigger.shortSymbol, viewModel.hotkeyTrigger.shortSymbol],
                separator: "+",
                action: "Persistent dictation",
                detail: "Tap again to stop"
            )

            Divider()
                .padding(.leading, 88)

            modeShortcutRow(
                keys: [viewModel.hotkeyTrigger.shortSymbol],
                separator: nil,
                action: "Push-to-talk",
                detail: "Release to stop"
            )
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private func modeShortcutRow(keys: [String], separator: String?, action: String, detail: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: 3) {
                if keys.count == 2, let sep = separator {
                    miniSettingsKeyCap(keys[0])
                    Text(sep)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    miniSettingsKeyCap(keys[1])
                } else {
                    Text("Hold")
                        .font(DesignSystem.Typography.micro)
                        .foregroundStyle(.secondary)
                    miniSettingsKeyCap(keys[0])
                }
            }
            .frame(width: 80, alignment: .center)

            Text(action)
                .font(DesignSystem.Typography.caption)

            Spacer()

            Text(detail)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private func miniSettingsKeyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignSystem.Colors.cardBackground)
                    .shadow(color: .black.opacity(0.06), radius: 0.5, x: 0, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
            )
    }

    // MARK: - Helpers

    private var formattedYouTubeStorage: String {
        let mb = viewModel.youtubeDownloadStorageMB
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
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
                .font(DesignSystem.Typography.micro)
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
                .font(DesignSystem.Typography.micro)
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

// MARK: - Settings Card with Hover

private struct SettingsCardContainer<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
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
                .cardShadow(isHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(
                    isHovered ? DesignSystem.Colors.accent.opacity(0.2) : DesignSystem.Colors.border.opacity(0.6),
                    lineWidth: 0.5
                )
        )
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovered = hovering
            }
        }
    }
}
