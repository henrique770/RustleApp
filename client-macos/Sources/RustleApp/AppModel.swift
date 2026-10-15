import AppKit
import Foundation
import SwiftUI

/// Everything the desktop window shows: history, notes, dictionary/snippets (shared with
/// rustle-server through settings.json), live status, and the actions the window can trigger.
@MainActor
final class AppModel: ObservableObject {
    // MARK: Data

    struct HistoryEntry: Codable, Identifiable, Hashable {
        var id = UUID()
        var date = Date()
        var text: String
        var raw: String
        var appName: String?
        var latencyMs: Int
        var pasted: Bool
        /// Optional so history saved by earlier versions still decodes.
        var durationSeconds: Double? = nil
        var words: Int { text.split(whereSeparator: \.isWhitespace).count }
    }

    struct Note: Codable, Identifiable, Hashable {
        var id = UUID()
        var body: String = ""
        var updated = Date()
        var title: String {
            let first = body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Nota sem título" : String(trimmed.prefix(60))
        }
    }

    /// Mirrors server/formatter.py `Settings`; the server reloads this file when it changes.
    struct ServerSettings: Codable, Equatable {
        var dictionary: [String] = ["RustleApp"]
        var replacements: [String: String] = [:]
        var snippets: [String: String] = [:]
        var use_claude: Bool = false
        /// Tone per app category, like Wispr's Style page: personal / work / email / other
        /// -> formal | casual | very_casual | excited.
        var styles: [String: String] = ["personal": "casual", "work": "formal", "email": "formal", "other": "formal"]

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = ServerSettings()
            dictionary = try c.decodeIfPresent([String].self, forKey: .dictionary) ?? d.dictionary
            replacements = try c.decodeIfPresent([String: String].self, forKey: .replacements) ?? d.replacements
            snippets = try c.decodeIfPresent([String: String].self, forKey: .snippets) ?? d.snippets
            use_claude = try c.decodeIfPresent(Bool.self, forKey: .use_claude) ?? d.use_claude
            styles = d.styles.merging(try c.decodeIfPresent([String: String].self, forKey: .styles) ?? [:]) { $1 }
        }
    }

    /// First name for the "Bem-vindo de volta" greeting.
    let firstName: String = (NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()).capitalized

    @Published var history: [HistoryEntry] = [] { didSet { save(history, "history.json") } }
    @Published var notes: [Note] = [] { didSet { save(notes, "notes.json") } }
    @Published var serverSettings = ServerSettings() { didSet { save(serverSettings, "settings.json") } }
    @Published var meetings: [Meeting] = [] { didSet { save(meetings, "meetings.json") } }

    // MARK: Notetaker live state

    /// The meeting being recorded, if any.
    @Published var activeMeetingID: UUID?
    /// Meeting app seen by MeetingDetector while nothing is recording ("Reunião detectada no Zoom").
    @Published var detectedMeetingApp: String?
    /// Why system audio could not be captured (permission, macOS version); nil when it works.
    @Published var systemAudioError: String?
    /// Meeting whose summary or chat answer is being generated.
    @Published var busyMeetingIDs: Set<UUID> = []
    /// Navigation requests from outside the window (menu bar, Flow bar prompt).
    @Published var pageRequest: MainView.Page?
    @Published var openMeetingID: UUID?
    /// Live levels live in their own object so the waveform does not redraw every page.
    let meetingLevels = MeetingLevels()

    // MARK: Status

    enum ServerState: Equatable { case starting, online, offline(String) }

    struct Permissions: Equatable {
        var microphone = false
        var inputMonitoring = false
        var accessibility = false
        /// Input Monitoring is optional: the Accessibility-based key monitor covers every app.
        var allGranted: Bool { microphone && accessibility }
    }

    @Published var serverState: ServerState = .starting
    @Published var permissions = Permissions()

    // MARK: Actions (wired by AppDelegate)

    var testPaste: () -> Void = {}
    var repairPermissions: () -> Void = {}
    var relaunch: () -> Void = {}
    var restartServer: () -> Void = {}
    var hotkeyChanged: () -> Void = {}
    /// Starts Notetaker (optionally for a detected app) and returns the new meeting's ID.
    var startMeeting: (String?) -> UUID? = { _ in nil }
    var stopMeeting: () -> Void = {}
    var generateNotes: (UUID) -> Void = { _ in }
    var askMeeting: (UUID, String) -> Void = { _, _ in }

    // MARK: Persistence

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RustleApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    private var loading = true
    /// False for throwaway models (snapshots): nothing is written to disk.
    private let persist: Bool

    init(persist: Bool = true) {
        self.persist = persist
        history = load("history.json") ?? []
        notes = load("notes.json") ?? []
        serverSettings = load("settings.json") ?? ServerSettings()
        meetings = load("meetings.json") ?? []
        // A meeting left "recording" by a crash or quit is finished now.
        for i in meetings.indices where meetings[i].status != .ready {
            meetings[i].status = .ready
            meetings[i].ended = meetings[i].ended ?? meetings[i].segments.last.map { meetings[i].started.addingTimeInterval($0.end) }
        }
        loading = false
        // Make sure the server has a settings file to read on first launch.
        if persist, !FileManager.default.fileExists(atPath: Self.settingsURL.path) { save(serverSettings, "settings.json") }
    }

    func record(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
    }

    // MARK: Notetaker

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    func updateMeeting(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[i])
    }

    /// Adds transcribed segments. Without headphones the mic also hears the other people, so a
    /// "Você" line that repeats an overlapping "Outros" line is dropped as echo.
    func appendSegments(_ new: [Meeting.Segment], to id: UUID) {
        updateMeeting(id) { m in
            for seg in new {
                if seg.speaker == .you,
                   m.segments.contains(where: { $0.speaker == .them && Self.isEcho(seg, of: $0) }) { continue }
                if seg.speaker == .them {
                    m.segments.removeAll { $0.speaker == .you && Self.isEcho($0, of: seg) }
                }
                m.segments.append(seg)
            }
        }
    }

    private static func isEcho(_ mic: Meeting.Segment, of system: Meeting.Segment) -> Bool {
        guard mic.start < system.end + 4, mic.end > system.start - 4 else { return false }
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        }
        let a = words(mic.text), b = words(system.text)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count)) >= 0.6
    }

    var totalWords: Int { history.reduce(0) { $0 + $1.words } }
    /// Consecutive days (ending today or yesterday) with at least one dictation.
    var dayStreak: Int {
        let cal = Calendar.current
        let days = Set(history.map { cal.startOfDay(for: $0.date) })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var streak = 0
        while days.contains(day) {
            streak += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    /// Words per minute over recent dictations that recorded their audio length.
    var wordsPerMinute: Int {
        let recent = history.prefix(50).filter { ($0.durationSeconds ?? 0) > 0 }
        let words = recent.reduce(0) { $0 + $1.words }
        let seconds = recent.reduce(0) { $0 + ($1.durationSeconds ?? 0) }
        return seconds > 0 ? Int(Double(words) / seconds * 60) : 0
    }

    var averageLatency: Int {
        history.isEmpty ? 0 : history.prefix(50).reduce(0) { $0 + $1.latencyMs } / min(history.count, 50)
    }

    private func load<T: Decodable>(_ name: String) -> T? {
        let url = Self.directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard !loading, persist else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: Self.directory.appendingPathComponent(name), options: .atomic)
    }
}

/// Mic / system audio levels while Notetaker records (0…1, log-scaled for display).
@MainActor
final class MeetingLevels: ObservableObject {
    @Published var bars: [CGFloat] = Array(repeating: 0, count: 15)
    @Published var elapsed: TimeInterval = 0

    func push(mic: Float, system: Float) {
        let level = max(mic, system)
        let db = 20 * log10(max(level, 1e-5))
        bars.removeFirst()
        bars.append(CGFloat(max(0, min(1, (db + 55) / 45))))
    }
}

/// User preferences that live in UserDefaults (also read by Config / ServerManager).
enum Prefs {
    static let hotkey = "hotkey"            // fn | right_option | right_command
    static let language = "language"        // pt | en | auto
    static let whisperModel = "whisperModel" // base | small | medium
}
