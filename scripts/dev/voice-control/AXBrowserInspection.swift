// Read only except optional explicit AX accessibility enablement; fixture window only.
import AppKit
import ApplicationServices
import Foundation

func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(node, name as CFString, &result) == .success ? result : nil
}
func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
}
guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier == "com.google.Chrome" else {
    print("Refusing inspection: Chrome must be frontmost and Accessibility authorized."); exit(2)
}
let application = AXUIElementCreateApplication(app.processIdentifier)
guard let window = element(attribute(application, kAXFocusedWindowAttribute)),
      (attribute(window, kAXTitleAttribute) as? String)?.contains("MacParakeet native AX flight fixture") == true else {
    print("Refusing inspection: disposable fixture must be the focused Chrome window."); exit(2)
}
if ProcessInfo.processInfo.environment["AX_BROWSER_ENABLE_ACCESSIBILITY"] == "1" {
    for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
        let result = AXUIElementSetAttributeValue(window, name as CFString, kCFBooleanTrue)
        print("ENABLE \(name) status=\(result.rawValue)")
    }
    Thread.sleep(forTimeInterval: 0.5)
}
var stack: [(AXUIElement,Int)] = [(window,0)]
var visited = Set<CFHashCode>()
var roles: [String:Int] = [:]
var count = 0
let safeLabels = ["Origin", "Destination", "Trip type", "One way", "Round trip", "Choose departure date", "20 September", "Search flights"]
while let (node,depth) = stack.popLast(), count < 1500 {
    guard visited.insert(CFHash(node)).inserted else { continue }; count += 1
    let role = attribute(node,kAXRoleAttribute) as? String ?? "?"; roles[role,default:0] += 1
    let label = [kAXTitleAttribute,kAXDescriptionAttribute].compactMap {attribute(node,$0) as? String}.first(where:{ !$0.isEmpty }) ?? ""
    if label == "Trip type", ProcessInfo.processInfo.environment["AX_BROWSER_OPEN_TRIP"] == "1" {
        print("FIXTURE_OPEN_TRIP \(AXUIElementPerformAction(node, kAXPressAction as CFString).rawValue)")
        Thread.sleep(forTimeInterval: 0.2)
    }
    if role == "AXWebArea" || safeLabels.contains(label) || role == "AXMenuItem" {
        var actions: CFArray?; AXUIElementCopyActionNames(node,&actions)
        var settable: DarwinBoolean = false; AXUIElementIsAttributeSettable(node,kAXValueAttribute as CFString,&settable)
        var names: CFArray?; AXUIElementCopyAttributeNames(node,&names)
        print("NODE depth=\(depth) role=\(role) label=\(role == "AXWebArea" ? "fixture web area" : label) value=\(attribute(node,kAXValueAttribute) as? String ?? "nil") actions=\(actions as? [String] ?? []) setValue=\(settable.boolValue) attrs=\(names as? [String] ?? [])")
        if role == "AXWebArea" {
            let url = attribute(node,"AXURL")
            let text = (url as? URL)?.absoluteString ?? (url as? String) ?? ""
            print("WEB_URL_IS_LOOPBACK \(text.hasPrefix("http://127.0.0.1:"))")
        }
    }
    if let children = attribute(node,kAXChildrenAttribute) as? [AXUIElement] {
        stack.append(contentsOf:children.reversed().map{($0,depth+1)})
    }
}
print("VISITED \(count) ROLES \(roles)")
