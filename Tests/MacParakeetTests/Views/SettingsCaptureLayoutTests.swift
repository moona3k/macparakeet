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
                HStack(spacing: 8) {
                    if !granted { Button("Allow") {} }
                    Picker("Microphone", selection: .constant("default")) {
                        Text("System Default").tag("default")
                    }
                    .labelsHidden()
                    .frame(minWidth: 160, idealWidth: 220, maxWidth: 280)
                    Button {
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .frame(width: width)
        )
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
        return host.fittingSize.height
    }
}
