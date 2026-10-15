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

        requestPermissions()
        refreshPermissions()
        startHotkey()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }

        showMainWindow()
        Task { await startServer() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        capturedContext = FocusContext.capture()
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
                let outcome = await inserter.insert(result.text)
                var pasted = false
                switch outcome {
                case .pasted:
                    pasted = true
                    overlay.show(.hidden)
                case .copiedOnly(let reason):
                    overlay.show(.message("\(reason). Cole com ⌘V", isError: true), autoHideAfter: 6)
                }
                model.record(.init(text: result.text.trimmingCharacters(in: .whitespaces), raw: result.raw,
                                   appName: context?.appName, latencyMs: result.latencyMs, pasted: pasted,
                                   durationSeconds: seconds))
            } catch {
                Log.info("dictation failed: \(error.localizedDescription)")
                model.serverState = .offline("Sem resposta do servidor")
                overlay.show(.message("Erro: \(error.localizedDescription)", isError: true), autoHideAfter: 6)
            }
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
