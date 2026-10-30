// PID-scoped AX actions for one journey. No global keystrokes or clipboard changes.
import AppKit
import ApplicationServices

func fail(_ message: String) -> Never {
    fputs("Native Library AX: \(message)\n", stderr)
    exit(1)
}
let args = CommandLine.arguments
guard args.count >= 4, let pid = Int32(args[1]),
      let application = NSRunningApplication(processIdentifier: pid) else { fail("usage: PID action identifier [value]") }
guard AXIsProcessTrusted() else { fail("Grant Accessibility to the runner terminal in the disposable account") }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 2)
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func find(_ root: AXUIElement, _ identifier: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 40 else { return nil }
    if attribute(root, kAXIdentifierAttribute) as? String == identifier { return root }
    for child in (attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
        if let found = find(child, identifier, depth: depth + 1) { return found }
    }
    return nil
}
func textArea(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 10 else { return nil }
    if attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole { return element }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
        if let found = textArea(child, depth: depth + 1) { return found }
    }
    return nil
}
application.activate(options: [])
let deadline = Date().addingTimeInterval(30)
if args[2] == "quit" {
    guard application.terminate() else { fail("App refused ordinary termination") }
    while !application.isTerminated && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard application.isTerminated else { fail("App did not finish ordinary quit and save flush") }
    print("PASS ordinary quit")
    exit(0)
}
var target: AXUIElement?
repeat {
    target = find(app, args[3])
    if target != nil { break }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
} while Date() < deadline && !application.isTerminated
guard let element = target else { fail("Timed out finding \(args[3]); dismiss onboarding and open Library before qualification") }
switch args[2] {
case "press":
    guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
        fail("No AXPress action on \(args[3])")
    }
case "set":
   guard args.count == 5,
          AXUIElementSetAttributeValue(textArea(element) ?? element, kAXValueAttribute as CFString, args[4] as CFString) == .success else {
        fail("Cannot set editor value")
    }
case "assert":
    guard args.count == 5 else { fail("Expected editor value argument") }
    var matches = false
    repeat {
        if let current = find(app, args[3]) {
            matches = attribute(textArea(current) ?? current, kAXValueAttribute) as? String == args[4]
        }
        if matches { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline && !application.isTerminated
    guard matches else {
        fail("Timed out waiting for persisted notes")
    }
default: fail("Unknown action")
}
print("PASS \(args[2]) \(args[3])")
