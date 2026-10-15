import AppKit
import SwiftUI

/// The Flow bar, rebuilt from Wispr Flow's status-window CSS (bottom position):
///   resting      40x8   rgba(0,0,0,.5), 1px white/50% border, radius 6   (always on screen)
///   ready        50x30  black, hover bg vast-900 / border vast-700         (mouse over the bar)
///   recording    73x30  black, radius 22.5, 1px vast-900, live waveform   (holding the hotkey)
///   hands-free  102.5x30 same + stop button                               (started by clicking)
///   processing   98x30  black with a rotating conic "rainbow" border      (transcribing)
///   error        91x30  1.5px destructive-500 border
/// Tooltips: black pill, radius 34, 1px vast-900, 15px white text, padding 6x14.
@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case hidden                    // shown as the resting pill
        case loading(String)
        case recording
        case transcribing
        case message(String, isError: Bool)
    }

    @Published var phase: Phase = .hidden
    @Published var hovering = false
    @Published var handsFree = false
    /// Notetaker is recording a meeting: the resting pill shows a red dot (dictation still works).
    @Published var meetingRecording = false
    /// "Reunião detectada" reminder (Wispr: hub_calendar_reminder_title_autodetect); a click starts Notetaker.
    @Published var meetingPrompt: String?
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 11)

    func push(level: Float) {
        // RMS -> 0...1 with a soft log curve so normal speech fills the bars.
        let db = 20 * log10(max(level, 1e-5))
        let normalized = CGFloat(max(0, min(1, (db + 55) / 45)))
        levels.removeFirst()
        levels.append(normalized)
    }

    func resetLevels() { levels = Array(repeating: 0, count: levels.count) }
}

@MainActor
final class OverlayPanel {
    let model = OverlayModel()
    /// Called when the user clicks the bar (start / stop hands-free dictation).
    var onClick: () -> Void = {}
    /// Called when the user clicks the bar while a "meeting detected" prompt is showing.
    var onMeetingPromptClick: () -> Void = {}
    private var promptWork: DispatchWorkItem?

    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    private var mouseTimer: Timer?
    private var clickMonitor: Any?
    private static let size = NSSize(width: 420, height: 110)
    /// Hot zone around the pill (in panel coordinates, origin bottom-left).
    private var hotRect: NSRect {
        let w: CGFloat = model.phase == .hidden && !model.hovering && model.meetingPrompt == nil ? 90 : 140
        return NSRect(x: (Self.size.width - w) / 2, y: 0, width: w, height: 44)
    }

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: FlowBarView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host

        position()
        panel.orderFrontRegardless()
        startMouseTracking()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
    }

    func show(_ phase: OverlayModel.Phase, autoHideAfter seconds: Double? = nil) {
        hideWork?.cancel()
        if phase == .recording { model.resetLevels() }
        if phase == .hidden { model.handsFree = false }
        withAnimation(.timingCurve(0.05, 0.6, 0.4, 0.95, duration: 0.18)) { model.phase = phase }
        position()
        panel.orderFrontRegardless()
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.show(.hidden) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    /// Shows the "meeting detected" reminder above the bar for 20 s.
    func showMeetingPrompt(_ text: String) {
        promptWork?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { model.meetingPrompt = text }
        position()
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in self?.dismissMeetingPrompt() }
        promptWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func dismissMeetingPrompt() {
        promptWork?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { model.meetingPrompt = nil }
    }

    /// Bottom-center of the screen that has the mouse (Wispr: data-bar-position="bottom").
    private func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 6))
    }

    /// The panel only takes mouse events while the pointer is over the pill, so the rest of
    /// its transparent area never blocks clicks on the apps underneath.
    private func startMouseTracking() {
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let p = event.locationInWindow
            if self.hotRect.contains(p) {
                if self.model.meetingPrompt != nil && self.model.phase == .hidden {
                    self.dismissMeetingPrompt()
                    self.onMeetingPromptClick()
                } else {
                    self.onClick()
                }
            }
            return nil
        }
    }

    private func updateHover() {
        let mouse = NSEvent.mouseLocation
        let local = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        let inside = hotRect.contains(local)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if model.hovering != inside {
            withAnimation(.timingCurve(0.05, 0.6, 0.4, 0.95, duration: 0.15)) { model.hovering = inside }
        }
    }
}

// MARK: - Views

struct FlowBarView: View {
    @ObservedObject var model: OverlayModel
    @AppStorage(Prefs.hotkey) private var hotkey = "fn"

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if let tip = tooltip {
                Tooltip(text: tip.text, keytip: tip.key)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
            Pill(model: model)
                .padding(.bottom, 8)
        }
        .frame(width: 420, height: 110)
    }

    private var tooltip: (text: String, key: String?)? {
        switch model.phase {
        case .message(let text, _), .loading(let text): return (text, nil)
        case .recording where model.handsFree: return ("Clique para parar", nil)
        case .hidden where model.meetingPrompt != nil: return (model.meetingPrompt!, nil)
        case .hidden where model.hovering && model.meetingRecording:
            return ("Notetaker gravando · clique ou segure", HotkeyMonitor.Trigger(rawValue: hotkey)?.label ?? "fn")
        case .hidden where model.hovering:
            return ("Clique ou segure", HotkeyMonitor.Trigger(rawValue: hotkey)?.label ?? "fn")
        default: return nil
        }
    }
}

private struct Tooltip: View {
    let text: String
    let keytip: String?
    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            if let keytip {
                Text(keytip).fontWeight(.bold)
                Text("para ditar")
            }
        }
        .font(DS.ui(15))
        .foregroundColor(.white)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        // Hug short tips; wrap long messages to two lines inside the 420 pt panel.
        .modifier(TooltipWidth(long: text.count > 40))
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 17).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(DS.vast900, lineWidth: 1))
    }
}

private struct Pill: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        ZStack {
            switch state {
            case .meeting:
                Capsule().fill(Color.black.opacity(0.8))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                    .overlay(RecordingDot())
                    .frame(width: 40, height: 14)
            case .prompt:
                Capsule().fill(Color.black)
                    .overlay(Capsule().strokeBorder(DS.vast700, lineWidth: 1))
                    .overlay(HStack(spacing: 6) {
                        RecordingDot()
                        Text("Iniciar").font(DS.ui(13, DS.w550)).foregroundColor(.white)
                    })
                    .frame(width: 84, height: 30)
            case .resting:
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                    .frame(width: 40, height: 8)
            case .ready:
                Capsule().fill(DS.vast900)
                    .overlay(Capsule().strokeBorder(DS.vast700, lineWidth: 1))
                    .overlay(Dots(color: DS.vast300, animated: false))
                    .frame(width: 50, height: 30)
            case .recording:
                Capsule().fill(Color.black)
                    .overlay(Capsule().strokeBorder(DS.vast900, lineWidth: 1))
                    .overlay(
                        HStack(spacing: 6) {
                            Waveform(levels: model.levels)
                            if model.handsFree {
                                RoundedRectangle(cornerRadius: 2).fill(DS.vast950).frame(width: 7, height: 7)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(DS.sand50))
                            }
                        })
                    .frame(width: model.handsFree ? 102.5 : 73, height: 30)
            case .processing:
                RainbowPill()
                    .overlay(Dots(color: .white, animated: true))
                    .frame(width: 98, height: 30)
            case .error:
                Capsule().fill(Color.black)
                    .overlay(Capsule().strokeBorder(DS.destructive500, lineWidth: 1.5))
                    .overlay(Image(systemName: "exclamationmark").font(.system(size: 12, weight: .bold)).foregroundColor(DS.destructive500))
                    .frame(width: 91, height: 30)
            }
        }
        .frame(height: 30, alignment: .bottom)
        .animation(.timingCurve(0.05, 0.6, 0.4, 0.95, duration: 0.18), value: state)
    }

    private enum VisualState { case resting, ready, recording, processing, error, meeting, prompt }

    private var state: VisualState {
        switch model.phase {
        case .recording: return .recording
        case .transcribing, .loading: return .processing
        case .message(_, let isError): return isError ? .error : (model.hovering ? .ready : .resting)
        case .hidden:
            if model.meetingPrompt != nil { return .prompt }
            if model.hovering { return .ready }
            return model.meetingRecording ? .meeting : .resting
        }
    }
}

/// Pulsing red dot used for Notetaker recording.
struct RecordingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(DS.destructive500).frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(), value: on)
            .onAppear { on = true }
    }
}

/// White bars driven by the mic level (rects 2 px wide, rx 1, min height, like the status waveform).
private struct Waveform: View {
    let levels: [CGFloat]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white)
                    .frame(width: 2.5, height: max(3, levels[i] * 18))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}

private struct Dots: View {
    let color: Color
    let animated: Bool
    @State private var phase = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(color).frame(width: 4, height: 4)
                    .opacity(animated ? (phase ? 1 : 0.3) : 0.9)
                    .animation(animated ? .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2) : nil, value: phase)
            }
        }
        .onAppear { phase = true }
    }
}

/// conic-gradient(#f0d7ff, #ffbcf2, #ff6c4c, #ffa946, #7232a6) rotating behind a 1 px inset black fill.
private struct RainbowPill: View {
    @State private var angle: Double = 0
    var body: some View {
        ZStack {
            Capsule()
                .fill(AngularGradient(colors: DS.rainbow, center: .center, angle: .degrees(angle)))
            Capsule()
                .fill(Color.black)
                .padding(1.5)
        }
        .onAppear {
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { angle = 360 }
        }
    }
}

private struct TooltipWidth: ViewModifier {
    let long: Bool
    func body(content: Content) -> some View {
        if long {
            content.frame(width: 360).fixedSize(horizontal: false, vertical: true)
        } else {
            content.fixedSize()
        }
    }
}
