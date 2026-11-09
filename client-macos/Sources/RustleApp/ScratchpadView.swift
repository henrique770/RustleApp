import AppKit
import SwiftUI

/// The Scratchpad window, laid out from Wispr Flow's scratchpad renderer CSS:
///   .scratchpadContainer  rail 48px, radius 12, Figtree
///   .topBar               padding 8 12 8 0, background-tertiary; logo in the 48px rail, inline tabs
///   .sidebar              48px rail; open = 48 + clamp(120px, 25cqw, 200px); 36px rows
///   .contentArea          background, radius 12, margin 0 8 8 0
///   .editorInput          padding 12 16, 14px / 550 / line-height 28, caret glow-300
///   .floatingIconButton   32px circle, white, 1px border, shadow 0 2 8 rgba(0,0,0,.08)
///   .transformBar         white, radius 12, chips radius 16 (4 12, 12px/500), input 12px, submit 24px r8
///   .versionDropdown      min 220 / max 300 wide, max 320 tall, radius 12, padding 4
struct ScratchpadView: View {
    @ObservedObject var controller: ScratchpadController
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ScratchTopBar(controller: controller, model: model)
                HStack(spacing: 0) {
                    ScratchSidebar(controller: controller, model: model,
                                   openWidth: 48 + min(200, max(120, geo.size.width * 0.25)))
                    ScratchContent(controller: controller, model: model)
                        .padding(.trailing, 8).padding(.bottom, 8)
                }
            }
            .background(DS.backgroundTertiary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        .font(DS.ui(14))
        .foregroundColor(DS.foreground)
    }
}

// MARK: - Top bar

private struct ScratchTopBar: View {
    @ObservedObject var controller: ScratchpadController
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ScratchLogo().frame(width: 48)
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(controller.tabs) { tab in
                            ScratchTabView(controller: controller, tab: tab,
                                           title: model.note(tab.noteID)?.title ?? "Sem título",
                                           active: tab.id == controller.activeTabID)
                        }
                    }
                }
                .scrollIndicators(.never)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
                ToolbarButton(icon: "plus", help: "Nova aba (⌘T)") { controller.newTab() }
                if let toast = controller.toast { ScratchToast(toast: toast).transition(.opacity) }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                ToolbarButton(icon: controller.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              help: controller.expanded ? "Compactar janela" : "Expandir janela") {
                    controller.expanded.toggle()
                    controller.onToggleExpanded(controller.expanded)
                }
                ToolbarButton(icon: "xmark", help: "Fechar") { controller.onClose() }
            }
        }
        .padding(.vertical, 8).padding(.trailing, 12)
        .animation(.easeOut(duration: 0.2), value: controller.toast)
    }
}

/// Our own mark (the five bars of the RustleApp logo) in neutral-600, 16 px, like .topBarLogo.
private struct ScratchLogo: View {
    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            ForEach([5.0, 10, 14, 8, 4], id: \.self) { h in
                Capsule().fill(DS.vast700).frame(width: 1.8, height: h * 0.9)
            }
        }
        .frame(width: 16, height: 16)
    }
}

private struct ScratchTabView: View {
    @ObservedObject var controller: ScratchpadController
    let tab: ScratchpadController.Tab
    let title: String
    let active: Bool
    @State private var hover = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            if editing {
                TextField("Sem título", text: $draft)
                    .textFieldStyle(.plain).font(DS.ui(12, .semibold))
                    .frame(width: 110)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onChange(of: focused) { if !focused { commit() } }
            } else {
                Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 120, alignment: .leading)
            }
            Button { controller.close(tab: tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.clear))
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.vast500)
            .opacity(hover || active ? 1 : 0)
            .help("Fechar aba \(title)")
        }
        .font(DS.ui(12, active ? .semibold : .medium))
        .foregroundColor(active ? DS.foreground : DS.vast600)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(minWidth: 40, maxWidth: 160)
        .background(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, bottomTrailingRadius: 6, topTrailingRadius: 6)
            .fill(active ? DS.background : (hover ? DS.neutral200 : .clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { draft = title == "Nota sem título" ? "" : title; editing = true; focused = true }
        .onTapGesture { controller.activate(tab.id) }
        .contextMenu {
            Button("Renomear") { draft = title; editing = true; focused = true }
            Button("Mover para a esquerda") { controller.moveTab(tab.id, by: -1) }
            Button("Mover para a direita") { controller.moveTab(tab.id, by: 1) }
            Divider()
            Button("Fechar aba") { controller.close(tab: tab.id) }
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        controller.rename(tab: tab.id, to: draft)
    }
}

private struct ScratchToast: View {
    let toast: ScratchpadController.Toast
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: toast.isError ? "xmark" : "checkmark").font(.system(size: 10, weight: .semibold))
            Text(toast.message).lineLimit(1)
        }
        .font(DS.ui(12, .medium))
        .foregroundColor(toast.isError ? DS.red600 : DS.vast900)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(DS.neutral200))
    }
}

/// .toolbar: 28x28, radius 6, neutral-600; hover background-tertiary / foreground.
private struct ToolbarButton: View {
    let icon: String
    var help: String = ""
    var active = false
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: size, height: size)
                .foregroundColor(hover || active ? DS.foreground : DS.vast700)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover || active ? DS.neutral200 : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Sidebar

private struct ScratchSidebar: View {
    @ObservedObject var controller: ScratchpadController
    @ObservedObject var model: AppModel
    let openWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            SidebarRow(icon: "sidebar.left", label: "Recolher notas", open: controller.sidebarOpen,
                       active: controller.sidebarOpen) {
                withAnimation(.easeOut(duration: 0.15)) { controller.sidebarOpen.toggle() }
            }
            .padding(.top, 8)
            if controller.sidebarOpen {
                NotesPanel(controller: controller, model: model)
                    .transition(.opacity)
            } else {
                SidebarRow(icon: "square.and.pencil", label: "Nova nota", open: false) { controller.newTab() }
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                SidebarRow(icon: "sparkles", label: "Transformações", open: controller.sidebarOpen,
                           active: controller.bottomBar == .transforms) { controller.toggle(.transforms) }
                SidebarRow(icon: "textformat", label: "Formatação", open: controller.sidebarOpen,
                           active: controller.bottomBar == .formatting) { controller.toggle(.formatting) }
            }
            .padding(.vertical, 4)
        }
        .frame(width: controller.sidebarOpen ? openWidth : 48)
        .clipped()
    }
}

/// .sidebarButton: full width, 36px, icon centred in the 48px rail, label to the right when open.
private struct SidebarRow: View {
    let icon: String
    let label: String
    let open: Bool
    var active = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).frame(width: 48)
                if open {
                    Text(label).font(DS.ui(13, .medium)).lineLimit(1).padding(.trailing, 8)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
            .foregroundColor(hover || active ? DS.foreground : DS.vast700)
            .background(Rectangle().fill(hover ? DS.neutral200 : (active ? DS.neutral200.opacity(0.6) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
    }
}

private struct NotesPanel: View {
    @ObservedObject var controller: ScratchpadController
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(DS.vast500)
                TextField("", text: $controller.search, prompt: Text("Buscar notas…").foregroundColor(DS.vast500))
                    .textFieldStyle(.plain).font(DS.ui(12))
                if !controller.search.isEmpty {
                    Button { controller.search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundColor(DS.vast500).help("Limpar busca")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.border, lineWidth: 1))
            .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 6)

            SidebarRow(icon: "square.and.pencil", label: "Nova nota", open: true) { controller.newTab() }
            Rectangle().fill(DS.border).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 6)

            let notes = controller.visibleNotes
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(notes) { note in
                        NoteListItem(note: note, active: note.id == controller.activeNote?.id,
                                     select: { controller.open(note: note.id) },
                                     pin: { controller.togglePin(note.id) },
                                     delete: { controller.delete(note: note.id) })
                    }
                    if notes.isEmpty {
                        Text(controller.search.isEmpty ? "Nenhuma nota ainda" : "Nenhuma nota encontrada")
                            .font(DS.ui(12)).foregroundColor(DS.vast500)
                            .padding(.vertical, 16).padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
        }
    }
}

/// .noteItem: 6 8 padding, radius 6, title 12/500, date + snippet 11; actions on hover.
private struct NoteListItem: View {
    let note: AppModel.Note
    let active: Bool
    let select: () -> Void
    let pin: () -> Void
    let delete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if note.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundColor(DS.vast600) }
                    Text(note.title).font(DS.ui(12, .medium)).lineLimit(1)
                }
                Text(note.updated.formatted(.relative(presentation: .named)))
                    .font(DS.ui(11)).foregroundColor(DS.vast500).lineLimit(1)
                if !snippet.isEmpty {
                    Text(snippet).font(DS.ui(11)).foregroundColor(DS.vast600).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hover {
                HStack(spacing: 0) {
                    MiniAction(icon: note.pinned ? "pin.slash" : "pin", help: note.pinned ? "Desafixar" : "Fixar", action: pin)
                    MiniAction(icon: "trash", help: "Apagar nota", action: delete)
                }
                .padding(.leading, 2)
                .overlay(alignment: .leading) { Rectangle().fill(DS.border).frame(width: 1) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? DS.neutral200 : (hover ? DS.sand200 : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
    }

    private var snippet: String {
        note.body.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().first.map { MarkdownStyler.plain(String($0)) } ?? ""
    }
}

private struct MiniAction: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10))
                .frame(width: 20, height: 20)
                .foregroundColor(hover ? DS.foreground : DS.vast600)
                .background(RoundedRectangle(cornerRadius: 4).fill(hover ? DS.neutral200 : .clear))
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help)
    }
}

// MARK: - Content

private struct ScratchContent: View {
    @ObservedObject var controller: ScratchpadController
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let tab = controller.activeTab, let note = model.note(tab.noteID) {
                    ScratchEditor(controller: controller, noteID: note.id, text: note.body)
                        .id(note.id)
                    if note.isEmpty {
                        HStack(spacing: 6) {
                            Text(Config.trigger == .fn ? "fn" : Config.trigger.label)
                                .font(DS.ui(12, DS.w550)).foregroundColor(DS.vast500)
                                .padding(.horizontal, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(DS.backgroundTertiary))
                            Text("para ditar").font(DS.ui(14)).foregroundColor(DS.vast500)
                        }
                        .padding(.top, 16).padding(.leading, 16)
                        .allowsHitTesting(false)
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("Para pensamentos rápidos que você quer retomar depois")
                            .font(DS.display(20)).multilineTextAlignment(.center)
                        Button("Nova nota") { controller.newTab() }.buttonStyle(PrimaryButtonStyle())
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if controller.activeNote != nil {
                VStack(spacing: 8) {
                    ActionOverlay(controller: controller, model: model)
                    switch controller.bottomBar {
                    case .transforms: TransformBar(controller: controller)
                    case .formatting: FormattingBar(controller: controller)
                    case .none: EmptyView()
                    }
                }
                .padding(8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.background))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Floating actions at the bottom right: version history, delete, Send in <app>, Copy.
private struct ActionOverlay: View {
    @ObservedObject var controller: ScratchpadController
    @ObservedObject var model: AppModel

    var body: some View {
        let note = controller.activeNote
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if let note, !note.versions.isEmpty {
                FloatingIcon(icon: "clock.arrow.circlepath", help: "Histórico de versões", active: controller.versionMenuOpen) {
                    controller.versionMenuOpen.toggle()
                }
                .overlay(alignment: .bottomTrailing) {
                    if controller.versionMenuOpen {
                        VersionMenu(controller: controller, note: note)
                            .fixedSize()
                            .offset(x: 120, y: -40)
                    }
                }
                .zIndex(1)
            }
            if let note, !note.isEmpty {
                FloatingIcon(icon: "trash", help: "Apagar nota") { controller.delete(note: note.id) }
                if let app = controller.targetApp, let name = app.localizedName {
                    Button { controller.send() } label: {
                        Label("Enviar no \(name)", systemImage: "paperplane").lineLimit(1)
                    }
                    .buttonStyle(FloatingPillStyle(primary: false))
                    .help("Cola a nota no \(name)")
                }
            }
            Button { controller.copy() } label: { Label("Copiar", systemImage: "doc.on.doc") }
                .buttonStyle(FloatingPillStyle(primary: true))
                .disabled(note?.isEmpty ?? true)
                .opacity(note?.isEmpty ?? true ? 0.5 : 1)
        }
    }
}

private struct FloatingIcon: View {
    let icon: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                .frame(width: 32, height: 32)
                .foregroundColor(DS.foreground)
                .background(Circle().fill(hover || active ? DS.backgroundTertiary : Color.white))
                .overlay(Circle().strokeBorder(DS.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help)
    }
}

private struct FloatingPillStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(DS.ui(12, DS.w550))
            .foregroundColor(primary ? DS.primaryForeground : DS.foreground)
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(primary ? DS.primary.opacity(configuration.isPressed ? 0.8 : 1)
                                               : (configuration.isPressed ? DS.backgroundTertiary : Color.white)))
            .overlay(Capsule().strokeBorder(primary ? Color.clear : DS.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            .contentShape(Capsule())
    }
}

private struct VersionMenu: View {
    @ObservedObject var controller: ScratchpadController
    let note: AppModel.Note

    var body: some View {
        let versions = Array(note.versions.reversed())
        let current = versions.first { $0.body == note.body }?.id
        ScrollView {
            VStack(spacing: 0) {
                Text("Histórico de versões").font(DS.ui(11, .semibold)).foregroundColor(DS.vast500)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 6)
                ForEach(versions) { v in
                    VersionRow(version: v, active: v.id == current) { controller.restore(v) }
                }
            }
        }
        .scrollIndicators(.never)
        .frame(width: 240)
        .frame(maxHeight: 280)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }
}

private struct VersionRow: View {
    let version: AppModel.NoteVersion
    let active: Bool
    let select: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: version.source.icon).font(.system(size: 11)).frame(width: 16).padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(version.source.label).font(DS.ui(12, .medium))
                    Text(version.date.formatted(.relative(presentation: .named))).font(DS.ui(11)).foregroundColor(DS.vast500)
                }
                Spacer(minLength: 0)
                if active { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).padding(.top, 3) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? DS.sand200 : (hover ? DS.sand100 : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(active).onHover { hover = $0 }
    }
}

// MARK: - Bottom bars

private struct BarCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.border.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}

private struct TransformBar: View {
    @ObservedObject var controller: ScratchpadController
    @State private var request = ""

    var body: some View {
        BarCard {
            FlowLayout(spacing: 6) {
                if let suggestions = controller.suggestions {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { _, s in
                        Button(s.label) { controller.transform(s.prompt, suggestionID: s.id) }
                            .buttonStyle(ChipStyle())
                            .disabled(controller.isTransforming)
                            .help(s.prompt)
                    }
                    if !suggestions.isEmpty {
                        ToolbarButton(icon: "arrow.clockwise", help: "Novas sugestões", size: 26) {
                            controller.loadSuggestions(force: true)
                        }
                        .disabled(controller.isTransforming)
                    }
                } else {
                    ForEach([52.0, 80, 64], id: \.self) { w in ChipSkeleton(width: w) }
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

            Rectangle().fill(DS.backgroundTertiary).frame(height: 1).padding(.horizontal, 12)

            HStack(spacing: 8) {
                if controller.isTransforming {
                    TypingDots()
                    Spacer()
                } else {
                    TextField("", text: $request, prompt: Text("Peça uma mudança ou faça uma pergunta").foregroundColor(DS.vast500),
                              axis: .vertical)
                        .textFieldStyle(.plain).font(DS.ui(12)).lineLimit(1...4)
                        .onSubmit(submit)
                    if request.isEmpty {
                        Text("Enter ↵").font(DS.ui(11)).foregroundColor(DS.vast500)
                    }
                    Button(action: submit) {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                            .foregroundColor(DS.sand50)
                            .background(RoundedRectangle(cornerRadius: 8).fill(DS.vast900))
                    }
                    .buttonStyle(.plain)
                    .disabled(request.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(request.trimmingCharacters(in: .whitespaces).isEmpty ? 0.3 : 1)
                    .help("Enviar")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func submit() {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        controller.transform(text)
        request = ""
    }
}

private struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration)
    }
    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(DS.ui(12, .medium))
                .foregroundColor(hover ? DS.foreground : DS.vast900)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 16).fill(hover || configuration.isPressed ? DS.neutral200 : DS.backgroundTertiary))
                .opacity(enabled ? 1 : 0.5)
                .onHover { hover = $0 }
        }
    }
}

private struct ChipSkeleton: View {
    let width: CGFloat
    @State private var dim = false
    var body: some View {
        RoundedRectangle(cornerRadius: 16).fill(DS.backgroundTertiary)
            .frame(width: width, height: 26)
            .opacity(dim ? 0.45 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { dim = true } }
    }
}

private struct TypingDots: View {
    @State private var phase = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(DS.vast500).frame(width: 5, height: 5)
                    .opacity(phase ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: phase)
            }
        }
        .padding(.vertical, 2)
        .onAppear { phase = true }
    }
}

private struct FormattingBar: View {
    @ObservedObject var controller: ScratchpadController
    var body: some View {
        BarCard {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ToolbarButton(icon: "bold", help: "Negrito (⌘B)") { controller.apply(.bold) }
                    ToolbarButton(icon: "italic", help: "Itálico (⌘I)") { controller.apply(.italic) }
                    ToolbarButton(icon: "chevron.left.forwardslash.chevron.right", help: "Código") { controller.apply(.code) }
                    ToolbarButton(icon: "link", help: "Inserir link (⌘K)") { controller.apply(.link) }
                    Rectangle().fill(DS.border).frame(width: 1, height: 16).padding(.horizontal, 4)
                    ToolbarButton(icon: "textformat.size", help: "Título") { controller.apply(.heading) }
                    ToolbarButton(icon: "list.bullet", help: "Lista com marcadores") { controller.apply(.bullet) }
                    ToolbarButton(icon: "list.number", help: "Lista numerada") { controller.apply(.numbered) }
                    ToolbarButton(icon: "checklist", help: "Checklist") { controller.apply(.checklist) }
                    ToolbarButton(icon: "text.quote", help: "Citação") { controller.apply(.quote) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - Editor

/// The Scratchpad's editor: a MarkdownEditor wired to the controller (dictation, formatting, versions).
struct ScratchEditor: View {
    let controller: ScratchpadController
    let noteID: UUID
    let text: String

    var body: some View {
        MarkdownEditor(text: text,
                       onAttach: { controller.register($0, for: noteID) },
                       onEdit: { controller.textChanged($0, note: noteID) })
    }
}

/// NSTextView with Wispr's editor metrics that renders a note's Markdown in place: headings,
/// bold, italic, code, strikethrough, links, bullets, checkboxes, quotes and rules. The note stays
/// plain Markdown (what is saved, copied, sent and transformed); only attributes and drawing change.
/// The caret's line shows its syntax, so it can be edited as typed. Used by the Scratchpad and the
/// hub's Notes page.
struct MarkdownEditor: NSViewRepresentable {
    let text: String
    /// Body text size; every Markdown style scales with it (Scratchpad 14, hub 16).
    var size: CGFloat = 14
    /// Open with the caret (and so the scroll) at the top, as the hub does; otherwise the caret
    /// starts at the end, where Scratchpad dictation lands.
    var opensAtTop = false
    var onAttach: @MainActor (NSTextView) -> Void = { _ in }
    let onEdit: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, assembled by hand: MarkdownLayoutManager draws the bullets, boxes and rules.
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: ScratchpadController.defaultSize))
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = MarkdownTextView(frame: NSRect(origin: .zero, size: scroll.contentSize), textContainer: container)
        view.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view.scale = size / 14
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isContinuousSpellCheckingEnabled = true
        view.textContainerInset = NSSize(width: 11, height: 10)
        view.insertionPointColor = NSColor(DS.glow300)
        view.linkTextAttributes = [.foregroundColor: MarkdownStyler.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .cursor: NSCursor.pointingHand]
        view.string = text
        if opensAtTop { view.setSelectedRange(NSRange(location: 0, length: 0)) }
        MarkdownStyler.style(view)
        onAttach(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        onAttach(view)
        if view.string != text, !context.coordinator.isEditing {
            view.string = text
            MarkdownStyler.style(view)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        var isEditing = false
        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            isEditing = true
            MarkdownStyler.style(view)
            let text = view.string
            MainActor.assumeIsolated { parent.onEdit(text) }
            isEditing = false
        }

        /// Moving to another line hides the old line's syntax and shows the new one's. Deferred,
        /// because the selection also moves in the middle of an edit.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? MarkdownTextView else { return }
            DispatchQueue.main.async { view.restyleIfCaretLineChanged() }
        }

        /// Enter on a list line continues the list; Enter on an empty item ends it.
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let ns = view.string as NSString
            let sel = view.selectedRange()
            let line = ns.substring(with: ns.lineRange(for: NSRange(location: sel.location, length: 0)))
                .trimmingCharacters(in: .newlines)
            guard let match = line.range(of: #"^(- \[[ x]\] |- |\d+\. |> )"#, options: .regularExpression) else { return false }
            var prefix = String(line[match])
            if line == prefix || line.trimmingCharacters(in: .whitespaces) == prefix.trimmingCharacters(in: .whitespaces) {
                let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
                let r = NSRange(location: lineStart, length: (prefix as NSString).length)
                if view.shouldChangeText(in: r, replacementString: "") { view.replaceCharacters(in: r, with: ""); view.didChangeText() }
                return true
            }
            if prefix.hasPrefix("- [x]") { prefix = "- [ ] " }
            if let n = Int(prefix.dropLast(2)) { prefix = "\(n + 1). " }
            view.insertText("\n" + prefix, replacementRange: sel)
            return true
        }
    }
}

/// The editor's text view: tracks which lines show their syntax, and toggles checkboxes on click.
final class MarkdownTextView: NSTextView {
    /// Body size / 14: MarkdownStyler and MarkdownLayoutManager scale their metrics by it.
    var scale: CGFloat = 1
    /// Lines whose Markdown syntax is visible (the caret's), nil while the editor is not focused.
    var revealed: NSRange?
    private(set) var isFocused = false

    /// The lines the selection touches, when the editor has the focus.
    var caretLines: NSRange? {
        isFocused ? (string as NSString).lineRange(for: selectedRange()) : nil
    }

    func restyleIfCaretLineChanged() {
        if caretLines != revealed { MarkdownStyler.style(self) }
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        isFocused = true
        MarkdownStyler.style(self)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        isFocused = false
        MarkdownStyler.style(self)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard let box = checkbox(at: convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        // "- [ ] " -> "- [x] " and back, as an ordinary undoable edit.
        let marker = (string as NSString).substring(with: box) as NSString
        let state = NSRange(location: box.location + marker.range(of: "[").location + 1, length: 1)
        let checked = (string as NSString).substring(with: state) != " "
        if shouldChangeText(in: state, replacementString: checked ? " " : "x") {
            replaceCharacters(in: state, with: checked ? " " : "x")
            didChangeText()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if checkbox(at: convert(event.locationInWindow, from: nil)) != nil { NSCursor.pointingHand.set() }
    }

    /// The task marker ("- [ ]") whose checkbox is under `point`, if any.
    private func checkbox(at point: NSPoint) -> NSRange? {
        guard let layout = layoutManager as? MarkdownLayoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let char = min(layout.characterIndexForGlyph(at: layout.glyphIndex(for: p, in: container)), storage.length - 1)
        var hit: NSRange?
        storage.enumerateAttribute(.markdownMark, in: (string as NSString).paragraphRange(for: NSRange(location: char, length: 0))) { value, range, stop in
            guard let mark = value as? String, mark == MarkdownStyler.Mark.task || mark == MarkdownStyler.Mark.done,
                  layout.checkboxRect(for: range).insetBy(dx: -3, dy: -3).contains(p) else { return }
            hit = range
            stop.pointee = true
        }
        return hit
    }
}

/// Draws what the hidden Markdown markers stand for: bullets, checkboxes, quote bars and rules.
final class MarkdownLayoutManager: NSLayoutManager {
    private var k: CGFloat { (firstTextView as? MarkdownTextView)?.scale ?? 1 }

    /// Where a marker starts and the line it is on, in container coordinates.
    private func place(_ chars: NSRange) -> (x: CGFloat, line: NSRect)? {
        let glyphs = glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        return (line.minX + location(forGlyphAt: glyphs.location).x, line)
    }

    /// Text sits above the fragment's centre (MarkdownStyler's baseline offset).
    private func textMidY(_ line: NSRect) -> CGFloat { line.midY - 0.5 * k }

    /// The checkbox drawn for a task marker, in container coordinates (also its click target).
    func checkboxRect(for chars: NSRange) -> NSRect {
        guard let (x, line) = place(chars) else { return .zero }
        return NSRect(x: x + k, y: textMidY(line) - 7 * k, width: 14 * k, height: 14 * k)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let k = self.k
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.markdownMark, in: chars) { value, range, _ in
            guard let mark = value as? String, let (x0, line0) = place(range) else { return }
            let x = x0 + origin.x
            let line = line0.offsetBy(dx: origin.x, dy: origin.y)
            let midY = textMidY(line)
            switch mark {
            case MarkdownStyler.Mark.bullet:
                NSColor(DS.foreground).setFill()
                NSBezierPath(ovalIn: NSRect(x: x + 3 * k, y: midY - 2.5 * k, width: 5 * k, height: 5 * k)).fill()
            case MarkdownStyler.Mark.task, MarkdownStyler.Mark.done:
                let box = checkboxRect(for: range).offsetBy(dx: origin.x, dy: origin.y)
                if mark == MarkdownStyler.Mark.done {
                    NSColor(DS.foreground).setFill()
                    NSBezierPath(roundedRect: box, xRadius: 3.5 * k, yRadius: 3.5 * k).fill()
                    let tick = NSBezierPath()
                    tick.move(to: NSPoint(x: box.minX + 3.5 * k, y: box.midY))
                    tick.line(to: NSPoint(x: box.minX + 6 * k, y: box.maxY - 3.5 * k))
                    tick.line(to: NSPoint(x: box.maxX - 3 * k, y: box.minY + 3.5 * k))
                    tick.lineWidth = 1.8 * k
                    tick.lineCapStyle = .round
                    tick.lineJoinStyle = .round
                    NSColor(DS.background).setStroke()
                    tick.stroke()
                } else {
                    let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.75 * k, dy: 0.75 * k), xRadius: 3 * k, yRadius: 3 * k)
                    path.lineWidth = 1.5 * k
                    NSColor(DS.vast500).setStroke()
                    path.stroke()
                }
            case MarkdownStyler.Mark.quote:
                NSColor(DS.sand700).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: line.minY + 2 * k, width: 3 * k, height: line.height - 4 * k),
                             xRadius: 1.5 * k, yRadius: 1.5 * k).fill()
            case MarkdownStyler.Mark.rule:
                NSColor(DS.sand700).setFill()
                NSRect(x: line.minX + container.lineFragmentPadding, y: midY, width: line.width - 2 * container.lineFragmentPadding,
                       height: 1).fill()
            default: break
            }
        }
    }
}

extension NSAttributedString.Key {
    /// What MarkdownLayoutManager draws over a hidden marker (MarkdownStyler.Mark).
    static let markdownMark = NSAttributedString.Key("RustleMarkdownMark")
}

enum MarkdownStyler {
    enum Mark {
        static let bullet = "bullet", task = "task", done = "done", quote = "quote", rule = "rule"
    }

    /// NSFontManager weights: 5 regular, 6 medium, 9 bold (a descriptor weight trait is ignored
    /// for a font picked by name, so Figtree's faces are selected this way).
    static func font(_ size: CGFloat, _ weight: Int) -> NSFont {
        NSFontManager.shared.font(withFamily: "Figtree", traits: [], weight: weight, size: size)
            ?? .systemFont(ofSize: size, weight: weight >= 9 ? .bold : (weight >= 6 ? .medium : .regular))
    }
    /// Hidden syntax keeps its characters but takes no room.
    static let hiddenFont = NSFont.systemFont(ofSize: 0.1)
    static let linkColor = NSColor(DS.chord600)
    static let muted = NSColor(DS.vast500)

    /// Heading levels 1-6 at a 14pt body: size, line height, baseline offset.
    private static let headings: [(size: CGFloat, line: CGFloat, baseline: CGFloat)] =
        [(22, 34, 6), (18, 30, 5), (16, 26, 4), (14, 24, 3), (14, 24, 3), (14, 24, 3)]

    /// Fonts and line metrics for one editor, scaled from the 14pt Scratchpad sizes by `k`.
    private struct Metrics {
        let k: CGFloat
        let body: NSFont, bold: NSFont, code: NSFont
        let base: [NSAttributedString.Key: Any]

        init(_ k: CGFloat) {
            self.k = k
            body = font(14 * k, 6)
            bold = font(14 * k, 9)
            code = .monospacedSystemFont(ofSize: 12.5 * k, weight: .regular)
            base = [.font: body, .foregroundColor: NSColor(DS.foreground), .paragraphStyle: lineStyle(24 * k), .baselineOffset: 3 * k]
        }
    }

    private static func lineStyle(_ height: CGFloat, indent: CGFloat = 0, spaceBefore: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = height
        p.maximumLineHeight = height
        p.headIndent = indent
        p.paragraphSpacingBefore = spaceBefore
        return p
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let headingRE = re(#"^(#{1,6})[ \t]+"#)
    private static let ruleRE = re(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let taskRE = re(#"^([ \t]*)([-*+] \[([ xX])\])[ \t]"#)
    private static let bulletRE = re(#"^([ \t]*)([-*+])[ \t]"#)
    private static let numberedRE = re(#"^([ \t]*)(\d{1,9}[.)])[ \t]"#)
    private static let quoteRE = re(#"^ {0,3}(>[ \t]?)"#)
    private static let fenceRE = re(#"^ {0,3}(```|~~~)"#)
    private static let codeRE = re(#"`[^`\n]+`"#)
    private static let boldRE = re(#"\*\*(?=\S).+?(?<=\S)\*\*|(?<!\w)__(?=\S).+?(?<=\S)__(?!\w)"#)
    private static let italicRE = re(#"(?<![\w*])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?![\w*])|(?<![\w_])_(?=[^\s_])([^_\n]+?)(?<=[^\s_])_(?![\w_])"#)
    private static let strikeRE = re(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let linkRE = re(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    private static let urlRE = re(#"(?<![(\[<\w])https?://[^\s<>]*[^\s<>.,;:!?)\]'"]"#)

    static func style(_ view: NSTextView) {
        guard let storage = view.textStorage, !view.hasMarkedText() else { return }
        let md = view as? MarkdownTextView
        let m = Metrics(md?.scale ?? 1)
        let reveal = md?.caretLines
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(m.base, range: full)
        var inFence = false
        ns.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, line, enclosing, _ in
            let revealed = reveal.map { NSIntersectionRange($0, enclosing).length > 0 || $0 == enclosing } ?? false
            styleLine(storage, ns, line, m, revealed: revealed, inFence: &inFence)
        }
        storage.endEditing()
        md?.revealed = reveal
        view.typingAttributes = m.base
    }

    private static func styleLine(_ s: NSTextStorage, _ ns: NSString, _ line: NSRange, _ m: Metrics, revealed: Bool, inFence: inout Bool) {
        guard line.length > 0 else { return }
        let k = m.k
        let text = ns.substring(with: line)
        let local = NSRange(location: 0, length: line.length)
        func doc(_ r: NSRange) -> NSRange { NSRange(location: line.location + r.location, length: r.length) }
        func first(_ regex: NSRegularExpression) -> NSTextCheckingResult? { regex.firstMatch(in: text, range: local) }
        /// Markers the caret is not on take no room; on the caret's line they show, muted.
        func syntax(_ r: NSRange) {
            if revealed {
                s.addAttribute(.foregroundColor, value: muted, range: r)
            } else {
                s.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: r)
            }
        }
        /// A marker drawn as something else: its characters take no room and `width` is left for
        /// the drawing, so "[ ]" and "[x]" (or "-" and "*") line their text up the same way.
        func drawn(_ r: NSRange, _ mark: String, width: CGFloat) {
            s.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .markdownMark: mark], range: r)
            s.addAttribute(.kern, value: width, range: NSRange(location: NSMaxRange(r) - 1, length: 1))
        }
        func width(_ r: NSRange) -> CGFloat { (ns.substring(with: doc(r)) as NSString).size(withAttributes: m.base).width }
        /// Wrapped lines of a list item or quote start under its text.
        func hang(_ match: NSTextCheckingResult, marker: Int, width w: CGFloat) {
            let lead = width(NSRange(location: 0, length: match.range(at: marker).location))
            let gap = NSRange(location: NSMaxRange(match.range(at: marker)), length: NSMaxRange(match.range) - NSMaxRange(match.range(at: marker)))
            s.addAttribute(.paragraphStyle, value: lineStyle(24 * k, indent: lead + w + width(gap)), range: line)
        }

        if first(fenceRE) != nil {
            inFence.toggle()
            s.addAttributes([.font: m.code, .foregroundColor: muted], range: line)
            return
        }
        if inFence {
            s.addAttributes([.font: m.code, .backgroundColor: NSColor(DS.backgroundTertiary)], range: line)
            return
        }

        var content = local
        var heading: Int?
        if let match = first(headingRE) {
            let level = match.range(at: 1).length
            let h = headings[level - 1]
            heading = level
            s.addAttributes([.font: font(h.size * k, 9), .baselineOffset: h.baseline * k,
                             .paragraphStyle: lineStyle(h.line * k, spaceBefore: line.location > 0 ? 6 * k : 0)], range: line)
            syntax(doc(match.range))
            content = NSRange(location: match.range.length, length: line.length - match.range.length)
        } else if first(ruleRE) != nil {
            s.addAttributes(revealed ? [.foregroundColor: muted] : [.foregroundColor: NSColor.clear, .markdownMark: Mark.rule], range: line)
            return
        } else if let match = first(taskRE) {
            let checked = (text as NSString).substring(with: match.range(at: 3)) != " "
            drawn(doc(match.range(at: 2)), checked ? Mark.done : Mark.task, width: 22 * k)
            hang(match, marker: 2, width: 22 * k)
            content = NSRange(location: match.range.length, length: line.length - match.range.length)
            if checked {
                s.addAttributes([.foregroundColor: muted, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: doc(content))
            }
        } else if let match = first(bulletRE) {
            drawn(doc(match.range(at: 2)), Mark.bullet, width: 12 * k)
            hang(match, marker: 2, width: 12 * k)
            content = NSRange(location: match.range.length, length: line.length - match.range.length)
        } else if let match = first(numberedRE) {
            s.addAttribute(.foregroundColor, value: muted, range: doc(match.range(at: 2)))
            hang(match, marker: 2, width: width(match.range(at: 2)))
            content = NSRange(location: match.range.length, length: line.length - match.range.length)
        } else if let match = first(quoteRE) {
            s.addAttribute(.foregroundColor, value: NSColor(DS.vast600), range: line)
            drawn(doc(match.range(at: 1)), Mark.quote, width: 14 * k)
            hang(match, marker: 1, width: 14 * k)
            content = NSRange(location: match.range.length, length: line.length - match.range.length)
        }

        // Inline spans; nothing is styled inside `code`.
        var code: [NSRange] = []
        codeRE.enumerateMatches(in: text, range: content) { match, _, _ in
            guard let r = match?.range else { return }
            code.append(r)
            s.addAttributes([.font: m.code, .backgroundColor: NSColor(DS.backgroundTertiary)], range: doc(r))
            syntax(doc(NSRange(location: r.location, length: 1)))
            syntax(doc(NSRange(location: NSMaxRange(r) - 1, length: 1)))
        }
        func spans(_ regex: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: text, range: content) { match, _, _ in
                guard let match, !code.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return }
                body(match)
            }
        }
        spans(boldRE) { match in
            if heading == nil { s.addAttribute(.font, value: m.bold, range: doc(match.range)) }
            syntax(doc(NSRange(location: match.range.location, length: 2)))
            syntax(doc(NSRange(location: NSMaxRange(match.range) - 2, length: 2)))
        }
        spans(italicRE) { match in
            // The bundled Figtree has no italic face; slant it instead.
            s.addAttribute(.obliqueness, value: 0.18, range: doc(match.range))
            syntax(doc(NSRange(location: match.range.location, length: 1)))
            syntax(doc(NSRange(location: NSMaxRange(match.range) - 1, length: 1)))
        }
        spans(strikeRE) { match in
            s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: doc(match.range(at: 1)))
            syntax(doc(NSRange(location: match.range.location, length: 2)))
            syntax(doc(NSRange(location: NSMaxRange(match.range) - 2, length: 2)))
        }
        spans(linkRE) { match in
            let label = match.range(at: 1)
            if let url = URL(string: (text as NSString).substring(with: match.range(at: 2))) {
                s.addAttribute(.link, value: url, range: doc(label))
            }
            syntax(doc(NSRange(location: match.range.location, length: 1)))
            syntax(doc(NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label))))
        }
        spans(urlRE) { match in
            if let url = URL(string: (text as NSString).substring(with: match.range)) { s.addAttribute(.link, value: url, range: doc(match.range)) }
        }
    }

    /// A line as plain text for list previews: block marker and inline syntax removed.
    static func plain(_ line: String) -> String {
        var s = line.replacingOccurrences(of: #"^\s*(#{1,6}|[-*+] \[[ xX]\]|[-*+]|\d{1,9}[.)]|>)\s+"#, with: "", options: .regularExpression)
        s = linkRE.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1")
        for re in [boldRE, strikeRE, codeRE, italicRE] {
            let ns = s as NSString
            var out = ""
            var last = 0
            re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let r = match?.range else { return }
                let marker = re === boldRE || re === strikeRE ? 2 : 1
                out += ns.substring(with: NSRange(location: last, length: r.location - last))
                out += ns.substring(with: NSRange(location: r.location + marker, length: r.length - 2 * marker))
                last = NSMaxRange(r)
            }
            s = out + ns.substring(from: last)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
