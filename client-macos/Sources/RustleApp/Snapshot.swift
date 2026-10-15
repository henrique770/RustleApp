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
