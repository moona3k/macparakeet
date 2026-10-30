import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels
@testable import MacParakeet
import XCTest

@MainActor
final class AskActivityViewTests: XCTestCase {
    func testNativeActivityLayoutAtNarrowAndWideWidths() throws {
        let steps = [
            AskActivity(tool: .listSources, status: .complete, sourceCount: 3),
            AskActivity(
                tool: .search, status: .complete, query: "launch deadline", resultCount: 6, sourceCount: 3,
                hasMore: true),
            AskActivity(
                tool: .read, status: .complete, sourceTitle: "Product review — September 24", resultCount: 4,
                sourceCount: 1),
        ]
        for width: CGFloat in [360, 640] {
            for dark in [false, true] {
                let collapsed = try render(steps, expanded: false, width: width, dark: dark)
                let expanded = try render(steps, expanded: true, width: width, dark: dark)
                XCTAssertEqual(expanded.size.width, width)
                XCTAssertGreaterThan(expanded.size.height, collapsed.size.height)
                XCTAssertLessThan(expanded.size.height, 420)
                try capture(expanded, name: "activity-\(Int(width))-\(dark ? "dark" : "light")")
            }
        }
        for status: AskMessage.Status in [.cancelled, .failed, .incomplete] {
            let image = try render(steps, expanded: true, width: 360, dark: false, status: status)
            XCTAssertGreaterThan(image.size.height, 100)
            try capture(image, name: "activity-\(status.rawValue)")
        }
        let writing = try render(steps, expanded: false, width: 360, dark: false, running: true)
        try capture(writing, name: "activity-writing")
    }

    func testWholeWorkspaceRendersSavedAndStreamingActivity() async throws {
        let source = UUID()
        let section = AskContextSection(sourceIDs: [source])
        let steps = [
            AskActivity(tool: .search, status: .complete, query: "launch deadline", resultCount: 6, sourceCount: 1),
            AskActivity(tool: .read, status: .complete, sourceTitle: "Product sync", resultCount: 4, sourceCount: 1),
        ]
        let conversation = AskConversation(
            title: "How the launch plan changed", sections: [section],
            messages: [
                AskMessage(sectionID: section.id, role: .user, content: "What changed about the launch deadline?"),
                AskMessage(
                    sectionID: section.id, role: .assistant,
                    content:
                        "The launch moved to **October 24** so the team could finish accessibility testing. [1]\n\nThe earlier date was a proposal; the later discussion records the revised commitment.",
                    citations: [
                        AskEvidenceReference(
                            sourceID: source, sourceRevision: "r1", segmentIndex: 0, sourceTitle: "Product sync")
                    ],
                    activities: steps),
            ])
        let service = AskWorkspaceMock(conversations: [conversation])
        await service.setSources([source])
        await service.enableControlledStream()
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(conversation.id)
        let view = AskWorkspaceView(model: model, onOpenAISettings: {}, onOpenSource: { _ in })
            .frame(width: 900, height: 740)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 740), styleMask: .borderless, backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        try capture(try snapshot(host), name: "workspace-complete")

        model.updateDraft("What should I follow up on?")
        await model.send()
        await service.waitUntilRequested("streamStarted")
        for step in steps { await service.emit(.step(step)) }
        await service.emit(.phase(.writing))
        await service.emit(.text("Follow up on the **accessibility test results** before confirming the revised date."))
        try await Task.sleep(for: .milliseconds(100))
        try capture(try snapshot(host), name: "workspace-streaming")
        await service.finishStream(text: "Follow up on the accessibility test results.")
        await model.stopAndSettle()
        XCTAssertFalse(model.isSending)
    }

    private func snapshot<V: View>(_ host: NSHostingView<V>) throws -> NSImage {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func render(
        _ steps: [AskActivity], expanded: Bool, width: CGFloat, dark: Bool,
        status: AskMessage.Status = .complete, running: Bool = false
    ) throws -> NSImage {
        let view = AskActivityView(
            activities: steps, phase: .writing, isRunning: running,
            status: status, isExpanded: .constant(expanded)
        )
        .padding(24)
        .frame(width: width, alignment: .leading)
        .background(DesignSystem.Colors.background)
        .environment(\.colorScheme, dark ? .dark : .light)
        // ImageRenderer cannot draw native Button/ProgressView backing views.
        // Render the actual AppKit hosting hierarchy without opening the application.
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.setFrameSize(size)
        return try snapshot(host)
    }

    private func capture(_ image: NSImage, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MACPARAKEET_ASK_UI_CAPTURE_DIR"] else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent(name + ".png"))
    }
}
