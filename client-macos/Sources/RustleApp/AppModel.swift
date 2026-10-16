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

    /// A note, shared by the hub's Notes page and the Scratchpad window (as in Wispr Flow, where
    /// scratchpad notes are the hub notes). Fields after `updated` were added for the Scratchpad;
    /// they are optional on decode so notes saved by earlier versions still load.
    struct Note: Codable, Identifiable, Hashable {
        var id = UUID()
        var body: String = ""
        var updated = Date()
        var created = Date()
        /// Title set by renaming the tab; otherwise the first line is the title.
        var customTitle: String?
        var pinned = false
        /// Version history, oldest first ("Created", "Dictated", "Typed edits", "Transform"...).
        var versions: [NoteVersion] = []

        init(body: String = "") {
            self.body = body
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
            updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? Date()
            created = try c.decodeIfPresent(Date.self, forKey: .created) ?? updated
            customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            versions = try c.decodeIfPresent([NoteVersion].self, forKey: .versions) ?? []
        }

        var title: String {
            if let customTitle, !customTitle.trimmingCharacters(in: .whitespaces).isEmpty { return customTitle }
            let first = body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            let trimmed = first.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^(#+|-\s\[[ x]\]|[-*•>]|\d+\.)\s+"#, with: "", options: .regularExpression)
            return trimmed.isEmpty ? "Nota sem título" : String(trimmed.prefix(60))
        }
        var isEmpty: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    struct NoteVersion: Codable, Identifiable, Hashable {
        enum Source: String, Codable {
            case created, dictated, typed, transform, customTransform

            var label: String {
                switch self {
                case .created: return "Criada"
                case .dictated: return "Ditado"
                case .typed: return "Edições digitadas"
                case .transform: return "Transformação"
                case .customTransform: return "Transformação personalizada"
                }
            }
            var icon: String {
                switch self {
                case .created: return "plus.circle"
                case .dictated: return "mic"
                case .typed: return "keyboard"
                case .transform, .customTransform: return "sparkles"
                }
            }
        }
        var id = UUID()
        var date = Date()
        var source: Source
        var body: String
    }

    /// Mirrors server/formatter.py `Settings`; the server reloads this file when it changes.
    struct ServerSettings: Codable, Equatable {
        var dictionary: [String] = ["RustleApp"]
        var replacements: [String: String] = [:]
        var snippets: [String: String] = [:]
        /// The "polish with AI" toggle (key name kept for compatibility with older settings files).
        var use_claude: Bool = false
        /// Preferred LLM: "claude" or "deepseek". The server uses the other one when this one has no key.
        var ai_provider: String = "claude"
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
            ai_provider = try c.decodeIfPresent(String.self, forKey: .ai_provider) ?? d.ai_provider
            styles = d.styles.merging(try c.decodeIfPresent([String: String].self, forKey: .styles) ?? [:]) { $1 }
        }
    }

    // MARK: Profile (asked in the onboarding questionnaire, editable in Settings → Perfil)

    /// Shown in "Bem-vindo de volta, <nome>". Wispr takes it from the account it signs you up
    /// with; RustleApp has no account, so the first onboarding question asks for it.
    @Published var firstName: String = UserDefaults.standard.string(forKey: Prefs.firstName) ?? "" {
        didSet { if persist { UserDefaults.standard.set(firstName.trimmingCharacters(in: .whitespaces), forKey: Prefs.firstName) } }
    }
    @Published var lastName: String = UserDefaults.standard.string(forKey: Prefs.lastName) ?? "" {
        didSet { if persist { UserDefaults.standard.set(lastName.trimmingCharacters(in: .whitespaces), forKey: Prefs.lastName) } }
    }
    /// The macOS account's first name, offered as the default answer.
    static let systemFirstName: String = (NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()).capitalized
    static let systemLastName: String = NSFullUserName().split(separator: " ").dropFirst().joined(separator: " ")
    var displayFirstName: String { firstName.trimmingCharacters(in: .whitespaces) }

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
    /// Opens the Scratchpad window, optionally on one note.
    var openScratchpad: (UUID?) -> Void = { _ in }

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

    // MARK: Notes

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    func updateNote(_ id: UUID, _ change: (inout Note) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[i])
    }

    /// Records a version unless the text did not change. Consecutive typed edits collapse into one
    /// version per 2 minutes, so typing does not flood the history.
    func addVersion(_ id: UUID, source: NoteVersion.Source) {
        updateNote(id) { n in
            guard n.versions.last?.body != n.body else { return }
            if source == .typed, let last = n.versions.last, last.source == .typed,
               Date().timeIntervalSince(last.date) < 120 {
                n.versions[n.versions.count - 1].body = n.body
                n.versions[n.versions.count - 1].date = Date()
            } else {
                n.versions.append(NoteVersion(source: source, body: n.body))
            }
            if n.versions.count > 50 { n.versions.removeFirst(n.versions.count - 50) }
        }
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
    /// "Você" line that repeats what "Outros" said around the same time is dropped as echo.
    /// Re-checked on every update because the two streams are transcribed out of order.
    func appendSegments(_ new: [Meeting.Segment], to id: UUID) {
        updateMeeting(id) { m in
            m.segments.append(contentsOf: new)
            let system = m.segments.filter { $0.speaker == .them }
            m.segments.removeAll { $0.speaker == .you && Self.isEcho($0, of: system) }
        }
    }

    /// Replaces segment text with the AI-corrected version, then re-runs the echo check
    /// (corrected text matches the other stream more reliably).
    func correctSegments(_ texts: [UUID: String], in id: UUID) {
        updateMeeting(id) { m in
            for i in m.segments.indices { if let t = texts[m.segments[i].id] { m.segments[i].text = t } }
            let system = m.segments.filter { $0.speaker == .them }
            m.segments.removeAll { $0.speaker == .you && Self.isEcho($0, of: system) }
        }
    }

    /// True when most of the mic line's words were also said on the system audio within ±4 s.
    /// Words match fuzzily: Whisper hears the bleed slightly differently ("deixa"/"deixo", "anda"/"manda").
    static func isEcho(_ mic: Meeting.Segment, of system: [Meeting.Segment]) -> Bool {
        let nearby = system.filter { mic.start < $0.end + 4 && mic.end > $0.start - 4 }
        guard !nearby.isEmpty else { return false }
        func words(_ s: String) -> [String] {
            s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                .split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
        }
        let a = Set(words(mic.text))
        let b = Set(nearby.flatMap { words($0.text) })
        guard !a.isEmpty, !b.isEmpty else { return false }
        let matched = a.filter { w in b.contains(w) || b.contains { similar(w, $0) } }.count
        return Double(matched) / Double(a.count) >= 0.6
    }

    /// Edit-distance similarity ≥ 0.7 for words of 4+ letters ("ponta"/"ponto", "bale"/"bala").
    private static func similar(_ x: String, _ y: String) -> Bool {
        let a = Array(x), b = Array(y)
        guard min(a.count, b.count) >= 4, abs(a.count - b.count) <= 3 else { return false }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = a[i - 1] == b[j - 1] ? prev : min(prev, row[j], row[j - 1]) + 1
                prev = cur
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count)) >= 0.7
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
    static let whisperModel = "whisperModel" // base | small | medium | large-v3-turbo
    /// Notetaker model; can be bigger than the dictation one since meetings aren't latency-bound.
    static let meetingWhisperModel = "meetingWhisperModel"
    static let scratchpadOpenBehavior = "scratchpadOpenBehavior" // resume | new_tab | last_pinned
    static let scratchpadLastNote = "scratchpadLastNote"
    static let onboardingDone = "onboardingDone"
    static let firstName = "profileFirstName"
    static let lastName = "profileLastName"
    static let role = "profileRole"
    static let typingPlaces = "profileTypingPlaces"
}
