import AppKit
import ApplicationServices
import CoreAudio

/// Notices when a call starts, like Wispr Flow's meeting auto-detect ("Meeting detected"):
/// a meeting app is running *and* some process is using the microphone. For browser calls
/// (Google Meet, Teams on the web) the window titles are read through Accessibility.
/// Wispr goes further (reads Zoom/Teams/Meet accessibility trees for speaker names and window
/// binding); this keeps only the detection signal.
@MainActor
final class MeetingDetector {
    /// Called once per call with the app name when a meeting starts.
    var onMeetingStarted: ((String) -> Void)?
    /// Called when the mic is released and no meeting is detected any more.
    var onMeetingEnded: (() -> Void)?
    /// Return false while RustleApp itself is using the mic (dictation / Notetaker).
    var shouldCheck: () -> Bool = { true }

    private var timer: Timer?
    private var current: String?

    private static let meetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.tinyspeck.slackmacgap": "Slack",   // huddles
        "com.hnc.Discord": "Discord",
        "net.whatsapp.WhatsApp": "WhatsApp",
    ]
    /// Apps that are almost always open; without per-process mic info they would cause false alarms.
    private static let alwaysOpenApps: Set<String> = ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp"]
    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    private static let browserTitles: [(String, String)] = [
        ("Meet -", "Google Meet"), ("Meet –", "Google Meet"), ("meet.google.com", "Google Meet"),
        ("Microsoft Teams", "Microsoft Teams"), ("Zoom Meeting", "Zoom"), ("Whereby", "Whereby"),
    ]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func check() {
        guard shouldCheck() else { return }
        let found: String?
        if #available(macOS 14.4, *), let users = Self.micUsers() {
            found = detectApp(micUsers: users)
        } else {
            found = Self.micInUse() ? detectApp(micUsers: nil) : nil
        }
        if let found, current == nil {
            current = found
            Log.info("meeting detected in \(found)")
            onMeetingStarted?(found)
        } else if found == nil, current != nil {
            current = nil
            onMeetingEnded?()
        }
    }

    /// `micUsers`: bundle IDs of processes capturing audio right now (nil when unknown).
    private func detectApp(micUsers: Set<String>?) -> String? {
        func usesMic(_ id: String) -> Bool {
            guard let micUsers else { return true }
            return micUsers.contains { $0 == id || $0.hasPrefix(id + ".") }
        }
        let running = NSWorkspace.shared.runningApplications
        for app in running {
            guard let id = app.bundleIdentifier, let name = Self.meetingApps[id] else { continue }
            if micUsers == nil && Self.alwaysOpenApps.contains(id) { continue }
            if usesMic(id) { return name }
        }
        guard AXIsProcessTrusted() else { return nil }
        for app in running where Self.browsers.contains(app.bundleIdentifier ?? "") && usesMic(app.bundleIdentifier ?? "") {
            for title in Self.windowTitles(pid: app.processIdentifier) {
                if let match = Self.browserTitles.first(where: { title.contains($0.0) }) { return match.1 }
            }
        }
        return nil
    }

    private static func windowTitles(pid: pid_t) -> [String] {
        let element = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return title as? String
        }
    }

    /// Bundle IDs of the processes currently capturing audio (macOS 14.4+ Core Audio process objects).
    @available(macOS 14.4, *)
    static func micUsers() -> Set<String>? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return nil }
        var users = Set<String>()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for object in objects {
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            address.mSelector = kAudioProcessPropertyIsRunningInput
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &s, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0
            s = UInt32(MemoryLayout<pid_t>.size)
            address.mSelector = kAudioProcessPropertyPID
            if AudioObjectGetPropertyData(object, &address, 0, nil, &s, &pid) == noErr, pid == ownPID { continue }
            var bundle: Unmanaged<CFString>?
            s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            address.mSelector = kAudioProcessPropertyBundleID
            if AudioObjectGetPropertyData(object, &address, 0, nil, &s, &bundle) == noErr,
               let id = bundle?.takeRetainedValue() as String?, !id.isEmpty {
                users.insert(id)
            }
        }
        return users
    }

    /// True when any process is capturing from the default input device.
    static func micInUse() -> Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
