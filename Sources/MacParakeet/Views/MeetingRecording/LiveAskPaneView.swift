import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Ask tab inside the live meeting panel. Chat against the rolling transcript
/// with a curated row of "thinking-partner" starter prompts in the empty state.
/// In-memory only while recording; promoted to a persisted ChatConversation when
/// the meeting is finalized (see TranscriptChatViewModel.bindPersistedConversation).
struct LiveAskPaneView: View {
    @Bindable var viewModel: TranscriptChatViewModel
    @Bindable var quickPromptsViewModel: QuickPromptsViewModel

    @FocusState private var inputFocused: Bool
    @State private var showingPromptMenu = false
    @State private var showingPromptsSheet = false

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
        .onChange(of: viewModel.isStreaming) { _, streaming in
            // The sparkle button dims + ignores hits while streaming, but if the
            // menu was already open when streaming began (e.g. user regenerated
            // from an earlier bubble) it would sit there with non-firing prompts.
            if streaming { showingPromptMenu = false }
        }
        .sheet(isPresented: $showingPromptsSheet, onDismiss: {
            // Refresh after the user closes the sheet so any edits / new pills
            // / restored defaults take effect immediately in the live pane.
            quickPromptsViewModel.refresh()
        }) {
            AskPromptsSheet(viewModel: quickPromptsViewModel)
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

            VStack(spacing: 0) {
                StarterPromptList(groups: quickPromptsViewModel.visiblePromptGroups) { entry in
                    showingPromptMenu = false
                    fire(entry)
                }

                Divider()
                    .padding(.top, DesignSystem.Spacing.sm)
                    .padding(.bottom, 6)

                Button {
                    showingPromptMenu = false
                    showingPromptsSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .medium))
                        Text("Edit prompts…")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

    /// Composer = follow-up pills (when conversation has started + at least one
    /// pinned prompt is visible) + input. Single visual chunk, single divider
    /// above. Owns the bottom of the panel.
    private var composerArea: some View {
        VStack(spacing: 0) {
            if !viewModel.messages.isEmpty
                && viewModel.canSendMessage
                && !quickPromptsViewModel.visiblePinned.isEmpty {
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
                ForEach(quickPromptsViewModel.visiblePinned) { entry in
                    FollowUpPill(label: entry.label) {
                        fire(entry)
                    }
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        // Edge-fade affordance: when pills overflow the strip width, the
        // trailing edge fades to signal "more available here, scroll" without
        // a visible scrollbar. When content fits, the fade overlaps only the
        // horizontal padding (background-only area), so it stays invisible.
        // 4% on each side ≈ 12-16pt at typical panel widths — subtle enough
        // not to clip pill edges, strong enough to read as a soft horizon.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.04),
                    .init(color: .black, location: 0.96),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        // Communicate "wait for the current response" — fire() also guards.
        .opacity(viewModel.isStreaming ? 0.45 : 1)
        .allowsHitTesting(!viewModel.isStreaming)
        .animation(.easeOut(duration: 0.18), value: viewModel.isStreaming)
    }

    /// Pill tap → bubble shows the short label, LLM gets the comprehensive prompt.
    private func fire(_ entry: QuickPrompt) {
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
                            MessageBubble(
                                message: message,
                                isLast: message.id == viewModel.messages.last?.id,
                                onRegenerate: { viewModel.regenerateLastResponse() }
                            )
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
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            StarterPromptList(groups: quickPromptsViewModel.visiblePromptGroups) { entry in
                fire(entry)
            }

            Button {
                showingPromptsSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .medium))
                    Text("Edit prompts…")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .padding(.leading, 4)
                .padding(.top, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var noProviderState: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .padding(.bottom, 4)
                .accessibilityHidden(true)

            Text("Turn on AI for meeting Ask")
                .font(DesignSystem.Typography.body.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Text("MacParakeet can use a local AI app, your API key, or a command-line AI tool. Recording works without this.")
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
            // Mirrors the follow-up row's streaming treatment so the entire
            // composer reads as "wait" while the assistant is composing.
            if !viewModel.messages.isEmpty && viewModel.canSendMessage {
                PromptMenuButton(isOpen: $showingPromptMenu)
                    .opacity(viewModel.isStreaming ? 0.45 : 1)
                    .allowsHitTesting(!viewModel.isStreaming)
                    .animation(.easeOut(duration: 0.18), value: viewModel.isStreaming)
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

/// Renders the grouped starter prompt list. Single source of truth for both the
/// empty-state pane and the mid-conversation popover so the two surfaces stay
/// visually identical and behavior never drifts. Groups come from
/// `QuickPromptsViewModel.visiblePromptGroups`, which preserves first-occurrence
/// group order so users who reorder pills control how groups appear.
private struct StarterPromptList: View {
    let groups: [(label: String, prompts: [QuickPrompt])]
    let onSelect: (QuickPrompt) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups, id: \.label) { group in
                VStack(alignment: .leading, spacing: 6) {
                    if !group.label.isEmpty {
                        Text(group.label)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                            .padding(.leading, 4)
                    }

                    VStack(spacing: 5) {
                        ForEach(group.prompts) { entry in
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

private struct StarterPromptPill: View {
    let entry: QuickPrompt
    let action: () -> Void

    @State private var isHovered = false
    @State private var isRevealed = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.label)
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isRevealed {
                    Text(entry.prompt)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
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

/// "Whisper" layout — designed for the live in-meeting context, not a generic
/// chat. Asymmetric on purpose: user turns are small accent-tinted capsules
/// (gestural, low visual weight); assistant turns are bubble-less typeset prose
/// anchored by a leading accent rule with the MacParakeet brand mark at the
/// top (resting state) or a spinning merkaba (streaming state). The rule
/// breathes while streaming, echoing the recording pill's sacred-geometry
/// language. Optimized for glance-and-return cognition in a narrow panel — no
/// avatar burning width, no chat-app chrome competing with content. Distinct
/// from the post-meeting transcript chat by design: that surface is archival
/// and leisurely; this one is in-the-moment thinking partnership.
private struct MessageBubble: View {
    let message: ChatDisplayMessage
    let isLast: Bool
    let onRegenerate: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            UserTurnView(content: message.content)
        case .assistant, .system:
            AssistantTurnView(
                content: message.content,
                isStreaming: message.isStreaming,
                isLast: isLast,
                onRegenerate: onRegenerate
            )
        }
    }
}

private struct UserTurnView: View {
    let content: String

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 32)

            Text(content)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.accent)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(DesignSystem.Colors.accent.opacity(0.10))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(DesignSystem.Colors.accent.opacity(0.22), lineWidth: 0.5)
                )
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AssistantTurnView: View {
    let content: String
    let isStreaming: Bool
    let isLast: Bool
    let onRegenerate: () -> Void

    @State private var hovered = false
    @State private var copied = false
    @FocusState private var actionFocus: AssistantActionFocus?

    private var isEmptyStreaming: Bool { content.isEmpty && isStreaming }

    /// Actions ride on the assistant turn but they're not part of the read.
    /// Hide while streaming (no copying half-tokens; no regenerating an unfinished
    /// turn) and on empty content. Reveal on hover OR keyboard focus so a tab-only
    /// user can still reach them. The `copied` hold keeps the row up while the
    /// green-checkmark confirmation plays out, even if the cursor leaves first.
    private var actionsVisible: Bool {
        guard !isStreaming, !content.isEmpty else { return false }
        return hovered || actionFocus != nil || copied
    }

    var body: some View {
        // Two columns: an 18pt leading anchor (head + accent rule) and the
        // typeset prose. The rule stretches to fill its column, and the HStack
        // top-aligns to the prose — so the rule ends exactly where the prose
        // ends. Actions ride beneath the HStack (with matching leading padding)
        // so the reserved-but-invisible actions row never inflates the rule
        // past the visible text. While we wait for the first token, the rule
        // and prose are hidden — the merkaba (brand voice / sacred-geometry
        // rotation) pairs with three small wave-pulsing dots (universal
        // "thinking" signal) for the loading state. Same job-division as
        // iMessage's avatar + typing bubble.
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 6) {
                    AssistantHead(isStreaming: isStreaming)

                    if !isEmptyStreaming {
                        AssistantAccentRule(isActive: isStreaming)
                            .transition(.opacity)
                    }
                }
                .frame(width: 18)

                if isEmptyStreaming {
                    ThinkingDots()
                        .transition(.opacity)
                        // ThinkingDots is .accessibilityHidden(true) internally
                        // (decorative); promote it to a single element here so
                        // VoiceOver still reads the loading state.
                        .accessibilityElement()
                        .accessibilityLabel("Thinking")
                } else {
                    // Reuse the canonical NSTextView-based renderer used
                    // elsewhere (post-meeting Chat tab, PromptResults).
                    // Markdown, headings, code blocks, lists, and proper text
                    // selection — for free.
                    MarkdownContentView(content)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }

                Spacer(minLength: 0)
            }

            if !isEmptyStreaming {
                // Always rendered (reserves height so hover doesn't shift
                // layout) but invisible until the assistant turn is hovered
                // or one of its action buttons takes keyboard focus. Leading
                // padding (head 18 + HStack spacing 12) keeps the actions row
                // column-aligned with the prose above it.
                AssistantMessageActions(
                    content: content,
                    showRegenerate: isLast,
                    onRegenerate: onRegenerate,
                    focus: $actionFocus,
                    copied: $copied
                )
                .padding(.leading, 30)
                .opacity(actionsVisible ? 1 : 0)
                .allowsHitTesting(actionsVisible)
                .animation(.easeOut(duration: 0.12), value: actionsVisible)
            }
        }
        // Generous, forgiving hover target — cursor doesn't need to land
        // precisely on prose to reveal actions; anywhere across the assistant
        // strip counts.
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.2), value: isEmptyStreaming)
    }
}

private enum AssistantActionFocus: Hashable {
    case copy
    case regenerate
}

/// Two SF Symbol buttons beneath the assistant prose: Copy (always) and
/// Regenerate (tail only). Bare glyphs — no backgrounds, no labels — to honor
/// the "whisper layout" intent: no chat-app chrome, just the response and
/// quiet affordances that emerge on hover. Per-button hover bumps glyph
/// opacity for a touch of liveliness without animating during reveal.
private struct AssistantMessageActions: View {
    let content: String
    let showRegenerate: Bool
    let onRegenerate: () -> Void
    @FocusState.Binding var focus: AssistantActionFocus?
    /// Lifted to the parent so the actions row stays revealed for the full
    /// confirmation animation even if the cursor leaves the assistant turn.
    @Binding var copied: Bool

    @State private var copyHovered = false
    @State private var regenerateHovered = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 14) {
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                    .font(.system(size: 11, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(
                        copied
                            ? DesignSystem.Colors.successGreen.opacity(0.95)
                            : DesignSystem.Colors.accent.opacity(copyHovered ? 0.95 : 0.55)
                    )
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .copy)
            .onHover { copyHovered = $0 }
            .help(copied ? "Copied" : "Copy response")
            .accessibilityLabel(copied ? "Copied" : "Copy response")

            if showRegenerate {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            DesignSystem.Colors.accent.opacity(regenerateHovered ? 0.95 : 0.55)
                        )
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focus, equals: .regenerate)
                .onHover { regenerateHovered = $0 }
                .help("Regenerate response")
                .accessibilityLabel("Regenerate response")
            }
        }
        .padding(.top, 8)
        .onDisappear { resetTask?.cancel() }
    }

    private func copy() {
        guard !content.isEmpty else { return }
        // Copy the raw markdown source — pastes cleanly into Notes/Slack/email
        // and preserves the bold quote callouts that make the response useful.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            if !Task.isCancelled {
                copied = false
            }
        }
    }
}

/// Three small accent dots that wave during empty-streaming. Sits at the right
/// of the merkaba head, vertically centered to it, so the pair reads as one
/// anchored loading affordance — not a glyph and floating decoration. Pure
/// opacity wave (no scale) keeps static moments clean; the merkaba does the
/// rotation work.
private struct ThinkingDots: View {
    @State private var phase = 0
    private let dotCount = 3

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<dotCount, id: \.self) { i in
                Circle()
                    .fill(DesignSystem.Colors.accent.opacity(phase == i ? 0.85 : 0.28))
                    .frame(width: 4, height: 4)
            }
        }
        // Match the AssistantHead's 18pt frame so HStack(.top) aligns the two
        // affordances by their centers, not their tops. If you change the head
        // size, change this height to match — the contract is "same frame
        // height as the head, content centered within".
        .frame(height: 18, alignment: .center)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(330))
                withAnimation(.easeInOut(duration: 0.32)) {
                    phase = (phase + 1) % dotCount
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Head of the assistant column — swaps between a spinning merkaba (streaming)
/// and the MacParakeet brand mark (idle). Streaming carries sacred-geometry
/// motion into the live Ask; idle carries the brand identity (Cursive P /
/// Breath Wave) for subtle product recognition next to every completed AI
/// turn. Two glyphs, two roles: motion = "thinking", brand = "sender."
private struct AssistantHead: View {
    let isStreaming: Bool

    var body: some View {
        ZStack {
            if isStreaming {
                SpinnerRingView(size: 14, revolutionDuration: 2.0, tintColor: DesignSystem.Colors.accent)
                    .transition(.opacity)
            } else {
                BreathWaveLogo(size: 18, tint: DesignSystem.Colors.accent, opacity: 1.0)
                    .transition(.opacity)
            }
        }
        .frame(width: 18, height: 18)
        .animation(.easeInOut(duration: 0.2), value: isStreaming)
        .accessibilityHidden(true)
    }
}

/// 2pt vertical accent rule. Sits quiet when idle (0.18); brightens to a steady
/// 0.4 during streaming so the column feels alive without competing with the
/// spinning merkaba above it. Two motion sources stacked would be noise — the
/// merkaba does the rotation, the rule does the static "active" presence.
private struct AssistantAccentRule: View {
    let isActive: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(DesignSystem.Colors.accent.opacity(isActive ? 0.40 : 0.18))
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.3), value: isActive)
    }
}
