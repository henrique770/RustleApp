import AppKit
import ApplicationServices

/// Reads the focused app and text field through the Accessibility API.
/// Mirrors the subset of Wispr Flow's flow_api.v1.Context we observed:
/// App{name,bundle_id} and Textbox{before_text,selected_text,after_text}.
enum FocusContext {
    struct Snapshot: Encodable {
        var appName: String?
        var bundleId: String?
        var beforeText: String?
        var selectedText: String?
        var afterText: String?
    }

    static let maxContextChars = 1_000

    static func capture() -> Snapshot {
        let front = NSWorkspace.shared.frontmostApplication
        var snap = Snapshot(appName: front?.localizedName, bundleId: front?.bundleIdentifier)

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let focused: AXUIElement = copy(system, kAXFocusedUIElementAttribute) else { return snap }

        snap.selectedText = copy(focused, kAXSelectedTextAttribute)
        if let value: String = copy(focused, kAXValueAttribute),
           let rangeValue: AXValue = copy(focused, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) {
                let ns = value as NSString
                let start = max(0, min(range.location, ns.length))
                let end = max(start, min(range.location + range.length, ns.length))
                snap.beforeText = String(ns.substring(to: start).suffix(maxContextChars))
                snap.afterText = String(ns.substring(from: end).prefix(maxContextChars))
            }
        }
        return snap
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
