import AppKit
import ApplicationServices
import Carbon
import CoreGraphics

/// Inserts text into whatever app has focus, using the strategy evidenced in Wispr Flow's
/// Swift helper:
///  - snapshot the pasteboard;
///  - offer the text with *delayed rendering* (NSPasteboardItemDataProvider), marked
///    org.nspasteboard.ConcealedType so clipboard managers skip it;
///  - post Cmd+V;
///  - if the target app requests the data, the paste worked; restore the old clipboard after 500 ms;
///  - if nobody requests it, the paste failed; leave the text on the clipboard for a manual Cmd+V.
@MainActor
final class TextInserter {
    enum Outcome {
        case pasted
        case copiedOnly(reason: String)
    }

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let restoreDelay: TimeInterval = 0.5
    private static let requestTimeout: TimeInterval = 1.0
    private static let kVK_ANSI_V: CGKeyCode = 9

    private var activeProvider: DelayedTextProvider?

    func insert(_ text: String) async -> Outcome {
        let pb = NSPasteboard.general

        if !AXIsProcessTrusted() {
            copyPlain(text, to: pb)
            Log.info("paste skipped: Accessibility not granted")
            return .copiedOnly(reason: "Sem permissão de Acessibilidade")
        }
        if IsSecureEventInputEnabled() {
            copyPlain(text, to: pb)
            Log.info("paste skipped: secure input is active")
            return .copiedOnly(reason: "Entrada segura ativa (campo de senha?)")
        }

        let saved = snapshot(pb)
        let provider = DelayedTextProvider(text: text)
        activeProvider = provider

        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        item.setString("", forType: Self.concealedType)
        pb.clearContents()
        guard pb.writeObjects([item]) else {
            copyPlain(text, to: pb)
            return .copiedOnly(reason: "Falha ao escrever na área de transferência")
        }

        // Give the pasteboard server a moment, like Wispr's pasteDelayMs.
        try? await Task.sleep(nanoseconds: 30_000_000)
        postCommandV()
        Log.info("posted Cmd+V (text length \(text.count))")

        let deadline = Date().addingTimeInterval(Self.requestTimeout)
        while !provider.wasRequested && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        if provider.wasRequested {
            Log.info("paste confirmed: target app requested the data")
            try? await Task.sleep(nanoseconds: UInt64(Self.restoreDelay * 1_000_000_000))
            restore(saved, to: pb)
            activeProvider = nil
            return .pasted
        }

        Log.info("paste not confirmed: no app requested the data within \(Self.requestTimeout)s")
        copyPlain(text, to: pb)
        activeProvider = nil
        return .copiedOnly(reason: "O app não aceitou a colagem; o texto foi copiado")
    }

    private func copyPlain(_ text: String, to pb: NSPasteboard) {
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func postCommandV() {
        // A private source keeps the user's physical modifier state out of the synthetic chord.
        let src = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: Self.kVK_ANSI_V, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: Self.kVK_ANSI_V, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { entry[type] = d } }
            return entry
        }
    }

    private func restore(_ saved: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }
}

/// Supplies the text only when an app actually asks for it, which tells us the paste landed.
private final class DelayedTextProvider: NSObject, NSPasteboardItemDataProvider {
    private let text: String
    private(set) var wasRequested = false

    init(text: String) { self.text = text }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        wasRequested = true
        item.setString(text, forType: type)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}
