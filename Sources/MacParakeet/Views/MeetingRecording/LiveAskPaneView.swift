import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Ask tab inside the live meeting panel. Chat against the rolling transcript
/// with a curated row of "thinking-partner" starter prompts in the empty state.
/// In-memory only while recording; promoted to a persisted ChatConversation when
/// the meeting is finalized (see TranscriptChatViewModel.bindPersistedConversation).
struct LiveAskPaneView: View {
    @Bindable var viewModel: TranscriptChatViewModel
    var onOpenLLMSettings: (() -> Void)?

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            messagesArea
            composerArea
        }
        .background(DesignSystem.Colors.background)
        .onAppear {
            // Cursor lands in the input the moment you switch to Ask. Tiny delay
            // so the focus state binding is wired before we set it (SwiftUI quirk).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                inputFocused = true
            }
        }
        .onKeyPress(.escape) {
            // Universal cancel for an in-flight assistant response.
            if viewModel.isStreaming {
                viewModel.cancelStreaming()
                return .handled
            }
            return .ignored
        }
    }

    /// Composer = follow-up pills (when conversation has started) + input.
    /// Single visual chunk, single divider above. Owns the bottom of the panel.
    private var composerArea: some View {
        VStack(spacing: 0) {
            if !viewModel.messages.isEmpty && viewModel.canSendMessage {
                followUpRow
            }
            inputBar
        }
        .background(DesignSystem.Colors.cardBackground)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var followUpRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LiveAskFollowUpPrompts.all, id: \.self) { entry in
                    FollowUpPill(label: entry.label) {
                        fire(entry)
                    }
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }

    /// Pill tap → bubble shows the short label, LLM gets the comprehensive prompt.
    private func fire(_ entry: LiveAskPrompt) {
        guard viewModel.canSendMessage, !viewModel.isStreaming else { return }
        viewModel.inputText = entry.label
        viewModel.sendMessage(richPrompt: entry.prompt)
        inputFocused = true
    }

    // MARK: - Messages

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    if !viewModel.canSendMessage {
                        noProviderState
                    } else if viewModel.messages.isEmpty {
                        emptyStateWithPills
                    } else {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }

                    if let error = viewModel.errorMessage {
                        errorRow(error)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: viewModel.messages.count) {
                guard let lastID = viewModel.messages.last?.id else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateWithPills: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Quick prompts")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .padding(.leading, 4)

            VStack(spacing: 8) {
                ForEach(LiveAskStarterPrompts.all, id: \.self) { entry in
                    StarterPromptPill(label: entry.label) {
                        fire(entry)
                    }
                }
            }
        }
    }

    private var noProviderState: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .padding(.bottom, 4)

            Text("Ask needs an AI provider")
                .font(DesignSystem.Typography.body.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Text("Add one in Settings → AI Providers. Recording works without it.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let onOpenLLMSettings {
                Button("Open Settings") { onOpenLLMSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.lg)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.errorRed)
                .font(.system(size: 11))
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.errorRed)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            TextField("Ask about the meeting…", text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(DesignSystem.Typography.body)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, 11)
                .focused($inputFocused)
                // Intentionally NOT disabled while streaming. SwiftUI strips focus from
                // a field the moment it becomes disabled, and re-focusing post-stream
                // is unreliable inside an NSPanel. Letting the user type a follow-up
                // while the assistant is still composing is also better UX. send()'s
                // own guard prevents a double-send.
                .disabled(!viewModel.canSendMessage)
                .onSubmit { send() }
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(DesignSystem.Colors.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(DesignSystem.Colors.border.opacity(0.3), lineWidth: 1)
                )

            sendOrStopButton
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if viewModel.isStreaming {
            Button {
                viewModel.cancelStreaming()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(DesignSystem.Colors.errorRed)
            }
            .buttonStyle(.plain)
            .help("Stop response")
        } else {
            let canSend = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && viewModel.canSendMessage
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(canSend
                        ? DesignSystem.Colors.accent
                        : DesignSystem.Colors.accent.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
    }

    private func send() {
        let trimmed = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, viewModel.canSendMessage, !viewModel.isStreaming else { return }
        viewModel.sendMessage()
        inputFocused = true
    }
}

// MARK: - Prompts

/// A pill is two strings: a short, gestural `label` rendered on the chip AND in
/// the user's bubble, and a more comprehensive `prompt` actually sent to the LLM.
/// The thread reads conversational ("Tell me more") while the model gets enough
/// scaffolding to answer well.
struct LiveAskPrompt: Hashable {
    let label: String
    let prompt: String
}

/// Empty-state "thinking-partner" prompts — meant to start a thread and make the
/// user sharper in the meeting, not just summarize. English-first; localization deferred.
enum LiveAskStarterPrompts {
    static let all: [LiveAskPrompt] = [
        LiveAskPrompt(
            label: "Summarize so far",
            prompt: "Give a concise summary of the meeting so far. Focus on the main topics, decisions made, and any clear conclusions. Skip verbal filler."
        ),
        LiveAskPrompt(
            label: "What did I miss?",
            prompt: "Catch me up on what I missed in the last few minutes — the most important points or shifts. Be terse, signal-rich."
        ),
        LiveAskPrompt(
            label: "What question is worth asking?",
            prompt: "Based on the meeting so far, suggest one sharp, useful question I could ask next that would advance the discussion or surface something important that hasn't been addressed."
        ),
        LiveAskPrompt(
            label: "What's worth pushing back on?",
            prompt: "Identify any claims, assumptions, or decisions in the meeting so far that deserve scrutiny. What might be wrong, weak, or worth challenging?"
        ),
        LiveAskPrompt(
            label: "Where are we going in circles?",
            prompt: "Have we revisited the same topic or argument without making progress? If so, point out where we're looping and what would actually move things forward."
        ),
        LiveAskPrompt(
            label: "What's unresolved?",
            prompt: "List the open questions, unmade decisions, or topics still hanging from the meeting so far. Be specific."
        ),
    ]
}

/// Always-visible follow-up prompts above the input once a conversation exists.
/// "Summarize so far" and "What did I miss?" earn a slot here too — both stay
/// useful mid-conversation since the underlying transcript keeps growing.
enum LiveAskFollowUpPrompts {
    static let all: [LiveAskPrompt] = [
        LiveAskPrompt(
            label: "Tell me more",
            prompt: "Expand on your previous response. Go deeper with concrete details and any nuances worth knowing."
        ),
        LiveAskPrompt(
            label: "Summarize so far",
            prompt: "Give a concise summary of the meeting so far. Focus on the main topics, decisions made, and any clear conclusions. Skip verbal filler."
        ),
        LiveAskPrompt(
            label: "What did I miss?",
            prompt: "Catch me up on what I missed in the last few minutes — the most important points or shifts. Be terse, signal-rich."
        ),
        LiveAskPrompt(
            label: "Why?",
            prompt: "Explain the reasoning behind your previous answer. What from the meeting transcript supports it?"
        ),
        LiveAskPrompt(
            label: "Give an example",
            prompt: "Give a specific, concrete example that illustrates your previous response — ideally pulled from what was actually said in the meeting."
        ),
        LiveAskPrompt(
            label: "Counter-argument?",
            prompt: "What's the strongest counter-argument to your previous response? Steelman the opposing view."
        ),
        LiveAskPrompt(
            label: "Action items?",
            prompt: "Pull out any action items, decisions, or commitments from the meeting so far. List them clearly, with owners if mentioned."
        ),
        LiveAskPrompt(
            label: "TL;DR",
            prompt: "Compress your previous response into one or two short, punchy sentences."
        ),
    ]
}

private struct StarterPromptPill: View {
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.accent.opacity(0.75))
                Text(label)
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered
                        ? DesignSystem.Colors.surfaceElevated
                        : DesignSystem.Colors.surfaceElevated.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isHovered
                            ? DesignSystem.Colors.accent.opacity(0.4)
                            : DesignSystem.Colors.border.opacity(0.5),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Compact horizontal-scroll pill for the follow-up row above the input.
/// Smaller than StarterPromptPill — meant to be persistent, not announce itself.
private struct FollowUpPill: View {
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered
                    ? DesignSystem.Colors.textPrimary
                    : DesignSystem.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isHovered
                            ? DesignSystem.Colors.surfaceElevated
                            : DesignSystem.Colors.surfaceElevated.opacity(0.55))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isHovered
                                ? DesignSystem.Colors.accent.opacity(0.35)
                                : DesignSystem.Colors.border.opacity(0.4),
                            lineWidth: 0.75
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: ChatDisplayMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 32) }

            if message.role != .user && message.content.isEmpty && message.isStreaming {
                TypingIndicator()
            } else {
                Text(message.content)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(bubbleColor)
                    )
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if message.role == .assistant { Spacer(minLength: 32) }
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user:
            return DesignSystem.Colors.accent.opacity(0.18)
        case .assistant, .system:
            return DesignSystem.Colors.surfaceElevated.opacity(0.6)
        }
    }
}

/// Three accent dots that wave gracefully while the assistant is composing.
/// On-brand replacement for the placeholder "…" — restrained, ~1.4s cycle.
private struct TypingIndicator: View {
    @State private var phase = 0
    private let dotCount = 3
    private let interval: Duration = .milliseconds(380)

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<dotCount, id: \.self) { i in
                Circle()
                    .fill(DesignSystem.Colors.accent.opacity(phase == i ? 0.9 : 0.32))
                    .frame(width: 6, height: 6)
                    .scaleEffect(phase == i ? 1.25 : 0.85)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
        )
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                withAnimation(.easeInOut(duration: 0.32)) {
                    phase = (phase + 1) % dotCount
                }
            }
        }
        .accessibilityLabel("Thinking")
    }
}
