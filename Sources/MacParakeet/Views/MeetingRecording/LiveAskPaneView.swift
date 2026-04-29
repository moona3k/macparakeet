import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Ask tab inside the live meeting panel. Chat against the rolling transcript
/// with a curated row of "thinking-partner" starter prompts in the empty state.
/// In-memory only while recording; promoted to a persisted ChatConversation when
/// the meeting is finalized (see TranscriptChatViewModel.bindPersistedConversation).
struct LiveAskPaneView: View {
    @Bindable var viewModel: TranscriptChatViewModel

    @FocusState private var inputFocused: Bool
    @State private var showingPromptMenu = false

    var body: some View {
        VStack(spacing: 0) {
            messagesArea
            composerArea
        }
        .background(DesignSystem.Colors.background)
        .overlay(alignment: .bottomLeading) {
            if showingPromptMenu {
                promptMenuOverlay
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: showingPromptMenu)
        .task {
            // Cursor lands in the input the moment you switch to Ask. Tiny await
            // so the focus state binding is wired before we set it (SwiftUI quirk).
            try? await Task.sleep(for: .milliseconds(100))
            inputFocused = true
        }
        .onKeyPress(.escape) {
            // ESC priority: dismiss menu, then cancel streaming.
            if showingPromptMenu {
                showingPromptMenu = false
                return .handled
            }
            if viewModel.isStreaming {
                viewModel.cancelStreaming()
                return .handled
            }
            return .ignored
        }
    }

    /// In-view popover for mid-conversation prompt browsing. Anchored above the
    /// menu button on the input bar. NOT a SwiftUI `.popover` — those are broken
    /// inside KeylessPanel (clip, focus theft, key misrouting). ZStack + transparent
    /// tap-catcher gives us outside-tap dismissal without crossing NSPanel boundaries.
    private var promptMenuOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.0001)
                .contentShape(Rectangle())
                .onTapGesture { showingPromptMenu = false }

            StarterPromptList(groups: LiveAskStarterPrompts.groups) { entry in
                showingPromptMenu = false
                fire(entry)
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(DesignSystem.Colors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.32), radius: 14, y: 4)
            .padding(.leading, DesignSystem.Spacing.md)
            .padding(.trailing, DesignSystem.Spacing.md)
            // Sit above the input bar (≈48pt) with breathing room.
            .padding(.bottom, 56)
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
        // Communicate "wait for the current response" — fire() also guards.
        .opacity(viewModel.isStreaming ? 0.45 : 1)
        .allowsHitTesting(!viewModel.isStreaming)
        .animation(.easeOut(duration: 0.18), value: viewModel.isStreaming)
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
        // Single source of truth for scroll: the manual scrollTo on .messages.count.
        // .defaultScrollAnchor(.bottom) was removed because it competes with the
        // explicit animation and the panel chat VM is always fresh per session
        // (panelVM is recreated in .showRecordingPill), so initial-anchor anchoring
        // has no preexisting messages to anchor to anyway.
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
        StarterPromptList(groups: LiveAskStarterPrompts.groups) { entry in
            fire(entry)
        }
    }

    private var noProviderState: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .padding(.bottom, 4)
                .accessibilityHidden(true)

            Text("Ask needs an AI provider")
                .font(DesignSystem.Typography.body.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Text("Add one in Settings → AI Providers. Recording works without it.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.lg)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.errorRed)
                .font(.system(size: 11))
                .accessibilityHidden(true)
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.errorRed)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            // Menu button only mid-conversation — empty state already shows the
            // full prompt grid in the pane, so the button would be redundant.
            if !viewModel.messages.isEmpty && viewModel.canSendMessage {
                PromptMenuButton(isOpen: $showingPromptMenu)
            }

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
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .help("Stop response")
            .accessibilityLabel("Stop response")
        } else {
            let canSend = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && viewModel.canSendMessage
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(canSend
                        ? DesignSystem.Colors.accent
                        : DesignSystem.Colors.accent.opacity(0.3))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
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
/// user sharper in the meeting, not just summarize. Grouped by intent so the empty
/// state orients the user before they read any individual label. English-first;
/// localization deferred.
enum LiveAskStarterPrompts {
    struct Group: Hashable {
        let label: String
        let prompts: [LiveAskPrompt]
    }

    static let groups: [Group] = [
        Group(label: "CATCH UP", prompts: [
            LiveAskPrompt(
                label: "Summarize so far",
                prompt: "Give a concise summary of the meeting so far. Focus on the main topics, decisions made, and any clear conclusions. Skip verbal filler."
            ),
            LiveAskPrompt(
                label: "What did I miss?",
                prompt: "Catch me up on what I missed in the last few minutes — the most important points or shifts. Be terse, signal-rich."
            ),
        ]),
        Group(label: "CAPTURE", prompts: [
            LiveAskPrompt(
                label: "Decisions made",
                prompt: "List the decisions reached in the meeting so far. For each, note what was decided and the brief context that explains why. Skip topics that were only discussed without a decision."
            ),
            LiveAskPrompt(
                label: "Action items",
                prompt: "List concrete action items from the meeting so far — what needs to happen next, by whom, and by when if mentioned. Be specific. Skip vague intentions."
            ),
            LiveAskPrompt(
                label: "Who owns what?",
                prompt: "Map who owns what from the meeting so far — assignments, commitments, areas of responsibility. If ownership for an item is unclear or unstated, flag that explicitly."
            ),
        ]),
        Group(label: "CHALLENGE", prompts: [
            LiveAskPrompt(
                label: "What's unresolved?",
                prompt: "List the open questions, unmade decisions, or topics still hanging from the meeting so far. Be specific."
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
        ]),
    ]
}

/// Renders the 3-group starter prompt list. Single source of truth for both the
/// empty-state pane and the mid-conversation popover so the two surfaces stay
/// visually identical and behavior never drifts.
private struct StarterPromptList: View {
    let groups: [LiveAskStarterPrompts.Group]
    let onSelect: (LiveAskPrompt) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.label)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .padding(.leading, 4)

                    VStack(spacing: 5) {
                        ForEach(group.prompts, id: \.self) { entry in
                            StarterPromptPill(entry: entry) {
                                onSelect(entry)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Sparkle button at the leading edge of the input bar. Toggles the prompt
/// menu popover. Visually tracks open/closed state so the user always knows
/// what the menu is doing.
private struct PromptMenuButton: View {
    @Binding var isOpen: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOpen
                    ? DesignSystem.Colors.accent
                    : DesignSystem.Colors.accent.opacity(isHovered ? 0.85 : 0.7))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isOpen
                            ? DesignSystem.Colors.surfaceElevated
                            : DesignSystem.Colors.surfaceElevated.opacity(isHovered ? 0.55 : 0.32))
                )
                .overlay(
                    Circle()
                        .strokeBorder(isOpen
                            ? DesignSystem.Colors.accent.opacity(0.4)
                            : DesignSystem.Colors.border.opacity(0.35),
                            lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.easeOut(duration: 0.14), value: isOpen)
        .onHover { isHovered = $0 }
        .help("Quick prompts")
        .accessibilityLabel(isOpen ? "Close quick prompts" : "Open quick prompts")
    }
}

/// Always-visible follow-up prompts above the input once a conversation exists.
/// Strictly universal "next-moves on the last assistant message" — keep, expand,
/// probe, push back, compress. Global meeting prompts (Summarize / What did I
/// miss? / Action items) live in the empty-state starters so this row stays
/// honest about its single job: continue the thread.
enum LiveAskFollowUpPrompts {
    static let all: [LiveAskPrompt] = [
        LiveAskPrompt(
            label: "Tell me more",
            prompt: "Expand on your previous response. Go deeper with concrete details and any nuances worth knowing."
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
            label: "TL;DR",
            prompt: "Compress your previous response into one or two short, punchy sentences."
        ),
    ]
}

private struct StarterPromptPill: View {
    let entry: LiveAskPrompt
    let action: () -> Void

    @State private var isHovered = false
    @State private var isRevealed = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.accent.opacity(0.75))
                    Text(entry.label)
                        .font(DesignSystem.Typography.bodySmall)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Spacer(minLength: 0)
                }

                if isRevealed {
                    Text(entry.prompt)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 19)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered
                        ? DesignSystem.Colors.surfaceElevated
                        : DesignSystem.Colors.surfaceElevated.opacity(0.32))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isHovered
                            ? DesignSystem.Colors.accent.opacity(0.4)
                            : DesignSystem.Colors.border.opacity(0.35),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: isRevealed)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .onHover { isHovered = $0 }
        // Delay the reveal slightly so sweeping the mouse across rows doesn't
        // flicker. Background/border still react instantly via isHovered.
        .task(id: isHovered) {
            if isHovered {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                isRevealed = true
            } else {
                isRevealed = false
            }
        }
        .accessibilityHint(entry.prompt)
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
                            : DesignSystem.Colors.surfaceElevated.opacity(0.32))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isHovered
                                ? DesignSystem.Colors.accent.opacity(0.4)
                                : DesignSystem.Colors.border.opacity(0.35),
                            lineWidth: 0.75
                        )
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: isHovered)
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
                // Reuse the canonical NSTextView-based renderer used by the
                // post-meeting Chat tab and PromptResults — same code path means
                // the live thread and its persisted form look identical, and we
                // get headings, code blocks, blockquotes, ordered lists, and
                // proper text selection without re-implementing them here.
                MarkdownContentView(message.content)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(bubbleColor)
                    )
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
