import Foundation

/// One Notetaker recording, modeled on what Wispr Flow's hub shows for a meeting:
/// title, live transcript labeled You / Them, the user's own notepad, and the post-meeting
/// "Enhanced Summary" + "Action Items".
struct Meeting: Codable, Identifiable, Hashable {
    enum Speaker: String, Codable { case you, them
        /// Wispr labels the drawer "You" / "Them" (hub_meeting_drawer_speaker_you / _others).
        var label: String { self == .you ? "Você" : "Outros" }
    }

    struct Segment: Codable, Identifiable, Hashable {
        var id = UUID()
        var speaker: Speaker
        /// Seconds since the meeting started.
        var start: Double
        var end: Double
        var text: String
    }

    struct SummarySection: Codable, Hashable {
        var heading: String
        var bullets: [String]
    }

    struct ActionItem: Codable, Identifiable, Hashable {
        var id = UUID()
        var text: String
        var owner: String = ""
        var done = false
    }

    struct ChatMessage: Codable, Identifiable, Hashable {
        var id = UUID()
        var fromUser: Bool
        var text: String
    }

    enum Status: String, Codable { case recording, processing, ready }

    var id = UUID()
    var title: String = ""
    var started = Date()
    var ended: Date?
    var status: Status = .recording
    var segments: [Segment] = []
    var userNotes: String = ""
    var summary: [SummarySection] = []
    var actionItems: [ActionItem] = []
    var summaryEngine: String?
    var chat: [ChatMessage] = []
    /// App the meeting was detected in (Zoom, Teams, Meet…), when known.
    var appName: String?

    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return "Reunião \(started.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
    }

    var duration: TimeInterval { (ended ?? Date()).timeIntervalSince(started) }

    var durationLabel: String {
        let m = Int(duration) / 60
        return m < 1 ? "< 1 min" : m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }

    var orderedSegments: [Segment] { segments.sorted { $0.start < $1.start } }

    var transcriptText: String {
        orderedSegments.map { "\($0.speaker.label): \($0.text)" }.joined(separator: "\n")
    }
}

/// HTTP client for the Notetaker endpoints of rustle-server.
struct NotetakerClient {
    let baseURL: URL

    struct Line: Codable { let speaker: String; let start: Double; let text: String }

    struct NotesResult: Decodable {
        struct Item: Decodable { let text: String; let owner: String }
        let title: String
        let summary: [Meeting.SummarySection]
        let action_items: [Item]
        let engine: String
    }

    func transcribe(wav: Data, language: String) async throws -> [(start: Double, end: Double, text: String)] {
        struct Req: Encodable { let audio_wav_b64: String; let language: String }
        struct Res: Decodable { struct S: Decodable { let start: Double; let end: Double; let text: String }; let segments: [S] }
        let res: Res = try await post("v1/transcribe", Req(audio_wav_b64: wav.base64EncodedString(), language: language), timeout: 120)
        return res.segments.map { ($0.start, $0.end, $0.text) }
    }

    func notes(for meeting: Meeting, language: String) async throws -> NotesResult {
        struct Req: Encodable { let transcript: [Line]; let user_notes: String; let title: String; let language: String }
        return try await post("v1/notes", Req(transcript: lines(meeting), user_notes: meeting.userNotes,
                                              title: meeting.title, language: language), timeout: 240)
    }

    func ask(_ question: String, about meeting: Meeting) async throws -> String {
        struct Req: Encodable {
            let question: String; let transcript: [Line]; let user_notes: String; let summary: [Meeting.SummarySection]
        }
        struct Res: Decodable { let answer: String }
        let res: Res = try await post("v1/notes/ask", Req(question: question, transcript: lines(meeting),
                                                          user_notes: meeting.userNotes, summary: meeting.summary), timeout: 120)
        return res.answer
    }

    private func lines(_ m: Meeting) -> [Line] {
        m.orderedSegments.map { Line(speaker: $0.speaker.label, start: $0.start, text: $0.text) }
    }

    private func post<B: Encodable, R: Decodable>(_ path: String, _ body: B, timeout: TimeInterval) async throws -> R {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "RustleApp", code: 3, userInfo: [NSLocalizedDescriptionKey: "Servidor: \(text.prefix(200))"])
        }
        return try JSONDecoder().decode(R.self, from: data)
    }
}
