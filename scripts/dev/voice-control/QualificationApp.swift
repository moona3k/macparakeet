// Disposable native UI for Voice Control qualification. No user data or network.
import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var origin = NSTextField(string: "")
    var destination = NSTextField(string: "")
    var date = NSTextField(string: "")
    var result = NSTextField(labelWithString: "No search yet")
    var oneWay = NSButton(checkboxWithTitle: "One way", target: nil, action: nil)
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 180, y: 180, width: 620, height: 400),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Voice Control — disposable flight search"
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 16
        stack.alignment = .leading; stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Find a flight by voice")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        stack.addArrangedSubview(title)
        for (name, field) in [("Origin", origin), ("Destination", destination), ("Departure date", date)] {
            field.setAccessibilityLabel(name); field.placeholderString = name
            field.identifier = NSUserInterfaceItemIdentifier(name)
            field.widthAnchor.constraint(equalToConstant: 520).isActive = true
            stack.addArrangedSubview(field)
        }
        oneWay.setAccessibilityLabel("One way")
        stack.addArrangedSubview(oneWay)
        let search = NSButton(title: "Search flights", target: self, action: #selector(searchFlights))
        search.setAccessibilityLabel("Search flights")
        stack.addArrangedSubview(search); stack.addArrangedSubview(result)
        let note = NSTextField(labelWithString: "Synthetic fixture. No booking, payment, or real flight data.")
        note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 36),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 32),
        ])
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func searchFlights() {
        result.stringValue =
            "Results: \(origin.stringValue) → \(destination.stringValue), \(date.stringValue), \(oneWay.state == .on ? "one way" : "return")"
        result.setAccessibilityLabel(result.stringValue)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = FixtureDelegate()
app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
