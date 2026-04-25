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

    var body: some View {
        VStack(spacing: 0) {
            messagesArea
            composerArea
        }
        .background(DesignSystem.Colors.background)
        .task {
            // Cursor lands in the input the moment you switch to Ask. Tiny await
            // so the focus state binding is wired before we set it (SwiftUI quirk).
            try? await Task.sleep(for: .milliseconds(100))
            inputFocused = true
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
                ChatMarkdownText(raw: message.content)
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

/// Renders chat content with paragraph spacing, simple bullet lists, and inline
/// Markdown (bold / italic / `code` / links) via SwiftUI's AttributedString. Not
/// a full Markdown renderer — covers the shapes LLMs actually produce in chat:
/// short paragraphs, `*`/`-`/numbered bullets, inline emphasis. Headings and
/// code blocks render as plain paragraphs.
struct ChatMarkdownText: View {
    let raw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(inlineAttributed(text))
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                case .heading(let level, let text):
                    Text(inlineAttributed(text))
                        .font(.system(size: headingSize(level), weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .padding(.top, 2)
                        .fixedSize(horizontal: false, vertical: true)

                case .bullet(let indent, let content):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Text(inlineAttributed(content))
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(indent) * 14)

                case .ordered(let indent, let marker, let content):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker)
                            .font(DesignSystem.Typography.body.monospacedDigit())
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Text(inlineAttributed(content))
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                }
            }
        }
    }

    // MARK: Block model

    private enum Block {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullet(indent: Int, content: String)
        case ordered(indent: Int, marker: String, content: String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                out.append(.paragraph(joined))
            }
            paragraphBuffer.removeAll()
        }

        for line in raw.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                continue
            }
            if let heading = Self.parseHeading(line) {
                flushParagraph()
                out.append(heading)
                continue
            }
            if let listItem = Self.parseListItem(line) {
                flushParagraph()
                out.append(listItem)
                continue
            }
            paragraphBuffer.append(line.trimmingCharacters(in: .whitespaces))
        }
        flushParagraph()
        return out
    }

    /// `# Foo`, `## Foo`, etc. up to level 6. Returns the level (count of `#`)
    /// and the trimmed text after the markers and required space.
    private static func parseHeading(_ line: String) -> Block? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashCount = trimmed.prefix(while: { $0 == "#" }).count
        guard hashCount >= 1, hashCount <= 6 else { return nil }
        let afterHashes = trimmed.dropFirst(hashCount)
        guard afterHashes.first == " " else { return nil }
        let text = afterHashes.drop(while: { $0 == " " })
        guard !text.isEmpty else { return nil }
        return .heading(level: hashCount, text: String(text))
    }

    /// Recognizes `* foo`, `- foo`, and `1. foo` (with optional leading whitespace).
    /// Indent level = leading spaces / 2 (caps at 4 to avoid runaway nesting).
    private static func parseListItem(_ line: String) -> Block? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let indent = min(leadingSpaces / 2, 4)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("* ") {
            return .bullet(indent: indent, content: String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("- ") {
            return .bullet(indent: indent, content: String(trimmed.dropFirst(2)))
        }
        if let match = trimmed.range(of: #"^(\d+\.)\s+"#, options: .regularExpression) {
            let marker = String(trimmed[trimmed.startIndex..<trimmed.index(before: match.upperBound)])
                .trimmingCharacters(in: .whitespaces)
            let content = String(trimmed[match.upperBound...])
            return .ordered(indent: indent, marker: marker, content: content)
        }
        return nil
    }

    /// Heading point sizes — H1 large, H6 same as body. Tuned for chat density.
    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 19
        case 2: return 17
        case 3: return 15
        default: return 14
        }
    }

    /// Inline-only Markdown so `**bold**`, `*italic*`, `` `code` ``, and `[link](url)`
    /// render with their attributes. Block-level constructs (headings, lists, fences)
    /// are intentionally not interpreted — handled by the block model above.
    private func inlineAttributed(_ s: String) -> AttributedString {
        if let attr = try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return attr
        }
        return AttributedString(s)
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
