import AppKit
import CoreGraphics

/// Push-to-talk on a modifier key, from two independent sources:
///  1. NSEvent global + local monitors for flagsChanged. These need only **Accessibility**
///     (already required to paste), so Fn works in every app once that one permission is on.
///  2. A listen-only CGEventTap, like Wispr Flow's Swift helper ("Keyboard service event tap").
///     It needs **Input Monitoring**; without it the tap only sees this app's own events.
/// Both feed the same state machine, so duplicate events are ignored.
final class HotkeyMonitor {
    enum Trigger: String {
        case fn, rightOption = "right_option", rightCommand = "right_command"

        var label: String {
            switch self {
            case .fn: return "Fn"
            case .rightOption: return "Option direito"
            case .rightCommand: return "Command direito"
            }
        }

        /// Returns whether the key is down, or nil if this event is about another key.
        func isDown(keyCode: Int64, flags: CGEventFlags) -> Bool? {
            switch self {
            case .fn:
                guard keyCode == 63 || keyCode == 179 else { return nil } // kVK_Function / globe
                return flags.contains(.maskSecondaryFn)
            case .rightOption:
                guard keyCode == 61 else { return nil }
                return flags.contains(.maskAlternate)
            case .rightCommand:
                guard keyCode == 54 else { return nil }
                return flags.contains(.maskCommand)
            }
        }
    }

    private let trigger: Trigger
    private let onChange: (Bool) -> Void
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

    init(trigger: Trigger, onChange: @escaping (Bool) -> Void) {
        self.trigger = trigger
        self.onChange = onChange
    }

    /// Returns true if at least one source is active.
    @discardableResult
    func start() -> Bool {
        startEventMonitors()
        let tapOK = startEventTap()
        return tapOK || globalMonitor != nil
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tapSource = nil
        isDown = false
    }

    // MARK: - Sources

    private func startEventMonitors() {
        // Events going to other apps (requires Accessibility trust).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(keyCode: Int64(event.keyCode), flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
        }
        // Events going to RustleApp itself (global monitors don't see those).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(keyCode: Int64(event.keyCode), flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
            return event
        }
    }

    private func startEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // macOS disables taps that stall; re-enable like Wispr's "attempting to restart tap".
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else {
                    monitor.handle(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    // MARK: - State

    private func handle(keyCode: Int64, flags: CGEventFlags) {
        guard let down = trigger.isDown(keyCode: keyCode, flags: flags), down != isDown else { return }
        isDown = down
        onChange(down)
    }
}
