import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacParakeetCore
import MacParakeetViewModels

struct FeedbackView: View {
    @Bindable var viewModel: FeedbackViewModel

    @State private var hoveredCategory: FeedbackCategory?
    @State private var isDraggingScreenshot = false
    @State private var isCommunityHovered = false
    @State private var showsDiagnosticLogSample = false
    @State private var isLogRowHovered = false
    @FocusState private var messageFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                pageHeader
                categoryPicker
                formCard
                communityCard
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .onAppear {
            viewModel.configure(feedbackService: FeedbackService())
            viewModel.refreshDiagnosticLogStatus()
        }
    }

    // MARK: - Page Header

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            // Brand glyph lock-up — the same coral-circle + Breath Wave mark
            // that anchors the Dictation Stats hero, so this reads as one of
            // the app's brand surfaces rather than a generic form.
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.accent.opacity(0.12))
                    .frame(width: 34, height: 34)
                BreathWaveLogo(size: 22, tint: DesignSystem.Colors.accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Feedback")
                    .font(DesignSystem.Typography.pageTitle)
                Text("Found a bug, have an idea, or just want to say hi?")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DesignSystem.Spacing.xs)
    }

    // MARK: - Category Picker

    /// The three category tiles sit directly on the page — the choice *is* the
    /// content, so it leads instead of hiding inside an icon-chip card. Selection
    /// reads coral (check + border + tinted fill), matching the Vocabulary mode
    /// picker rather than the old green check that fought the coral border.
    private var categoryPicker: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: DesignSystem.Spacing.md), count: 3),
            spacing: DesignSystem.Spacing.md
        ) {
            ForEach(FeedbackCategory.allCases, id: \.rawValue) { category in
                categoryTile(category)
            }
        }
    }

    private func categoryTile(_ category: FeedbackCategory) -> some View {
        let isSelected = viewModel.category == category
        let isHovered = hoveredCategory == category
        return Button {
            viewModel.category = category
        } label: {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Image(systemName: categoryIcon(for: category))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? DesignSystem.Colors.accent : .secondary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.accent)
                    }
                }

                Text(category.displayName)
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(.primary)

                Text(categorySubtitle(for: category))
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(isSelected ? DesignSystem.Colors.accentLight : DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(
                        isSelected ? DesignSystem.Colors.accent.opacity(0.5) : DesignSystem.Colors.border,
                        lineWidth: isSelected ? 1.2 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hoveredCategory = hovering ? category : nil
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Form

    /// One calm container for the whole form — no repeated icon-chip header.
    /// The first thing inside is the Message label, so the eye lands on the
    /// only required field.
    private var formCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            if viewModel.submissionState == .success {
                successBanner
            } else {
                formContent
            }
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

    private var successBanner: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
            Text("Sent! Thanks for helping make MacParakeet better.")
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

    private var formContent: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            // Message — the hero, and the only required field. Coral focus ring
            // and the same input material as every other field in the app.
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Message")
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.medium)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $viewModel.message)
                        .font(DesignSystem.Typography.body)
                        .scrollContentBackground(.hidden)
                        .tint(DesignSystem.Colors.accent)
                        .focused($messageFocused)
                        .padding(DesignSystem.Spacing.sm)
                        .frame(minHeight: 120)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                .fill(DesignSystem.Colors.surfaceElevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                .strokeBorder(
                                    messageFocused
                                        ? DesignSystem.Colors.accent.opacity(0.7)
                                        : DesignSystem.Colors.border.opacity(0.7),
                                    lineWidth: messageFocused ? 1.5 : 0.5
                                )
                        )
                        .animation(DesignSystem.Animation.hoverTransition, value: messageFocused)

                    if viewModel.message.isEmpty {
                        Text(placeholderText)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(.tertiary)
                            .padding(DesignSystem.Spacing.sm + 5)
                            .allowsHitTesting(false)
                    }
                }
            }

            // Email + screenshots — both optional, visually secondary, sharing
            // the same input material so they read as a pair.
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Email (optional)")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.medium)
                    ParakeetTextField(placeholder: "you@example.com", text: $viewModel.email)
                    Text("Provide your email if you need a direct response.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Screenshots (optional)")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.medium)

                    if viewModel.screenshotAttachments.isEmpty {
                        screenshotAttachButton
                    } else {
                        VStack(spacing: DesignSystem.Spacing.xs) {
                            ForEach(viewModel.screenshotAttachments) { attachment in
                                screenshotAttachedPill(attachment)
                            }
                            if viewModel.canAttachMoreScreenshots {
                                screenshotAttachButton
                            }
                        }
                    }

                    Text(viewModel.screenshotAttachments.isEmpty
                         ? "or drop images here"
                         : "PNG, JPEG, TIFF, or HEIC. Up to 5.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .onDrop(of: [.image], isTargeted: $isDraggingScreenshot) { providers in
                    guard !providers.isEmpty else { return false }
                    for provider in providers {
                        _ = provider.loadFileRepresentation(for: .image) { url, _, error in
                            guard let url, error == nil else { return }
                            let tmpDirectory = FileManager.default.temporaryDirectory
                                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                            let tmp = tmpDirectory.appendingPathComponent(url.lastPathComponent)
                            do {
                                try FileManager.default.createDirectory(at: tmpDirectory, withIntermediateDirectories: true)
                                try FileManager.default.copyItem(at: url, to: tmp)
                            } catch {
                                try? FileManager.default.removeItem(at: tmpDirectory)
                                return
                            }
                            Task { @MainActor in
                                defer { try? FileManager.default.removeItem(at: tmpDirectory) }
                                viewModel.handleScreenshotDrop(url: tmp)
                            }
                        }
                    }
                    return true
                }
            }

            diagnosticLogOption

            // System info disclosure
            DisclosureGroup("System Info", isExpanded: $viewModel.showSystemInfo) {
                Text(viewModel.systemInfo.displaySummary)
                    .font(DesignSystem.Typography.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(DesignSystem.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .fill(DesignSystem.Colors.contentBackground.opacity(0.5))
                    )
            }
            .font(DesignSystem.Typography.body)
            .tint(DesignSystem.Colors.accent)

            // Error banner
            if case .error(let errorMessage) = viewModel.submissionState {
                errorBanner(errorMessage)
            }

            // Action buttons — one coral CTA on the surface.
            HStack {
                Spacer()
                Button("Clear") {
                    viewModel.resetForm()
                }
                .parakeetAction(.secondary)
                .keyboardShortcut(.cancelAction)

                Button(viewModel.submissionState == .submitting ? "Sending…" : "Send Feedback") {
                    viewModel.submit()
                }
                .parakeetAction(.primaryProminent)
                .disabled(!viewModel.canSubmit)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, DesignSystem.Spacing.xs)
        }
    }

    private var diagnosticLogOption: some View {
        let isAvailable = viewModel.diagnosticLogIsAvailable

        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "doc.text")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(viewModel.includeDiagnosticLog ? DesignSystem.Colors.accent : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                viewModel.includeDiagnosticLog
                                    ? DesignSystem.Colors.accent.opacity(0.12)
                                    : DesignSystem.Colors.surfaceElevated
                            )
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Attach capture diagnostics")
                        .font(DesignSystem.Typography.body.weight(.semibold))

                    Text(diagnosticLogDisplayPath)
                        .font(DesignSystem.Typography.micro.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.surfaceElevated)
                        )
                        .help(viewModel.diagnosticLogURL.path)

                    Text(diagnosticLogScopeDescription)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("It contains no audio or transcript text. You can also give this log to Claude Code, Codex, or another coding agent for debugging.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        guard isAvailable else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([viewModel.diagnosticLogURL])
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isAvailable ? DesignSystem.Colors.successGreen : DesignSystem.Colors.warningAmber)
                            Text(viewModel.diagnosticLogAvailabilityDescription)
                                .font(DesignSystem.Typography.micro)
                                .foregroundStyle(isAvailable && isLogRowHovered ? DesignSystem.Colors.accent : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if isAvailable {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(DesignSystem.Colors.accent)
                                    .opacity(isLogRowHovered ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!isAvailable)
                    .help(isAvailable ? "Reveal \(viewModel.diagnosticLogFilename) in Finder" : "")
                    .accessibilityLabel(isAvailable ? "Reveal \(viewModel.diagnosticLogFilename) in Finder" : viewModel.diagnosticLogAvailabilityDescription)
                    .onHover { hovering in
                        guard isAvailable else { return }
                        withAnimation(DesignSystem.Animation.hoverTransition) {
                            isLogRowHovered = hovering
                        }
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: DesignSystem.Spacing.sm)

                Toggle("", isOn: $viewModel.includeDiagnosticLog)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(DesignSystem.Colors.accent)
                    .disabled(!isAvailable)
                    .accessibilityLabel("Attach capture diagnostics")
                    .accessibilityHint("Includes the dictation audio diagnostics log with this feedback report")
            }

            if isAvailable {
                if viewModel.includeDiagnosticLog {
                    diagnosticLogScopeToggle
                }
                diagnosticLogSample
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(viewModel.includeDiagnosticLog ? 0.95 : 0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .strokeBorder(
                    viewModel.includeDiagnosticLog
                        ? DesignSystem.Colors.accent.opacity(0.45)
                        : DesignSystem.Colors.border.opacity(0.7),
                    lineWidth: viewModel.includeDiagnosticLog ? 1 : 0.5
                )
        )
    }

    /// The full local path of the diagnostics log, home-folder-abbreviated so
    /// it stays readable (and screenshot-safe) while still being the real
    /// `~/Library/Logs/MacParakeet/dictation-audio.log` location on disk.
    private var diagnosticLogDisplayPath: String {
        (viewModel.diagnosticLogURL.path as NSString).abbreviatingWithTildeInPath
    }

    /// Lead copy for the attach control — accurately reflects how far back the
    /// upload reaches so users know what they are sharing.
    private var diagnosticLogScopeDescription: String {
        let attached = viewModel.includeFullDiagnosticHistory
            ? "It attaches your full local history"
            : "It attaches the last 7 days"
        return "Use this for dictation or meeting recording issues. \(attached) to the public report so we can inspect capture timing, buffers, silence, and device errors."
    }

    /// Advanced opt-in to send the entire local log instead of only the recent
    /// window. Shown as a subordinate checkbox under the main switch, so it
    /// reads as a refinement of "attach diagnostics" rather than a peer toggle.
    private var diagnosticLogScopeToggle: some View {
        Toggle(isOn: $viewModel.includeFullDiagnosticHistory) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Include full history")
                    .font(DesignSystem.Typography.caption.weight(.medium))
                Text("Off attaches only the last 7 days. Turn on to include older entries — useful for issues that are hard to reproduce.")
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .tint(DesignSystem.Colors.accent)
        // Indent to align with the main toggle's text column (icon width +
        // the row's HStack spacing) so it reads as a sub-option.
        .padding(.leading, 28 + DesignSystem.Spacing.sm)
        .padding(.top, 2)
        .accessibilityHint("Attaches your entire local diagnostics history instead of only the last seven days")
    }

    // A real, representative slice of `dictation-audio.log` — a full capture
    // session from launch through dictation, a meeting, and a device error.
    // Kept verbatim (just illustrative values) so the Feedback form can show
    // users exactly what they share: counts and device state, never audio or
    // transcript text.
    private static let diagnosticLogExampleLines = [
        "2026-06-06T09:14:02.118Z dictation_diagnostics_session_start pid=42317 version=0.6.21 build=20260607023821 source=stable-dmg commit=3c7f3d8f82ce",
        "2026-06-06T09:14:48.512Z dictation_capture_start permission_status=3",
        "2026-06-06T09:14:48.560Z dictation_capture_first_buffer sr=16000.0 ch=1 common_format=1 interleaved=false frames=4800 has_float_data=true",
        "2026-06-06T09:14:53.121Z dictation_capture_heartbeat input_buffers=50 input_frames=240000 isRunning=true default_input=present default_input_transport=built-in",
        "2026-06-06T09:14:54.004Z dictation_capture_stop sample_count=78000 duration_s=4.875 input_buffers=98 output_buffers=98 max_rms=0.071234 non_silent_buffers=95",
        "2026-06-06T09:14:54.330Z dictation_transcribe_complete chars=49 words=9 engine=parakeet variant=none",
        "2026-06-06T10:02:11.806Z dictation_capture_insufficient sample_count=3200 required=4800",
        "2026-06-06T11:25:27.341Z meeting_recording_started session=40B8536B-… requested_mic_mode=vpioPreferred effective_mic_mode=vpio",
        "2026-06-06T11:25:27.574Z meeting_mic_capture_started effective_mode=vpio sr=16000.0 ch=1 default_input=present default_input_transport=built-in",
        "2026-06-06T11:25:27.902Z system_audio_stream_first_buffer sr=48000.0 ch=2 frames=1024",
        "2026-06-06T11:48:03.190Z meeting_mic_capture_start_failed mode=raw reason=\"permission_denied\"",
    ]

    private var diagnosticLogSample: some View {
        DisclosureGroup(isExpanded: $showsDiagnosticLogSample) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                // One selectable Text inside a horizontal scroller: lines never
                // wrap (so they read like the real log), and a single click-drag
                // highlights the whole excerpt.
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(Self.diagnosticLogExampleLines.joined(separator: "\n"))
                        .font(DesignSystem.Typography.micro.monospaced())
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: true, vertical: true)
                        .textSelection(.enabled)
                }

                Text("Every entry is a count or a device state. `words=9` means you spoke nine words — never which words. No audio and no transcript text is ever written to this file.")
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(DesignSystem.Colors.background.opacity(0.6))
            )
            .padding(.top, 6)
        } label: {
            Text("See exactly what's in the log")
                .font(DesignSystem.Typography.caption.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.accent)
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
            Text(error)
                .font(DesignSystem.Typography.caption)
                .lineLimit(2)
            Spacer()
            Button {
                viewModel.dismissError()
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

    // MARK: - Screenshot Components

    private var screenshotAttachButton: some View {
        Button {
            viewModel.attachScreenshot()
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: isDraggingScreenshot ? "arrow.down.doc.fill" : "photo.on.rectangle.angled")
                    .font(.system(size: 13))
                    .foregroundStyle(isDraggingScreenshot ? DesignSystem.Colors.accent : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text("Attach…")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(isDraggingScreenshot ? DesignSystem.Colors.accent.opacity(0.06) : DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(
                        isDraggingScreenshot ? DesignSystem.Colors.accent : DesignSystem.Colors.border.opacity(0.7),
                        lineWidth: isDraggingScreenshot ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func screenshotAttachedPill(_ attachment: FeedbackScreenshotAttachment) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "photo")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(attachment.filename)
                .font(DesignSystem.Typography.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                viewModel.removeScreenshot(id: attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.7), lineWidth: 0.5)
        )
    }

    // MARK: - Community

    /// A community invitation, not fine print. The whole card is one clickable
    /// destination, dressed in the same craft signature as the Dictation Stats
    /// hero — diagonal-gradient material, a whisper-thin coral top-edge
    /// highlight, shadow lift on hover — plus an external-arrow nudge for delight.
    private var communityCard: some View {
        Button {
            if let url = URL(string: "https://github.com/moona3k/macparakeet/issues") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(DesignSystem.Colors.accent.opacity(0.12))
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Join the conversation on GitHub")
                        .font(DesignSystem.Typography.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("See what's already reported and upvote the ideas you want next.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCommunityHovered ? DesignSystem.Colors.accent : .secondary)
                    .offset(x: isCommunityHovered ? 2 : 0, y: isCommunityHovered ? -2 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.cardBackground,
                                DesignSystem.Colors.surfaceElevated.opacity(0.45)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cardShadow(isCommunityHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.accent.opacity(isCommunityHovered ? 0.35 : 0.18),
                                Color.primary.opacity(0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isCommunityHovered = hovering
            }
        }
        .accessibilityLabel("Join the conversation on GitHub")
        .accessibilityHint("Opens the MacParakeet issues page on GitHub in your browser")
    }

    // MARK: - Category metadata

    private func categoryIcon(for category: FeedbackCategory) -> String {
        switch category {
        case .bug: return "ladybug"
        case .featureRequest: return "lightbulb"
        case .other: return "ellipsis.bubble"
        }
    }

    private func categorySubtitle(for category: FeedbackCategory) -> String {
        switch category {
        case .bug: return "Something isn't working right."
        case .featureRequest: return "An idea for improvement."
        case .other: return "General thoughts or questions."
        }
    }

    /// Placeholder responds to the chosen category so the message box feels
    /// like it's listening rather than showing one generic prompt.
    private var placeholderText: String {
        switch viewModel.category {
        case .bug: return "What happened, and what did you expect instead?"
        case .featureRequest: return "What would make MacParakeet better for you?"
        case .other: return "What's on your mind?"
        }
    }
}
