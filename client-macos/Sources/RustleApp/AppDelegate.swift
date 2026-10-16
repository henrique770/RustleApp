import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI

/// Wires the pipeline together:
/// hotkey down -> record mic -> hotkey up -> send WAV + focus context to rustle-server
/// -> receive cleaned text -> paste into the focused app -> save to history.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var window: NSWindow?
    private var statusItem: NSStatusItem!
    private let overlay = OverlayPanel()
    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private let client = TranscriptionClient(baseURL: Config.serverURL)
    private lazy var server = ServerManager(baseURL: Config.serverURL, settingsPath: AppModel.settingsURL.path)
    private var hotkey: HotkeyMonitor?
    private var permissionTimer: Timer?
    private var capturedContext: FocusContext.Snapshot?
    private var isRecording = false
    private let notetaker = NotetakerClient(baseURL: Config.serverURL)
    private lazy var meetingRecorder = MeetingRecorder(client: notetaker)
    private let meetingDetector = MeetingDetector()
    private var meetingClock: Timer?
    private var notetakerMenuItem: NSMenuItem?
    private lazy var scratchpad = ScratchpadWindowController(model: model, client: TransformClient(baseURL: Config.serverURL))
    private var scratchpadShortcut: GlobalShortcut?
    /// True when the dictation started while the Scratchpad had the keyboard: the text goes into it.
    private var dictatingIntoScratchpad = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("RustleApp started (hotkey=\(Config.trigger.rawValue), server=\(Config.serverURL), bundle=\(Bundle.main.bundlePath))")
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
        buildStatusItem()
        wireActions()

        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.overlay.model.push(level: level) }
        }
        // Clicking the Flow bar starts / stops hands-free dictation (no key held).
        overlay.onClick = { [weak self] in
            guard let self else { return }
            if self.isRecording { self.stopDictation() } else { self.startDictation(handsFree: true) }
        }

        // On first run the questionnaire asks for each permission at its own step; a microphone
        // grant that already exists is still read now (no prompt is shown for a decided status).
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.info("microphone status at launch: \(micStatus.rawValue)")
        if UserDefaults.standard.bool(forKey: Prefs.onboardingDone) {
            requestPermissions()
        } else if micStatus != .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in Log.info("microphone access: \(granted)") }
        }
        refreshPermissions()
        startHotkey()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }

        overlay.onMeetingPromptClick = { [weak self] in
            guard let self else { return }
            if let id = self.startMeeting(app: self.model.detectedMeetingApp) { self.openMeeting(id) }
        }
        meetingDetector.shouldCheck = { [weak self] in self?.model.activeMeetingID == nil }
        meetingDetector.onMeetingStarted = { [weak self] app in
            guard let self, self.model.activeMeetingID == nil else { return }
            self.model.detectedMeetingApp = app
            self.overlay.showMeetingPrompt("Reunião detectada no \(app) · clique para iniciar o Notetaker")
        }
        meetingDetector.onMeetingEnded = { [weak self] in
            self?.model.detectedMeetingApp = nil
            self?.overlay.dismissMeetingPrompt()
        }
        meetingDetector.start()

        scratchpadShortcut = GlobalShortcut { [weak self] in self?.scratchpad.toggle() }
        scratchpad.controller.onSend = { [weak self] text, app in self?.send(text, to: app) }

        showMainWindow()
        Task { await startServer() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let id = model.activeMeetingID {
            model.updateMeeting(id) { $0.status = .ready; $0.ended = Date() }
        }
        server.stop()
    }

    // MARK: - Window & menus

    @objc private func showMainWindow() {
        if window == nil {
            // Like Wispr's hub: frameless look, hidden title bar, traffic lights over the sidebar.
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "RustleApp"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(red: 0xF5 / 255.0, green: 0xF4 / 255.0, blue: 0xF0 / 255.0, alpha: 1)
            w.contentViewController = NSHostingController(rootView: MainView(model: model))
            w.setContentSize(NSSize(width: 1100, height: 720))
            w.minSize = NSSize(width: 900, height: 600)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("RustleAppHub")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A regular app needs an Edit menu, or Cmd+C / Cmd+V do nothing in its own text fields
    /// (which would also break dictating into the Notes view).
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Sobre o RustleApp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ocultar RustleApp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Sair do RustleApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Editar")
        edit.addItem(withTitle: "Desfazer", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Refazer", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar Tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Janela")
        windowMenu.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Fechar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("waveform", tip: "RustleApp")
        let menu = NSMenu()
        menu.addItem(item("Abrir RustleApp", #selector(showMainWindow)))
        menu.addItem(item("Abrir Scratchpad (\(GlobalShortcut.label))", #selector(openScratchpadFromMenu)))
        let notetakerItem = item("Iniciar Notetaker", #selector(toggleNotetakerFromMenu))
        menu.addItem(notetakerItem)
        notetakerMenuItem = notetakerItem
        menu.addItem(item("Testar colagem (em 3 s)", #selector(testPasteFromMenu)))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sair do RustleApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func setIcon(_ symbol: String, tip: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        statusItem.button?.toolTip = tip
    }

    private func wireActions() {
        model.testPaste = { [weak self] in self?.testPaste() }
        model.repairPermissions = { [weak self] in self?.repairPermissions() }
        model.relaunch = { [weak self] in self?.relaunch() }
        model.restartServer = { [weak self] in
            guard let self else { return }
            Task { await self.restartServer() }
        }
        model.hotkeyChanged = { [weak self] in self?.startHotkey() }
        model.startMeeting = { [weak self] app in self?.startMeeting(app: app) }
        model.stopMeeting = { [weak self] in self?.stopMeeting() }
        model.generateNotes = { [weak self] id in self?.generateNotes(for: id) }
        model.askMeeting = { [weak self] id, question in self?.ask(question, about: id) }
        model.openScratchpad = { [weak self] id in self?.scratchpad.show(note: id) }
    }

    private func openMeeting(_ id: UUID) {
        model.openMeetingID = id
        model.pageRequest = .notetaker
        showMainWindow()
    }

    // MARK: - Server

    private func startServer() async {
        if await server.isOutdated() {
            Log.info("server is outdated; restarting it")
            await restartServer()
            return
        }
        if await server.isHealthy() {
            model.serverState = .online
            return
        }
        model.serverState = .starting
        overlay.show(.loading("Iniciando servidor…"))
        if let error = await server.ensureRunning() {
            Log.info("server not ready: \(error)")
            model.serverState = .offline(error)
            overlay.show(.message(error, isError: true), autoHideAfter: 8)
        } else {
            Log.info("server ready")
            model.serverState = .online
            overlay.show(.message("Pronto: segure \(Config.trigger.label) para ditar", isError: false), autoHideAfter: 3)
        }
    }

    private func restartServer() async {
        model.serverState = .starting
        Log.info("restarting server")
        if let error = await server.restart() {
            model.serverState = .offline(error)
        } else {
            model.serverState = .online
        }
    }

    // MARK: - Hotkey & permissions

    private func startHotkey() {
        hotkey?.stop()
        let trigger = Config.trigger
        let monitor = HotkeyMonitor(trigger: trigger) { [weak self] pressed in
            DispatchQueue.main.async { self?.hotkeyChanged(pressed: pressed) }
        }
        if monitor.start() {
            Log.info("hotkey \(trigger.rawValue) listening (accessibility: \(AXIsProcessTrusted()), input monitoring: \(CGPreflightListenEventAccess()))")
        } else {
            Log.info("event tap creation failed")
        }
        hotkey = monitor
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in Log.info("microphone access: \(granted)") }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
    }

    private func refreshPermissions() {
        let now = AppModel.Permissions(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            inputMonitoring: CGPreflightListenEventAccess(),
            accessibility: AXIsProcessTrusted()
        )
        guard now != model.permissions else { return }
        let gained = (now.inputMonitoring && !model.permissions.inputMonitoring)
            || (now.accessibility && !model.permissions.accessibility)
        model.permissions = now
        Log.info("permissions: mic=\(now.microphone) input=\(now.inputMonitoring) ax=\(now.accessibility)")
        // Hotkey sources created before a grant only see this app's own events; recreate them.
        if gained { startHotkey() }
    }

    /// Clears stale grants (left by earlier builds with a different signature) and asks again.
    private func repairPermissions() {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.rustleapp.client"
        for service in ["Accessibility", "ListenEvent"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", service, bundleID]
            try? p.run()
            p.waitUntilExit()
            Log.info("tccutil reset \(service) \(bundleID): exit \(p.terminationStatus)")
        }
        requestPermissions()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - Dictation pipeline

    /// Hold-to-talk; a press while hands-free dictation is running stops it instead.
    private func hotkeyChanged(pressed: Bool) {
        if pressed {
            if isRecording && overlay.model.handsFree { stopDictation() } else { startDictation(handsFree: false) }
        } else if isRecording && !overlay.model.handsFree {
            stopDictation()
        }
    }

    private func startDictation(handsFree: Bool) {
        guard !isRecording else { return }
        // Capture context before anything changes focus (Wispr does this via its AX helper).
        dictatingIntoScratchpad = scratchpad.isKey
        capturedContext = dictatingIntoScratchpad ? nil : FocusContext.capture()
        do {
            try recorder.start()
            isRecording = true
            setIcon("mic.fill", tip: "Gravando…")
            overlay.show(.recording)
            overlay.model.handsFree = handsFree
            Log.info("recording started in \(capturedContext?.bundleId ?? "?")")
        } catch {
            Log.info("mic start failed: \(error)")
            overlay.show(.message("Microfone: \(error.localizedDescription)", isError: true), autoHideAfter: 5)
        }
    }

    private func stopDictation() {
        guard isRecording else { return }
        isRecording = false
        let wav = recorder.stop()
        let seconds = recorder.lastDurationSeconds
        Log.info(String(format: "recording stopped: %.2fs", seconds))

        guard seconds >= Config.minimumSeconds else {
            setIcon("waveform", tip: "RustleApp")
            overlay.show(.hidden)
            return
        }
        setIcon("ellipsis.circle", tip: "Transcrevendo…")
        overlay.show(.transcribing)
        let context = capturedContext
        let intoScratchpad = dictatingIntoScratchpad

        Task {
            defer { setIcon("waveform", tip: "RustleApp") }
            if model.serverState != .online {
                if let error = await server.ensureRunning(timeout: 30) {
                    overlay.show(.message(error, isError: true), autoHideAfter: 6)
                    return
                }
                model.serverState = .online
            }
            do {
                let result = try await client.dictate(wav: wav, context: context, language: Config.language)
                Log.info("transcribed in \(result.latencyMs)ms via \(result.formatter): \(result.text.count) chars")
                guard !result.text.isEmpty else {
                    overlay.show(.message("Nada foi reconhecido", isError: true), autoHideAfter: 2.5)
                    return
                }
                var pasted = false
                if intoScratchpad && scratchpad.isVisible {
                    scratchpad.insertDictation(result.text.trimmingCharacters(in: .whitespaces))
                    pasted = true
                    overlay.show(.hidden)
                } else {
                    switch await inserter.insert(result.text) {
                    case .pasted:
                        pasted = true
                        overlay.show(.hidden)
                    case .copiedOnly(let reason):
                        // Like Wispr ("paste_failure"): the text opens in the Scratchpad instead of being lost.
                        Log.info("paste failed (\(reason)); opening the Scratchpad")
                        overlay.show(.message("\(reason). Abrimos o texto no Scratchpad", isError: true), autoHideAfter: 4)
                        scratchpad.show(text: result.text.trimmingCharacters(in: .whitespaces))
                    }
                }
                model.record(.init(text: result.text.trimmingCharacters(in: .whitespaces), raw: result.raw,
                                   appName: intoScratchpad ? "Scratchpad" : context?.appName, latencyMs: result.latencyMs,
                                   pasted: pasted, durationSeconds: seconds))
            } catch {
                Log.info("dictation failed: \(error.localizedDescription)")
                model.serverState = .offline("Sem resposta do servidor")
                overlay.show(.message("Erro: \(error.localizedDescription)", isError: true), autoHideAfter: 6)
            }
        }
    }

    // MARK: - Scratchpad

    @objc private func openScratchpadFromMenu() { scratchpad.show() }

    /// "Enviar no <app>": hide the Scratchpad, bring the app back and paste the note there.
    private func send(_ text: String, to app: NSRunningApplication) {
        scratchpad.hide()
        app.activate()
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if case .copiedOnly(let reason) = await inserter.insert(text) {
                overlay.show(.message("\(reason). Cole com ⌘V", isError: true), autoHideAfter: 5)
            }
        }
    }

    // MARK: - Notetaker

    @objc private func toggleNotetakerFromMenu() {
        if model.activeMeetingID != nil {
            stopMeeting()
        } else if let id = startMeeting(app: model.detectedMeetingApp) {
            openMeeting(id)
        }
    }

    /// Wispr: "New note — opens notepad and starts Notetaker". Records mic + system audio.
    @discardableResult
    private func startMeeting(app: String?) -> UUID? {
        if let active = model.activeMeetingID { return active }
        var meeting = Meeting(appName: app)
        if !model.displayFirstName.isEmpty { meeting.setName(model.displayFirstName, for: .you) }
        model.meetings.insert(meeting, at: 0)
        let id = meeting.id
        meetingRecorder.onSegments = { [weak self] segments in self?.model.appendSegments(segments, to: id) }
        meetingRecorder.onCorrected = { [weak self] texts in self?.model.correctSegments(texts, in: id) }
        meetingRecorder.recentTranscript = { [weak self] in
            guard let m = self?.model.meeting(id) else { return "" }
            return m.orderedSegments.suffix(12).map { "\(m.name(of: $0.speaker)): \($0.text)" }.joined(separator: "\n")
        }
        meetingRecorder.onLevels = { [weak self] mic, system in self?.model.meetingLevels.push(mic: mic, system: system) }
        do {
            try meetingRecorder.start(language: Config.language)
        } catch {
            model.meetings.removeAll { $0.id == id }
            Log.info("meeting recording failed to start: \(error)")
            overlay.show(.message("Notetaker: \(error.localizedDescription)", isError: true), autoHideAfter: 6)
            return nil
        }
        model.activeMeetingID = id
        model.systemAudioError = meetingRecorder.systemAudioError
        model.detectedMeetingApp = nil
        model.meetingLevels.elapsed = 0
        overlay.dismissMeetingPrompt()
        overlay.model.meetingRecording = true
        notetakerMenuItem?.title = "Parar Notetaker"
        setIcon("record.circle", tip: "Notetaker gravando")
        meetingClock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let m = self.model.meeting(id) else { return }
                self.model.meetingLevels.elapsed = Date().timeIntervalSince(m.started)
            }
        }
        if model.serverState != .online {
            Task { if await server.ensureRunning(timeout: 60) == nil { model.serverState = .online } }
        }
        return id
    }

    private func stopMeeting() {
        guard let id = model.activeMeetingID else { return }
        model.activeMeetingID = nil
        meetingClock?.invalidate()
        meetingClock = nil
        model.updateMeeting(id) { $0.ended = Date(); $0.status = .processing }
        overlay.model.meetingRecording = false
        notetakerMenuItem?.title = "Iniciar Notetaker"
        setIcon("waveform", tip: "RustleApp")
        Task {
            await meetingRecorder.stop()
            generateNotes(for: id)
        }
    }

    /// Post-meeting "Enhanced Summary" and "Action Items" (Claude when a key is set, else local).
    private func generateNotes(for id: UUID) {
        guard let meeting = model.meeting(id), !model.busyMeetingIDs.contains(id) else { return }
        model.busyMeetingIDs.insert(id)
        model.updateMeeting(id) { $0.status = .processing }
        Task {
            defer {
                model.busyMeetingIDs.remove(id)
                model.updateMeeting(id) { $0.status = .ready }
            }
            do {
                let notes = try await notetaker.notes(for: meeting, language: Config.language)
                model.updateMeeting(id) { m in
                    m.summary = notes.summary
                    // Keep items the user already checked off or added by hand.
                    let kept = m.actionItems.filter { $0.done }
                    m.actionItems = kept + notes.action_items.map { Meeting.ActionItem(text: $0.text, owner: $0.owner) }
                    m.summaryEngine = notes.engine
                    if m.title.trimmingCharacters(in: .whitespaces).isEmpty, !notes.title.isEmpty { m.title = notes.title }
                    if let other = notes.other_speaker_name?.trimmingCharacters(in: .whitespaces), !other.isEmpty,
                       m.name(of: .them) == Meeting.Speaker.them.label {
                        m.suggestedOtherName = other
                    }
                }
                Log.info("meeting notes via \(notes.engine): \(notes.summary.count) sections, \(notes.action_items.count) actions")
            } catch {
                Log.info("meeting notes failed: \(error.localizedDescription)")
                overlay.show(.message("Resumo: \(error.localizedDescription)", isError: true), autoHideAfter: 6)
            }
        }
    }

    private func ask(_ question: String, about id: UUID) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let meeting = model.meeting(id) else { return }
        model.updateMeeting(id) { $0.chat.append(.init(fromUser: true, text: q)) }
        model.busyMeetingIDs.insert(id)
        Task {
            defer { model.busyMeetingIDs.remove(id) }
            let answer: String
            do { answer = try await notetaker.ask(q, about: meeting) } catch { answer = "Algo deu errado: \(error.localizedDescription)" }
            model.updateMeeting(id) { $0.chat.append(.init(fromUser: false, text: answer)) }
        }
    }

    // MARK: - Diagnostics

    @objc private func testPasteFromMenu() { testPaste() }

    /// Pastes a fixed string after 3 s, so the user can click into a text field first.
    /// This isolates the paste step from the mic and server.
    private func testPaste() {
        overlay.show(.message("Clique num campo de texto…", isError: false))
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            switch await inserter.insert("Teste do RustleApp ✓") {
            case .pasted: overlay.show(.message("Colagem funcionou", isError: false), autoHideAfter: 2.5)
            case .copiedOnly(let reason): overlay.show(.message(reason, isError: true), autoHideAfter: 6)
            }
        }
    }
}

enum Config {
    static var serverURL: URL {
        URL(string: ProcessInfo.processInfo.environment["RUSTLE_SERVER"]
            ?? UserDefaults.standard.string(forKey: "serverURL")
            ?? "http://127.0.0.1:8765")!
    }
    static var trigger: HotkeyMonitor.Trigger {
        let raw = ProcessInfo.processInfo.environment["RUSTLE_HOTKEY"]
            ?? UserDefaults.standard.string(forKey: Prefs.hotkey) ?? "fn"
        return HotkeyMonitor.Trigger(rawValue: raw) ?? .fn
    }
    static var language: String {
        UserDefaults.standard.string(forKey: Prefs.language) ?? "pt"
    }
    static let minimumSeconds = 0.3
}
