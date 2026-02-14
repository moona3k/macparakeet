import SwiftUI
import AppKit
import MacParakeetCore
import MacParakeetViewModels

struct TranscriptChatPanel: View {
    let transcription: Transcription
    @Bindable var viewModel: TranscriptionViewModel
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            promptChips

            if let error = viewModel.chatErrorMessage {
                errorBanner(error)
            }

            messageThread
            composer

            Text("Local only. Answers are grounded to this transcript and never leave your Mac.")
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.tertiary)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.75), lineWidth: 0.5)
        )
        .task {
            viewModel.refreshChatRuntimeStatus()
            composerFocused = true
        }
        .onChange(of: transcription.id) { _, _ in
            composerFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask This Transcript")
                    .font(DesignSystem.Typography.sectionTitle)

                HStack(spacing: 6) {
                    statusBadge
                    Text(viewModel.chatRuntimeStatusDetail)
                        .font(DesignSystem.Typography.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if viewModel.isGeneratingCurrentChatResponse {
                ProgressView()
                    .controlSize(.small)
            }

            Menu {
                Button("Clear Thread", role: .destructive) {
                    viewModel.clearChat(for: transcription.id)
                }
                .disabled(viewModel.currentChatMessages.isEmpty)

                Button("Retry Last Failed Question") {
                    viewModel.retryLastFailedQuestion()
                }
                .disabled(!hasFailedAssistantMessage)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var promptChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(viewModel.suggestedChatPrompts(for: transcription), id: \.self) { prompt in
                    Button {
                        viewModel.sendChatQuestion(prompt)
                    } label: {
                        Text(prompt)
                            .font(DesignSystem.Typography.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(DesignSystem.Colors.background)
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.6)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isGeneratingCurrentChatResponse)
                }
            }
        }
    }

    private var messageThread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    if viewModel.currentChatMessages.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.currentChatMessages) { message in
                            TranscriptChatMessageRow(message: message) {
                                copyMessageText($0)
                            }
                                .id(message.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: viewModel.currentChatMessages.count) { _, _ in
                guard let lastID = viewModel.currentChatMessages.last?.id else { return }
                withAnimation(DesignSystem.Animation.contentSwap) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
        .frame(minHeight: 220)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DesignSystem.Spacing.sm) {
            TextField("Ask about decisions, action items, risks, or blockers...", text: $viewModel.chatInput, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .lineLimit(1 ... 4)
                .focused($composerFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.8)
                )
                .onSubmit {
                    viewModel.sendChatQuestion()
                    composerFocused = true
                }

            Button {
                viewModel.sendChatQuestion()
                composerFocused = true
            } label: {
                Label("Send", systemImage: "arrow.up.circle.fill")
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius)
                            .fill(viewModel.canSendChatMessage ? DesignSystem.Colors.accent : DesignSystem.Colors.accent.opacity(0.35))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSendChatMessage)
            .keyboardShortcut(.return, modifiers: [.command])
            .help("Send (Command-Return)")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("No conversation yet.")
                .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Try asking for key decisions, next steps, unresolved risks, or a concise recap.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.background)
        )
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            Text(error)
                .font(DesignSystem.Typography.caption)
                .lineLimit(2)
            Spacer()
        }
        .foregroundStyle(DesignSystem.Colors.errorRed)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.errorRed.opacity(0.08))
        )
    }

    private var statusBadge: some View {
        let style: (String, Color) = {
            switch viewModel.chatRuntimeStatus {
            case .ready:
                return ("Ready", DesignSystem.Colors.successGreen)
            case .cold:
                return ("Cold Start", DesignSystem.Colors.warningAmber)
            case .checking:
                return ("Checking", DesignSystem.Colors.warningAmber)
            case .unavailable:
                return ("Unavailable", DesignSystem.Colors.errorRed)
            }
        }()

        return Text(style.0)
            .font(DesignSystem.Typography.micro.weight(.semibold))
            .foregroundStyle(style.1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(style.1.opacity(0.12))
            )
    }

    private var hasFailedAssistantMessage: Bool {
        viewModel.currentChatMessages.contains { $0.role == .assistant && $0.state == .failed }
    }

    private func copyMessageText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        SoundManager.shared.play(.copyClick)
    }
}

private struct TranscriptChatMessageRow: View {
    let message: TranscriptionViewModel.ChatMessage
    var onCopy: ((String) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            if isAssistant {
                avatar(symbol: "sparkles", tint: DesignSystem.Colors.accent)
            } else {
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(message.text)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let note = message.groundingNote, isAssistant {
                        Text(note)
                            .font(DesignSystem.Typography.micro)
                            .foregroundStyle(.tertiary)
                    }

                    if let model = message.modelID, let duration = message.durationSeconds {
                        Text("\(model) · \(String(format: "%.2fs", duration))")
                            .font(DesignSystem.Typography.micro)
                            .foregroundStyle(.tertiary)
                    } else if message.state == .pending {
                        Text("Generating...")
                            .font(DesignSystem.Typography.micro)
                            .foregroundStyle(.secondary)
                    } else if let error = message.errorDescription, message.state == .failed {
                        Text(error)
                            .font(DesignSystem.Typography.micro)
                            .foregroundStyle(DesignSystem.Colors.errorRed)
                            .lineLimit(2)
                    }

                    if isAssistant && message.state == .delivered {
                        Button {
                            onCopy?(message.text)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy answer")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.7), lineWidth: 0.5)
            )
            .frame(maxWidth: .infinity, alignment: isAssistant ? .leading : .trailing)

            if !isAssistant {
                avatar(symbol: "person.fill", tint: .secondary)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private var isAssistant: Bool {
        message.role == .assistant
    }

    private var backgroundColor: Color {
        if message.role == .user {
            return DesignSystem.Colors.accentLight
        }
        if message.state == .failed {
            return DesignSystem.Colors.errorRed.opacity(0.06)
        }
        return DesignSystem.Colors.surface
    }

    private func avatar(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                Circle()
                    .strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
            )
    }
}
