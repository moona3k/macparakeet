import AppKit
#if canImport(SwiftStreamingMarkdown)
import SwiftStreamingMarkdown
#endif
import SwiftUI

#if canImport(SwiftStreamingMarkdown)
/// Canonical renderer for LLM-authored Markdown throughout the app.
///
/// The source string remains the artifact of record; this view only changes its
/// presentation. Remote/local images stay disabled, while links are restricted
/// to web URLs before SwiftUI hands them to the system browser.
struct MarkdownContentView: View {
    let content: String
    private let baseFontSize: CGFloat
    private let isStreaming: Bool
    @StateObject private var streamingSource: MarkdownSnapshotSource
    @State private var renderedDocument: RenderableDocument = .empty

    init(
        _ content: String,
        font: Font = DesignSystem.Typography.body,
        isStreaming: Bool = false
    ) {
        self.content = content
        self.baseFontSize = font == DesignSystem.Typography.bodyLarge ? 15 : 14
        self.isStreaming = isStreaming
        self._streamingSource = StateObject(
            wrappedValue: MarkdownSnapshotSource(initialContent: content)
        )
    }

    var body: some View {
        DocumentView(
            renderableDocument: renderedDocument,
            config: renderConfiguration,
            listener: MarkdownContentInteractionListener.shared
        )
        .onAppear {
            streamingSource.send(content)
        }
        .onChange(of: content) { _, newContent in
            streamingSource.send(newContent)
        }
        .task(id: baseFontSize) {
            // SwiftUI owns this consumer's lifetime. A cancelled parse cannot
            // publish after a replacement consumer returns to the same pane.
            await MarkdownSnapshotRenderer.render(source: streamingSource, config: renderConfiguration) {
                renderedDocument = $0
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(
            \.openURL,
            OpenURLAction { url in
                MarkdownContentPolicy.isAllowedLink(url)
                    ? .systemAction(url)
                    : .discarded
            })
    }

    private var renderConfiguration: MarkdownRenderConfig {
        MarkdownContentConfiguration.make(
            baseFontSize: baseFontSize,
            isStreaming: isStreaming
        )
    }
}

/// A retained snapshot store, with a separate stream for each renderer task.
/// Cancelling a consumer terminates its AsyncStream permanently, so the source
/// must create a fresh subscription when the same SwiftUI view reappears.
final class MarkdownSnapshotSource: ObservableObject, @unchecked Sendable {
    // The renderer subscribes/cancels from tasks while SwiftUI sends snapshots.
    // All mutable state, including replay ordering, is protected by this lock.
    private let lock = NSLock()
    private var latestContent: String
    private var subscribers: [UUID: AsyncStream<String>.Continuation] = [:]

    init(initialContent: String) {
        self.latestContent = initialContent
    }

    var text: AsyncStream<String> {
        let subscriptionID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            lock.withLock {
                subscribers[subscriptionID] = continuation
                continuation.yield(latestContent)
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeSubscriber(subscriptionID)
            }
        }
    }

    func send(_ content: String) {
        lock.withLock {
            latestContent = content
            for continuation in subscribers.values {
                continuation.yield(content)
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        lock.withLock {
            _ = subscribers.removeValue(forKey: id)
        }
    }

    deinit {
        // No strong reference to the source survives into termination handlers.
        for continuation in subscribers.values {
            continuation.finish()
        }
    }
}

/// Serial parsing keeps only the newest waiting snapshot, even when generation
/// outpaces rendering. Publication stays on the UI actor after cancellation checks.
enum MarkdownSnapshotRenderer {
    @MainActor
    static func render(
        source: MarkdownSnapshotSource,
        config: MarkdownRenderConfig,
        parse: @MainActor (String, MarkdownRenderConfig) async -> RenderableDocument = { text, config in
            await MarkdownParserImpl().parse(text: text, config: config)
        },
        publish: (RenderableDocument) -> Void
    ) async {
        for await text in source.text {
            guard !Task.isCancelled else { return }
            let document = await parse(text, config)
            guard !Task.isCancelled else { return }
            publish(document)
        }
    }
}

enum MarkdownContentPolicy {
    static func isAllowedLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

enum MarkdownContentConfiguration {
    static func make(baseFontSize: CGFloat, isStreaming: Bool) -> MarkdownRenderConfig {
        let bodyFonts = fonts(size: baseFontSize, lineHeight: baseFontSize + 6)
        let smallFonts = fonts(size: max(12, baseFontSize - 1), lineHeight: baseFontSize + 4)
        let codeFonts = TextFonts(
            normal: .monospacedSystemFont(ofSize: max(12, baseFontSize - 1), weight: .regular),
            italic: nil,
            bold: .monospacedSystemFont(ofSize: max(12, baseFontSize - 1), weight: .semibold),
            boldItalic: nil,
            preferredLetterSpacing: 0,
            preferredLineHeight: baseFontSize + 5
        )

        return MarkdownRenderConfig(
            shouldAnimateText: isStreaming,
            blockQuoteStyle: .init(
                textFonts: bodyFonts,
                textColor: DesignSystem.Colors.textSecondary
            ),
            headingStyle: .init(
                h1Font: fonts(size: 22, weight: .semibold, lineHeight: 28),
                h2Font: fonts(size: 17, weight: .semibold, lineHeight: 23),
                h3Font: fonts(size: 15, weight: .semibold, lineHeight: 21),
                h4Font: fonts(size: 14, weight: .semibold, lineHeight: 20),
                h5Font: fonts(size: 14, weight: .semibold, lineHeight: 20),
                h6Font: fonts(size: 14, weight: .semibold, lineHeight: 20),
                textColor: DesignSystem.Colors.textPrimary
            ),
            orderedListStyle: .init(
                textFonts: bodyFonts,
                textColor: DesignSystem.Colors.textPrimary
            ),
            paragraphStyle: .init(
                textFonts: bodyFonts,
                textColor: DesignSystem.Colors.textPrimary
            ),
            tableStyle: .init(
                textFonts: smallFonts,
                headerTextColor: DesignSystem.Colors.textPrimary,
                regularTextColor: DesignSystem.Colors.textPrimary,
                headerBackgroundColor: DesignSystem.Colors.surfaceElevated,
                borderColor: DesignSystem.Colors.border,
                actionButtonColor: DesignSystem.Colors.accent
            ),
            inlineStyle: .init(
                boldTextColor: DesignSystem.Colors.textPrimary,
                linkTextFont: bodyFonts.normal,
                linkTextColor: DesignSystem.Colors.accentDark,
                linkUnderlineStyle: .single,
                codeTextFont: codeFonts.normal,
                codeTextColor: DesignSystem.Colors.textPrimary,
                codeBackgroundColor: DesignSystem.Colors.surfaceElevated,
                codeUnderlineColor: DesignSystem.Colors.border
            ),
            citationConfig: .init(
                isEnabled: false,
                font: smallFonts.normal,
                textColor: DesignSystem.Colors.textSecondary,
                backgroundColor: DesignSystem.Colors.surfaceElevated
            ),
            codeBlockConfig: .init(
                theme: .xcode,
                backgroundColor: DesignSystem.Colors.surfaceElevated,
                foregroundColor: DesignSystem.Colors.textSecondary,
                codeTextFonts: codeFonts,
                chromeTextFonts: smallFonts
            ),
            blockSpacing: 10,
            textSelectionConfig: .default,
            thematicBreakColor: DesignSystem.Colors.divider,
            imageConfig: .disabled
        )
    }

    private static func fonts(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        lineHeight: CGFloat
    ) -> TextFonts {
        let regular = NSFont.systemFont(ofSize: size, weight: weight)
        let bold = NSFont.systemFont(ofSize: size, weight: .semibold)
        return TextFonts(
            normal: regular,
            italic: NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask),
            bold: bold,
            boldItalic: NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask),
            preferredLetterSpacing: 0,
            preferredLineHeight: lineHeight
        )
    }
}

/// Writes the renderer's normalized table Markdown without blocking the UI actor.
enum MarkdownTableExporter {
    static func write(_ content: String, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try content.write(to: destination, atomically: true, encoding: .utf8)
        }.value
    }
}

private final class MarkdownContentInteractionListener: MarkdownListener {
    static let shared = MarkdownContentInteractionListener()

    func onRender(markdown _: RenderableDocument) async {}

    func onTableCopyTap(content: String) async {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
        }
    }

    func onTableDownloadTap(content: String) async {
        let destination = await MainActor.run { () -> URL? in
            let panel = NSSavePanel()
            panel.title = "Export Markdown table"
            panel.nameFieldStringValue = "table.md"
            panel.allowedContentTypes = [.plainText]
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
        guard let destination else { return }
        do {
            try await MarkdownTableExporter.write(content, to: destination)
        } catch {
            await MainActor.run {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    func onContextMenuAppear(id _: String, selectedContent _: String) async {}
    func onContextMenuTap(id _: String, selectedContent _: String) async {}
    func onImageTap(image _: MarkdownImage) async {}
}
#else
/// Plain-text compile-time fallback used only by the first-party Swift 6 gate
/// while SwiftStreamingMarkdown's dependency graph remains Swift 5-only.
struct MarkdownContentView: View {
    let content: String
    let font: Font

    init(
        _ content: String,
        font: Font = DesignSystem.Typography.body,
        isStreaming _: Bool = false
    ) {
        self.content = content
        self.font = font
    }

    var body: some View {
        Text(content)
            .font(font)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
#endif
