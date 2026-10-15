import AppKit
import SwiftUI

/// `RustleApp --snapshot <dir>` renders every hub page and every Flow bar state off-screen to PNG
/// (no Screen Recording permission needed), then exits. Used to check the UI without a display.
@MainActor
enum Snapshot {
    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(persist: false)
        model.serverState = .online
        model.permissions = .init(microphone: true, inputMonitoring: true, accessibility: true)
        if model.history.isEmpty { seed(model) }

        for page in MainView.Page.allCases {
            render(MainView(model: model, initialPage: page), size: NSSize(width: 1100, height: 720),
                   to: dir.appendingPathComponent("hub-\(page.rawValue).png"))
        }
        // Notetaker: a finished meeting, then the same page while live.
        if model.meetings.isEmpty { seedMeeting(model) }
        if let id = model.meetings.first?.id {
            model.openMeetingID = id
            render(MainView(model: model, initialPage: .notetaker), size: NSSize(width: 1100, height: 900),
                   to: dir.appendingPathComponent("notetaker-meeting.png"))
            model.activeMeetingID = id
            model.meetingLevels.bars = (0..<15).map { i in CGFloat([0.2, 0.6, 0.9, 0.4, 0.7][i % 5]) }
            model.meetingLevels.elapsed = 754
            render(MainView(model: model, initialPage: .notetaker), size: NSSize(width: 1100, height: 720),
                   to: dir.appendingPathComponent("notetaker-live.png"))
            model.openMeetingID = nil
            render(MainView(model: model, initialPage: .notetaker), size: NSSize(width: 1100, height: 720),
                   to: dir.appendingPathComponent("notetaker-list-live.png"))
            model.activeMeetingID = nil
        }

        // Onboarding questionnaire, every step.
        for step in OnboardingView.Step.allCases {
            render(OnboardingView(model: model, initialStep: step) {}, size: NSSize(width: 1100, height: 720),
                   to: dir.appendingPathComponent("onboarding-\(step.rawValue)-\(step).png"))
        }

        // Scratchpad: default, notes sidebar + transforms, formatting + version history, empty.
        let sp = ScratchpadController(model: model, client: TransformClient(baseURL: URL(string: "http://127.0.0.1:1")!))
        var note = AppModel.Note(body: "Ideias para o lançamento\n\n- [ ] Revisar a landing page com o time\n- [x] Gravar o vídeo de demo\n- [ ] Mandar o **rascunho do e-mail** para a Ana até sexta\n\n> Lembrar: o foco é velocidade, não features.")
        note.pinned = true
        note.versions = [.init(date: Date().addingTimeInterval(-3600), source: .created, body: "Ideias"),
                         .init(date: Date().addingTimeInterval(-1800), source: .dictated, body: "Ideias para o lançamento"),
                         .init(date: Date().addingTimeInterval(-300), source: .transform, body: note.body)]
        model.notes = [note, AppModel.Note(body: "Mensagem pro Pedro\nOi Pedro, consegue revisar o contrato hoje?"),
                       AppModel.Note(body: "Lista de compras\npão, café, frutas")] + model.notes
        sp.open(note: note.id)
        sp.newTab()
        sp.activate(sp.tabs[0].id)
        sp.targetApp = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }
        render(ScratchpadView(controller: sp, model: model), size: ScratchpadController.defaultSize,
               to: dir.appendingPathComponent("scratchpad.png"))
        sp.sidebarOpen = true
        sp.bottomBar = .transforms
        sp.suggestions = [.init(id: "fix", label: "Corrigir texto", prompt: ""), .init(id: "bullets", label: "Lista de tópicos", prompt: ""),
                          .init(id: "shorter", label: "Mais curto", prompt: ""), .init(id: "email", label: "Transformar em e-mail", prompt: "")]
        sp.toast = .init(message: "Copiado")
        render(ScratchpadView(controller: sp, model: model), size: NSSize(width: 720, height: 560),
               to: dir.appendingPathComponent("scratchpad-transforms.png"))
        sp.sidebarOpen = false
        sp.toast = nil
        sp.bottomBar = .formatting
        sp.versionMenuOpen = true
        render(ScratchpadView(controller: sp, model: model), size: NSSize(width: 560, height: 480),
               to: dir.appendingPathComponent("scratchpad-formatting.png"))
        sp.versionMenuOpen = false
        sp.bottomBar = .none
        sp.activate(sp.tabs[1].id)
        render(ScratchpadView(controller: sp, model: model), size: ScratchpadController.defaultSize,
               to: dir.appendingPathComponent("scratchpad-empty.png"))

        let states: [(String, OverlayModel.Phase, Bool, Bool)] = [
            ("resting", .hidden, false, false),
            ("hover", .hidden, true, false),
            ("recording", .recording, false, false),
            ("handsfree", .recording, false, true),
            ("processing", .transcribing, false, false),
            ("error", .message("O app não aceitou a colagem; o texto foi copiado. Cole com ⌘V", isError: true), false, false),
        ]
        for (name, phase, hover, handsFree) in states {
            let m = OverlayModel()
            m.phase = phase
            m.hovering = hover
            m.handsFree = handsFree
            m.levels = [0.2, 0.5, 0.8, 0.4, 0.9, 0.6, 0.3, 0.7, 0.5, 0.25, 0.1]
            // SwiftUI's own renderer: draws shapes exactly as on screen.
            let renderer = ImageRenderer(content: FlowBarPreview(model: m).frame(width: 420, height: 110))
            renderer.scale = 2
            if let cg = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("flowbar-\(name).png"))
            }
        }
        print("snapshots written to \(dir.path)")
    }

    private static func render<V: View>(_ view: V, size: NSSize, to url: URL) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func seedMeeting(_ model: AppModel) {
        var m = Meeting(title: "Planejamento do lançamento", started: Date().addingTimeInterval(-3600),
                        ended: Date().addingTimeInterval(-1500), status: .ready, appName: "Google Meet")
        m.segments = [
            .init(speaker: .them, start: 4, end: 9, text: "Bom dia! Vamos revisar o plano do lançamento da versão 2."),
            .init(speaker: .you, start: 10, end: 16, text: "Bom dia. O build está pronto, falta só o texto da página."),
            .init(speaker: .them, start: 17, end: 24, text: "A Ana fica de enviar o texto até quinta, e eu marco a reunião com o time de vendas."),
            .init(speaker: .you, start: 25, end: 30, text: "Perfeito, eu vou revisar o anúncio na sexta."),
        ]
        m.userNotes = "Lançamento na segunda\nConfirmar preço com financeiro"
        m.summary = [
            .init(heading: "Status do lançamento", bullets: ["Build da versão 2 está pronto.", "Falta finalizar o texto da página."]),
            .init(heading: "Próximos passos", bullets: ["Texto da página até quinta.", "Reunião com vendas a agendar.", "Lançamento previsto para segunda."]),
        ]
        m.actionItems = [
            .init(text: "Enviar o texto da página até quinta", owner: "Ana"),
            .init(text: "Agendar reunião com o time de vendas", owner: "Outros"),
            .init(text: "Revisar o anúncio na sexta", owner: "Você", done: true),
        ]
        m.summaryEngine = "claude"
        m.chat = [.init(fromUser: true, text: "O que eu perdi?"),
                  .init(fromUser: false, text: "A Ana vai enviar o texto até quinta e o time de vendas terá uma reunião antes do lançamento de segunda.")]
        model.meetings = [m]
    }

    private static func seed(_ model: AppModel) {
        let now = Date()
        let samples = [
            ("Então eu acho que a gente devia lançar o RustleApp na quinta.", "Notas", -300.0),
            ("Oi, você está livre para almoçar amanhã? Pode ser ao meio-dia", "WhatsApp", -3600.0),
            ("Vamos revisar o pull request antes da reunião de amanhã.", "Slack", -90000.0),
        ]
        for (text, app, offset) in samples {
            var e = AppModel.HistoryEntry(text: text, raw: text, appName: app, latencyMs: 900, pasted: true, durationSeconds: 4)
            e.date = now.addingTimeInterval(offset)
            model.history.append(e)
        }
    }
}

/// Flow bar on a neutral desktop-like background, for snapshots.
private struct FlowBarPreview: View {
    @ObservedObject var model: OverlayModel
    var body: some View {
        FlowBarView(model: model)
            .background(LinearGradient(colors: [Color(hex: 0xD9D4C7), Color(hex: 0xBFC8D6)], startPoint: .top, endPoint: .bottom))
    }
}
