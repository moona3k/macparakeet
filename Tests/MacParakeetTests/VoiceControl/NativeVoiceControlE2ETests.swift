import AppKit
import ApplicationServices
import XCTest

@testable import MacParakeetCore

/// Opt-in. The only app observed or changed is an owned synthetic process.
@MainActor
final class NativeVoiceControlE2ETests: XCTestCase {
    func testSyntheticNativeObservationEffectsRevocationAndOCR() async throws {
        guard ProcessInfo.processInfo.environment["MACPARAKEET_NATIVE_VOICE_CONTROL_E2E"] == "1" else {
            throw XCTSkip("Set MACPARAKEET_NATIVE_VOICE_CONTROL_E2E=1 for the owned native fixture.")
        }
        let log = URL(fileURLWithPath: "/tmp/macparakeet-voice-control-e2e.log")
        try? FileManager.default.removeItem(at: log)
        Self.stage(
            "host ax=\(AXIsProcessTrusted()) screen=\(CGPreflightScreenCaptureAccess()) pid=\(ProcessInfo.processInfo.processIdentifier)"
        )
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Native qualification requires existing Accessibility and Screen Recording grants.")
        }
        let priorApplication = NSWorkspace.shared.frontmostApplication
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macparakeet-native-e2e-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = Process()
        defer {
            if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() }
            _ = priorApplication?.activate()
            try? FileManager.default.removeItem(at: directory)
        }
        let pid = try await launch(fixture, in: directory)
        Self.stage("fixture pid=\(pid) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)")
        try requireForeground(pid)

        let adapter = NativeVoiceControlAdapter(
            includeMenus: false, includeApplications: false, expectedProcessID: pid)
        let initial = try await adapter.observe()
        Self.stage("observe labels=\(initial.targets.map(\.label)) context=\(initial.contextID)")
        XCTAssertTrue(initial.contextID.hasPrefix("ax:\(pid):"))
        let checkbox = try XCTUnwrap(
            initial.targets.first { $0.label == "Qualification toggle" && $0.operations.contains(.press) })
        try requireForeground(pid)
        let receipt = try await adapter.execute(
            action: VoiceControlAction(operation: .press, targetID: checkbox.id),
            snapshot: initial, authority: ActionAuthority())
        Self.stage("press status=\(receipt.status.rawValue) message=\(receipt.message)")
        XCTAssertEqual(receipt.status, .verified)
        do {
            _ = try await adapter.execute(
                action: VoiceControlAction(operation: .press, targetID: checkbox.id),
                snapshot: initial, authority: ActionAuthority())
            XCTFail("Consumed snapshot dispatched a second time")
        } catch NativeVoiceControlError.observationExpired {
            Self.stage("consumed snapshot rejected")
        }

        try requireForeground(pid)
        let editable = try await adapter.observe()
        let field = try XCTUnwrap(
            editable.targets.first { $0.label == "Qualification input" && $0.operations.contains(.insertText) })
        let revoked = ActionAuthority()
        revoked.revoke()
        do {
            _ = try await adapter.execute(
                action: VoiceControlAction(operation: .insertText, targetID: field.id, value: "must not appear"),
                snapshot: editable, authority: revoked)
            XCTFail("Revoked authority dispatched an effect")
        } catch is CancellationError {
            Self.stage("revoked insert rejected")
        }
        try requireForeground(pid)
        let inserted = try await adapter.execute(
            action: VoiceControlAction(
                operation: .insertText, targetID: field.id, value: "Synthetic qualification text"),
            snapshot: editable, authority: ActionAuthority())
        Self.stage("insert status=\(inserted.status.rawValue)")
        XCTAssertEqual(inserted.status, .verified)
        try requireForeground(pid)
        let after = try await adapter.observe()
        let readback = after.targets.first { $0.label == "Qualification input" }?.value
        Self.stage("readback=\(readback ?? "nil")")
        XCTAssertEqual(readback, "Synthetic qualification text")

        let reader = VisionScreenTextReader()
        let enhanced = NativeVoiceControlAdapter(
            includeMenus: false, includeApplications: false, screenText: reader, expectedProcessID: pid)
        var observedWithOCR: VoiceControlSnapshot?
        for attempt in 0..<8 {
            try await ownForeground(pid)
            let snapshot = try await enhanced.observe()
            let stats = await enhanced.lastObservationStats
            Self.stage(
                "ocr-observe \(attempt) ax=\(stats.axCandidates) blocks=\(stats.screenTextBlocks) targets=\(stats.screenTextTargets) summary=\(snapshot.summary.prefix(400))"
            )
            observedWithOCR = snapshot
            if snapshot.summary.localizedCaseInsensitiveContains("LANTERN ORBIT 742") { break }
            try await Task.sleep(for: .seconds(1))
        }
        let observed = try XCTUnwrap(observedWithOCR)
        XCTAssertTrue(
            observed.summary.localizedCaseInsensitiveContains("LANTERN ORBIT 742"),
            "OCR must contribute synthetic text to the observation. \(Self.logText())")
        XCTAssertTrue(
            observed.targets.contains {
                $0.role == "text" && $0.label.localizedCaseInsensitiveContains("LANTERN ORBIT")
            },
            "Drawn text with no AX control stays a pixel target. \(Self.logText())")
    }

    private func launch(_ fixture: Process, in directory: URL) async throws -> Int32 {
        let bundle = directory.appendingPathComponent("SyntheticVoiceFixture.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/SyntheticVoiceFixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.macparakeet.synthetic-voice-fixture",
            "CFBundleExecutable": "SyntheticVoiceFixture", "CFBundleName": "SyntheticVoiceFixture",
            "CFBundlePackageType": "APPL",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let source = directory.appendingPathComponent("Fixture.swift")
        try Self.fixtureSource.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", source.path, "-o", executable.path]
        let errors = Pipe()
        compiler.standardError = errors
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Self.stage("fixture compile failed \(message)")
            XCTFail(message)
            throw NativeVoiceControlError.unsupported
        }
        fixture.executableURL = executable
        fixture.standardOutput = FileHandle.nullDevice
        fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        let pid = fixture.processIdentifier
        for _ in 0..<100 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return pid
    }

    private func ownForeground(_ pid: Int32) async throws {
        let application = NSRunningApplication(processIdentifier: pid)
        for _ in 0..<30 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return }
            _ = application?.activate()
            try await Task.sleep(for: .milliseconds(100))
        }
        try requireForeground(pid)
    }

    private func requireForeground(_ pid: Int32) throws {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard front == pid else {
            Self.stage("fixture lost foreground frontmost=\(front.map(String.init) ?? "none") expected=\(pid)")
            throw XCTSkip("Owned fixture lost foreground; refusing to observe or act on another application.")
        }
    }

    private static func stage(_ message: String) {
        VisionScreenTextReader.note("e2e: \(message)")
    }

    private static func logText() -> String {
        (try? String(contentsOf: URL(fileURLWithPath: "/tmp/macparakeet-voice-control-e2e.log"), encoding: .utf8)) ?? ""
    }

    private static let fixtureSource = #"""
        import AppKit
        final class DrawnText: NSView {
            override func draw(_ dirtyRect: NSRect) {
                NSColor.white.setFill(); bounds.fill()
                ("LANTERN ORBIT 742" as NSString).draw(at: NSPoint(x: 12, y: 18), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: NSColor.black])
            }
        }
        final class Delegate: NSObject, NSApplicationDelegate {
            var window: NSWindow!
            func applicationDidFinishLaunching(_ notification: Notification) {
                window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 560, height: 340),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Owned synthetic voice qualification"
                let drawn = DrawnText(frame: NSRect(x: 20, y: 230, width: 500, height: 72))
                drawn.setAccessibilityElement(false)
                window.contentView!.addSubview(drawn)
                let toggle = NSButton(checkboxWithTitle: "Qualification toggle", target: nil, action: nil)
                toggle.frame = NSRect(x: 30, y: 150, width: 280, height: 28)
                window.contentView!.addSubview(toggle)
                let field = NSTextField(frame: NSRect(x: 30, y: 80, width: 480, height: 28))
                field.placeholderString = ""
                field.setAccessibilityLabel("Qualification input")
                window.contentView!.addSubview(field)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(field)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate()
        app.delegate = delegate
        app.run()
        """#
}
