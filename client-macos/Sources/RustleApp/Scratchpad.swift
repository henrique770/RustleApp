import AppKit
import Carbon
import SwiftUI

/// Scratchpad: Wispr Flow's floating note window, rebuilt from its main and renderer bundles.
///
/// What Wispr does (recovered with REA from the shipped app):
///  - A frameless, transparent panel ("Scratchpad"), 500x420 by default, min 300x200, expanded
///    920x660, opened next to the cursor and clamped to the screen's work area, visible on all
///    Spaces and over full-screen apps.
///  - Tabs, each bound to a note; a collapsible notes sidebar (search, pin, delete); a rich text
///    editor you can dictate into ("fn to dictate"); Copy; version history (Created / Dictated /
///    Typed edits / Transform); a formatting bar and a "Transforms" bar with AI suggestion pills
///    (POST /api/v1/transform/suggestions {content, count: 6}) plus a free-form request.
///  - It opens from a shortcut, from the status bubble, and when a dictation cannot be pasted
///    ("paste_failure"), so the text is never lost.
/// This file holds the state and the window; ScratchpadView.swift draws it.

// MARK: - Server client

struct TransformClient {
    struct Suggestion: Decodable, Identifiable, Hashable {
        let id: String
        let label: String
        let prompt: String
    }

    let baseURL: URL

    func suggestions(for content: String, count: Int = 6) async throws -> [Suggestion] {
        struct Req: Encodable { let content: String; let count: Int }
        struct Res: Decodable { let suggestions: [Suggestion] }
        let res: Res = try await post("v1/transform/suggestions", Req(content: content, count: count), timeout: 25)
        return res.suggestions
    }

    func apply(_ prompt: String, suggestionID: String?, content: String, selection: String?) async throws -> String {
        struct Req: Encodable { let content: String; let prompt: String; let suggestion_id: String?; let selection: String? }
        struct Res: Decodable { let text: String?; let error: String? }
        let res: Res = try await post("v1/transform", Req(content: content, prompt: prompt, suggestion_id: suggestionID,
                                                           selection: selection), timeout: 120)
        guard let text = res.text, !text.isEmpty else {
            throw NSError(domain: "RustleApp", code: 4, userInfo: [NSLocalizedDescriptionKey: res.error ?? "A transformação falhou. Tente de novo."])
        }
        return text
    }

    private func post<B: Encodable, R: Decodable>(_ path: String, _ body: B, timeout: TimeInterval) async throws -> R {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "RustleApp", code: 3, userInfo: [NSLocalizedDescriptionKey: "Servidor indisponível"])
        }
        return try JSONDecoder().decode(R.self, from: data)
    }
}

// MARK: - State

@MainActor
final class ScratchpadController: ObservableObject {
    struct Tab: Identifiable, Hashable {
        let id = UUID()
        var noteID: UUID
    }
    enum BottomBar { case none, transforms, formatting }
    enum OpenBehavior: String { case resume, newTab = "new_tab", lastPinned = "last_pinned" }
    struct Toast: Equatable { var message: String; var isError = false; var id = UUID() }

    // Window defaults from Wispr's scratchpad config (default/min/expanded sizes).
    static let defaultSize = NSSize(width: 500, height: 420)
    static let minSize = NSSize(width: 300, height: 200)
    static let expandedSize = NSSize(width: 920, height: 660)

    let model: AppModel
    private let client: TransformClient

    @Published var tabs: [Tab] = []
    @Published var activeTabID: UUID?
    @Published var sidebarOpen = false
    @Published var expanded = false
    @Published var bottomBar: BottomBar = .none
    @Published var suggestions: [TransformClient.Suggestion]?
    @Published var isTransforming = false
    @Published var toast: Toast?
    @Published var versionMenuOpen = false
    @Published var search = ""
    /// The app that was in front when the Scratchpad opened ("Enviar no Slack").
    @Published var targetApp: NSRunningApplication?

    /// Set by the window: hide / resize / send.
    var onClose: () -> Void = {}
    var onToggleExpanded: (Bool) -> Void = { _ in }
    var onSend: (String, NSRunningApplication) -> Void = { _, _ in }

    /// Text views by note, so dictation and formatting reach the visible editor.
    private var editors: [UUID: NSTextView] = [:]
    private var typedTimer: Timer?
    private var suggestionsFor: String?

    init(model: AppModel, client: TransformClient) {
        self.model = model
        self.client = client
    }

    var activeTab: Tab? { tabs.first { $0.id == activeTabID } }
    var activeNote: AppModel.Note? { activeTab.flatMap { model.note($0.noteID) } }
    var activeEditor: NSTextView? { activeTab.flatMap { editors[$0.noteID] } }

    // MARK: Opening

    /// Applies the "Scratchpad open behavior" setting when the window is shown.
    func prepareForOpen(with note: UUID?) {
        if let note {
            open(note: note)
            return
        }
        let behavior = OpenBehavior(rawValue: UserDefaults.standard.string(forKey: Prefs.scratchpadOpenBehavior) ?? "") ?? .resume
        switch behavior {
        case .resume:
            if tabs.isEmpty {
                if let last = UserDefaults.standard.string(forKey: Prefs.scratchpadLastNote).flatMap(UUID.init),
                   model.note(last) != nil {
                    open(note: last)
                } else {
                    newTab()
                }
            }
        case .newTab:
            if activeNote.map({ !$0.isEmpty }) ?? true { newTab() }
        case .lastPinned:
            if let pinned = model.notes.filter(\.pinned).max(by: { $0.updated < $1.updated }) {
                open(note: pinned.id)
            } else if tabs.isEmpty {
                newTab()
            }
        }
    }

    /// Opens a new tab holding `text` (dictation that could not be pasted).
    func openWithText(_ text: String) {
        let note = AppModel.Note(body: text)
        model.notes.insert(note, at: 0)
        model.addVersion(note.id, source: .created)
        addTab(for: note.id)
    }

    // MARK: Tabs

    func newTab() {
        // Reuse an empty active tab instead of stacking blank ones.
        if let note = activeNote, note.isEmpty { focusEditor(); return }
        let note = AppModel.Note()
        model.notes.insert(note, at: 0)
        addTab(for: note.id)
    }

    func open(note id: UUID) {
        if let tab = tabs.first(where: { $0.noteID == id }) {
            activate(tab.id)
        } else if let tab = activeTab, model.note(tab.noteID)?.isEmpty == true {
            // Replace a blank tab, like opening a note from the sidebar in Wispr.
            discardIfEmpty(tab.noteID)
            if let i = tabs.firstIndex(where: { $0.id == tab.id }) { tabs[i].noteID = id }
            activate(tab.id)
        } else {
            addTab(for: id)
        }
    }

    func activate(_ tabID: UUID) {
        flushTypedVersion()
        activeTabID = tabID
        versionMenuOpen = false
        suggestions = nil
        if let note = activeTab?.noteID { UserDefaults.standard.set(note.uuidString, forKey: Prefs.scratchpadLastNote) }
        if bottomBar == .transforms { loadSuggestions() }
        focusEditor()
    }

    func close(tab tabID: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        flushTypedVersion()
        let tab = tabs.remove(at: i)
        discardIfEmpty(tab.noteID)
        editors[tab.noteID] = nil
        if tabs.isEmpty {
            activeTabID = nil
            onClose()
        } else if activeTabID == tabID {
            activate(tabs[min(i, tabs.count - 1)].id)
        }
    }

    func moveTab(_ id: UUID, by offset: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(tabs.count - 1, i + offset))
        guard i != j else { return }
        tabs.swapAt(i, j)
    }

    func selectTab(offset: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == activeTabID }), !tabs.isEmpty else { return }
        activate(tabs[(i + offset + tabs.count) % tabs.count].id)
    }

    func rename(tab tabID: UUID, to title: String) {
        guard let note = tabs.first(where: { $0.id == tabID })?.noteID else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        model.updateNote(note) { $0.customTitle = trimmed.isEmpty ? nil : trimmed }
    }

    private func addTab(for noteID: UUID) {
        let tab = Tab(noteID: noteID)
        tabs.append(tab)
        activate(tab.id)
    }

    /// Called when the window hides: blank notes are not kept.
    func windowWillHide() {
        flushTypedVersion()
        versionMenuOpen = false
        for tab in tabs where tab.id != activeTabID { discardIfEmpty(tab.noteID) }
        tabs.removeAll { model.note($0.noteID) == nil }
    }

    private func discardIfEmpty(_ noteID: UUID) {
        if model.note(noteID)?.isEmpty == true { model.notes.removeAll { $0.id == noteID } }
    }

    // MARK: Notes

    var visibleNotes: [AppModel.Note] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let openNotes = Set(tabs.map(\.noteID))
        let notes = model.notes.filter { !$0.isEmpty || openNotes.contains($0.id) }
            .filter { q.isEmpty || $0.body.localizedCaseInsensitiveContains(q) || $0.title.localizedCaseInsensitiveContains(q) }
        return notes.sorted { ($0.pinned ? 1 : 0, $0.updated) > ($1.pinned ? 1 : 0, $1.updated) }
    }

    func togglePin(_ id: UUID) {
        model.updateNote(id) { $0.pinned.toggle() }
    }

    func delete(note id: UUID) {
        if let tab = tabs.first(where: { $0.noteID == id }) {
            model.notes.removeAll { $0.id == id }
            close(tab: tab.id)
        } else {
            model.notes.removeAll { $0.id == id }
        }
        show(Toast(message: "Nota apagada"))
    }

    // MARK: Editing

    func register(_ view: NSTextView, for noteID: UUID) { editors[noteID] = view }

    /// Every keystroke updates the note; a "Typed edits" version is recorded after a pause.
    func textChanged(_ text: String, note noteID: UUID) {
        guard model.note(noteID)?.body != text else { return }
        model.updateNote(noteID) { $0.body = text; $0.updated = Date() }
        typedTimer?.invalidate()
        typedTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.addVersion(noteID, source: .typed) }
        }
    }

    private func flushTypedVersion() {
        guard let timer = typedTimer, timer.isValid else { return }
        timer.fire()
        typedTimer = nil
    }

    func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.activeEditor else { return }
            view.window?.makeFirstResponder(view)
        }
    }

    /// Dictation lands at the cursor of the visible editor, like Wispr's notifyScratchpadDictation.
    func insertDictation(_ text: String) {
        guard let tab = activeTab else { openWithText(text); return }
        flushTypedVersion()
        if let view = editors[tab.noteID] {
            let range = view.selectedRange()
            let ns = view.string as NSString
            var insert = text
            if range.location > 0, range.location <= ns.length {
                let prev = ns.substring(with: NSRange(location: range.location - 1, length: 1))
                if !prev.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { insert = " " + insert }
            }
            if view.shouldChangeText(in: range, replacementString: insert) {
                view.replaceCharacters(in: range, with: insert)
                view.didChangeText()
            }
        } else {
            model.updateNote(tab.noteID) { $0.body += ($0.body.isEmpty ? "" : " ") + text; $0.updated = Date() }
        }
        typedTimer?.invalidate()
        model.addVersion(tab.noteID, source: .dictated)
    }

    /// Replaces the whole note (transform, version restore) through the text view, so undo works.
    private func replaceBody(of noteID: UUID, with text: String, range: NSRange? = nil) {
        if let view = editors[noteID] {
            let target = range ?? NSRange(location: 0, length: (view.string as NSString).length)
            if view.shouldChangeText(in: target, replacementString: text) {
                view.replaceCharacters(in: target, with: text)
                view.didChangeText()
            }
        } else {
            model.updateNote(noteID) { $0.body = text; $0.updated = Date() }
        }
        typedTimer?.invalidate()
    }

    func restore(_ version: AppModel.NoteVersion) {
        guard let note = activeTab?.noteID else { return }
        versionMenuOpen = false
        replaceBody(of: note, with: version.body)
        show(Toast(message: "Versão restaurada"))
    }

    // MARK: Copy / send

    func copy() {
        guard let note = activeNote, !note.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.body, forType: .string)
        show(Toast(message: "Copiado para a área de transferência"))
    }

    func send() {
        guard let note = activeNote, !note.isEmpty, let app = targetApp else { return }
        flushTypedVersion()
        onSend(note.body, app)
    }

    func show(_ toast: Toast) {
        self.toast = toast
        let id = toast.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.toast?.id == id { self?.toast = nil }
        }
    }

    // MARK: Transforms

    func toggle(_ bar: BottomBar) {
        bottomBar = bottomBar == bar ? .none : bar
        if bottomBar == .transforms { loadSuggestions() }
    }

    func loadSuggestions(force: Bool = false) {
        let content = activeNote?.body ?? ""
        guard force || suggestions == nil || suggestionsFor != content else { return }
        suggestions = nil
        suggestionsFor = content
        Task {
            let result = (try? await client.suggestions(for: content)) ?? []
            if suggestionsFor == content { suggestions = result }
        }
    }

    /// Applies a pill or a typed request to the selection, or to the whole note.
    func transform(_ prompt: String, suggestionID: String? = nil) {
        guard let noteID = activeTab?.noteID, let note = model.note(noteID), !isTransforming else { return }
        guard !note.isEmpty else { show(Toast(message: "Escreva ou dite algo primeiro", isError: true)); return }
        flushTypedVersion()
        if note.versions.last?.body != note.body { model.addVersion(noteID, source: .typed) }
        var selection: String?
        var range: NSRange?
        if let view = editors[noteID], view.selectedRange().length > 0 {
            range = view.selectedRange()
            selection = (view.string as NSString).substring(with: view.selectedRange())
        }
        isTransforming = true
        Task {
            defer { isTransforming = false }
            do {
                let text = try await client.apply(prompt, suggestionID: suggestionID, content: note.body, selection: selection)
                guard model.note(noteID) != nil else { return }
                replaceBody(of: noteID, with: text, range: range)
                model.addVersion(noteID, source: suggestionID == nil ? .customTransform : .transform)
                loadSuggestions(force: true)
            } catch {
                show(Toast(message: error.localizedDescription, isError: true))
            }
        }
    }

    // MARK: Formatting (Markdown in plain text)

    enum Format { case bold, italic, code, link, bullet, numbered, checklist, quote, heading }

    func apply(_ format: Format) {
        guard let view = activeEditor else { return }
        let ns = view.string as NSString
        let sel = view.selectedRange()
        switch format {
        case .bold: wrap(view, sel, "**", "**")
        case .italic: wrap(view, sel, "_", "_")
        case .code: wrap(view, sel, "`", "`")
        case .link:
            let text = sel.length > 0 ? ns.substring(with: sel) : "link"
            replace(view, sel, "[\(text)](https://)")
        case .bullet: prefixLines(view, "- ")
        case .numbered: prefixLines(view, nil)
        case .checklist: prefixLines(view, "- [ ] ")
        case .quote: prefixLines(view, "> ")
        case .heading: prefixLines(view, "# ")
        }
        view.window?.makeFirstResponder(view)
    }

    private func wrap(_ view: NSTextView, _ sel: NSRange, _ open: String, _ close: String) {
        let text = (view.string as NSString).substring(with: sel)
        replace(view, sel, open + text + close)
        if sel.length == 0 { view.setSelectedRange(NSRange(location: sel.location + (open as NSString).length, length: 0)) }
    }

    private func replace(_ view: NSTextView, _ range: NSRange, _ text: String) {
        if view.shouldChangeText(in: range, replacementString: text) {
            view.replaceCharacters(in: range, with: text)
            view.didChangeText()
        }
    }

    /// Toggles a line prefix on every selected line; nil numbers the lines.
    private func prefixLines(_ view: NSTextView, _ prefix: String?) {
        let ns = view.string as NSString
        let lineRange = ns.lineRange(for: view.selectedRange())
        let block = ns.substring(with: lineRange)
        let hasNewline = block.hasSuffix("\n")
        var lines = (hasNewline ? String(block.dropLast()) : block).components(separatedBy: "\n")
        let pattern = #"^(- \[[ x]\] |- |\d+\. |> |# )"#
        let allHave = lines.allSatisfy { line in
            if let prefix { return line.hasPrefix(prefix) }
            return line.range(of: #"^\d+\. "#, options: .regularExpression) != nil
        }
        lines = lines.enumerated().map { i, line in
            let bare = line.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            if allHave { return bare }
            return (prefix ?? "\(i + 1). ") + bare
        }
        let result = lines.joined(separator: "\n") + (hasNewline ? "\n" : "")
        replace(view, lineRange, result)
        view.setSelectedRange(NSRange(location: lineRange.location + (result as NSString).length - (hasNewline ? 1 : 0), length: 0))
    }
}

// MARK: - Window

/// A non-activating panel (Wispr creates its window with Electron's type "panel"): it takes the
/// keyboard without bringing RustleApp forward, so the app you were in stays the active one, which
/// is also what "Enviar no <app>" pastes into. Borderless panels need canBecomeKey overridden.
final class ScratchpadPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class ScratchpadWindowController {
    let controller: ScratchpadController
    private var panel: ScratchpadPanel?
    private var keyMonitor: Any?
    private var collapsedFrame: NSRect?

    init(model: AppModel, client: TransformClient) {
        controller = ScratchpadController(model: model, client: client)
        controller.onClose = { [weak self] in self?.hide() }
        controller.onToggleExpanded = { [weak self] in self?.setExpanded($0) }
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var isKey: Bool { panel?.isKeyWindow ?? false }

    /// Shows the window next to the cursor (or over `anchor`), applying the open behavior.
    func show(note: UUID? = nil, text: String? = nil, anchor: NSRect? = nil) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier, front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            controller.targetApp = front
        }
        let panel = self.panel ?? makePanel()
        if let text {
            controller.openWithText(text)
        } else {
            controller.prepareForOpen(with: note)
        }
        if !panel.isVisible {
            panel.setFrameOrigin(origin(for: panel.frame.size, anchor: anchor))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        controller.focusEditor()
        Log.info("scratchpad shown (key=\(panel.isKeyWindow), app active=\(NSApp.isActive), target=\(controller.targetApp?.localizedName ?? "-"))")
        installKeyMonitor()
    }

    /// Shortcut: open, focus it if it is open behind something, close it if it has the keyboard.
    func toggle() {
        if isKey { hide() } else { show() }
    }

    func hide() {
        controller.windowWillHide()
        panel?.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func insertDictation(_ text: String) { controller.insertDictation(text) }

    private func makePanel() -> ScratchpadPanel {
        let panel = ScratchpadPanel(contentRect: NSRect(origin: .zero, size: ScratchpadController.defaultSize),
                                    styleMask: [.borderless, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.title = "Scratchpad"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.minSize = ScratchpadController.minSize
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ScratchpadView(controller: controller, model: controller.model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 12
        host.layer?.masksToBounds = true
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Wispr: open at the cursor, clamped so the whole window fits the display's work area.
    private func origin(for size: NSSize, anchor: NSRect?) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin: NSPoint
        if let anchor {
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 8)
        } else {
            origin = NSPoint(x: mouse.x, y: mouse.y - size.height)
        }
        origin.x = max(area.minX, min(origin.x, area.maxX - size.width))
        origin.y = max(area.minY, min(origin.y, area.maxY - size.height))
        return origin
    }

    private func setExpanded(_ expanded: Bool) {
        guard let panel else { return }
        var frame = panel.frame
        if expanded {
            collapsedFrame = frame
            let size = ScratchpadController.expandedSize
            frame = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
            if let area = panel.screen?.visibleFrame {
                frame.origin.x = max(area.minX, min(frame.origin.x, area.maxX - frame.width))
                frame.origin.y = max(area.minY, min(frame.origin.y, area.maxY - frame.height))
            }
        } else {
            frame = collapsedFrame ?? NSRect(origin: frame.origin, size: ScratchpadController.defaultSize)
        }
        panel.setFrame(frame, display: true, animate: true)
    }

    /// Window shortcuts: ⌘T new tab, ⌘W close tab, ⌃Tab / ⌘⇧] next tab, ⌘B/⌘I formatting, Esc closes.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            let c = self.controller
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if event.keyCode == 53 {   // Esc
                if c.versionMenuOpen { c.versionMenuOpen = false } else if c.bottomBar != .none { c.bottomBar = .none } else { self.hide() }
                return nil
            }
            if flags == .command {
                switch key {
                case "t": c.newTab(); return nil
                case "w": if let id = c.activeTabID { c.close(tab: id) }; return nil
                case "b": c.apply(.bold); return nil
                case "i": c.apply(.italic); return nil
                case "k": c.apply(.link); return nil
                default: break
                }
            }
            if flags == [.command, .shift] {
                if key == "]" || key == "}" { c.selectTab(offset: 1); return nil }
                if key == "[" || key == "{" { c.selectTab(offset: -1); return nil }
                if key == "c" { c.copy(); return nil }
            }
            if flags.contains(.control), event.keyCode == 48 {   // ⌃Tab / ⌃⇧Tab
                c.selectTab(offset: flags.contains(.shift) ? -1 : 1)
                return nil
            }
            return event
        }
    }
}

// MARK: - Global shortcut

/// System-wide "Open Scratchpad" shortcut (⌃⌥N) through Carbon's RegisterEventHotKey, which needs
/// no extra permission. Wispr exposes the same action as a configurable "open_scratchpad" hotkey.
final class GlobalShortcut {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    static let label = "⌃⌥N"

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { shortcut.action() }
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x5253_5450), id: 1)   // "RSTP"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Log.info("scratchpad shortcut unavailable (\(status))") }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
