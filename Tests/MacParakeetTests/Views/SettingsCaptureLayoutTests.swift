import AppKit
import MacParakeetViewModels
import SwiftUI
import XCTest

@testable import MacParakeet

@MainActor
final class SettingsCaptureLayoutTests: XCTestCase {
    func testLongMicrophoneExplanationWrapsAtCompactAndRegularWidths() {
        let detail =
            "Using macOS System Default for dictation: MacBook Air Microphone. Meeting recording is set to System Audio Only."
        for width in [476.0, 712.0] {
            for granted in [true, false] {
                let short = headerHeight(status: "Using System Default.", width: width, granted: granted)
                let long = headerHeight(
                    status: String(repeating: detail + " ", count: 3), width: width, granted: granted)
                XCTAssertGreaterThan(
                    long - short, 24,
                    "The input explanation must increase the row height instead of truncating at width \(width)."
                )
            }
        }
    }

    func testSettingsHeaderStacksSearchAtCompactWidth() {
        let compact = NSHostingView(rootView: NavigationHeader().frame(width: 572))
        let regular = NSHostingView(rootView: NavigationHeader().frame(width: 900))
        compact.layoutSubtreeIfNeeded()
        regular.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            compact.fittingSize.height - regular.fittingSize.height, 24,
            "Search must move below the tabs instead of widening the entire Settings panel."
        )
    }

    func testMicrophoneControlsStayInsideHeaderAndStackWhenSpaceIsTight() throws {
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasEnhanced = NSApplication.shared.accessibilityAttributeValue(enhancedUI) as? Bool ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { NSApplication.shared.accessibilitySetValue(wasEnhanced, forAttribute: enhancedUI) }

        for (width, granted, stacked) in [
            (476.0, true, true), (476.0, false, true), (524.0, false, true),
            (712.0, true, false), (712.0, false, false),
        ] {
            let host = NSHostingView(
                rootView: SettingsMicrophoneHeader(
                    microphoneGranted: granted, statusText: "Using System Default."
                ) {
                    self.microphoneControls(granted: granted)
                }
                .background(LayoutMarker(name: "header"))
                .frame(width: width)
                .frame(maxHeight: .infinity, alignment: .top)
            )
            let window = LayoutWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 200),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()

            let header = try markerFrame("header", in: host)
            let controls = try markerFrame("controls", in: host)
            let heading = try XCTUnwrap(accessibilityHeading(in: host))
            let screenFrame = try XCTUnwrap(heading.accessibilityFrame?())
            let headingFrame = host.convert(window.convertFromScreen(screenFrame), from: nil)
            let context = "width=\(width), permissionGranted=\(granted)"
            XCTAssertEqual(header.width, width, accuracy: 1, context)
            for frame in [headingFrame, controls]
                + (try ["picker", "refresh"].map { try markerFrame($0, in: host) })
                + (granted ? [] : [try markerFrame("permission", in: host)])
            {
                XCTAssertGreaterThan(frame.width, 0, context)
                XCTAssertGreaterThan(frame.height, 0, context)
                XCTAssertGreaterThanOrEqual(frame.minX, header.minX - 1, context)
                XCTAssertLessThanOrEqual(frame.maxX, header.maxX + 1, context)
                XCTAssertGreaterThanOrEqual(frame.minY, header.minY - 1, context)
                XCTAssertLessThanOrEqual(frame.maxY, header.maxY + 1, context)
            }
            if stacked {
                XCTAssertGreaterThanOrEqual(
                    controls.minY, headingFrame.maxY + DesignSystem.Spacing.sm - 1,
                    "Controls must move below the heading: \(context)"
                )
            } else {
                XCTAssertEqual(controls.midY, headingFrame.midY, accuracy: 4, context)
            }
        }
    }

    private final class LayoutWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

    private struct LayoutMarker: NSViewRepresentable {
        let name: String

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.identifier = NSUserInterfaceItemIdentifier(name)
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private func markerFrame(_ name: String, in host: NSView) throws -> CGRect {
        func find(in view: NSView) -> NSView? {
            if view.identifier?.rawValue == name, view.bounds.width > 0 { return view }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        let marker = try XCTUnwrap(find(in: host), "Missing rendered layout marker: \(name)")
        return host.convert(marker.bounds, from: marker)
    }

    private func accessibilityHeading(in root: AnyObject) -> AnyObject? {
        var visited: Set<ObjectIdentifier> = []
        func find(in element: AnyObject) -> AnyObject? {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
            let value: Any? = element.accessibilityValue?()
            if element.accessibilityRole?() == .staticText,
                element.accessibilityLabel?() == "Microphone"
                    || (value as? String) == "Microphone"
            {
                return element
            }
            for child in element.accessibilityChildren?() ?? [] {
                if let result = find(in: child as AnyObject) { return result }
            }
            for child in (element as? NSView)?.subviews ?? [] {
                if let result = find(in: child) { return result }
            }
            return nil
        }
        return find(in: root)
    }

    private func microphoneControls(granted: Bool) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            if !granted {
                Button("Settings") {}
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .background(LayoutMarker(name: "permission"))
            }
            Picker("Microphone", selection: .constant("default")) {
                Text("System Default").tag("default")
            }
            .labelsHidden()
            .frame(minWidth: 160, idealWidth: 220, maxWidth: 280)
            .background(LayoutMarker(name: "picker"))
            Button {
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .parakeetAction(.secondary)
            .accessibilityLabel("Refresh microphones")
            .background(LayoutMarker(name: "refresh"))
        }
        .background(LayoutMarker(name: "controls"))
    }

    private struct NavigationHeader: View {
        @FocusState private var searchFocused: Bool

        var body: some View {
            SettingsHeaderLayout {
                SettingsTabBar(
                    activeTab: .constant(.capture),
                    tabBadges: [.capture: .required, .engine: .recommended, .system: .required]
                )
                SettingsSearchField(query: .constant(""), isFocused: $searchFocused)
                    .frame(minWidth: 200, maxWidth: 280)
                    .layoutPriority(1)
            }
        }
    }

    private func headerHeight(status: String, width: CGFloat, granted: Bool) -> CGFloat {
        let host = NSHostingView(
            rootView: SettingsMicrophoneHeader(microphoneGranted: granted, statusText: status) {
                self.microphoneControls(granted: granted)
            }
            .frame(width: width)
        )
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
        return host.fittingSize.height
    }
}
