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
        note.body.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
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

/// NSTextView with Wispr's editor metrics and light Markdown styling (headings, bold, italic,
/// code, quotes, done checklist items), so the note stays plain text that pastes anywhere.
struct ScratchEditor: NSViewRepresentable {
    let controller: ScratchpadController
    let noteID: UUID
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, noteID: noteID) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isContinuousSpellCheckingEnabled = true
        view.textContainerInset = NSSize(width: 11, height: 10)
        view.insertionPointColor = NSColor(DS.glow300)
        view.typingAttributes = MarkdownStyler.base
        view.string = text
        MarkdownStyler.style(view)
        controller.register(view, for: noteID)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        controller.register(view, for: noteID)
        if view.string != text, !context.coordinator.isEditing {
            view.string = text
            MarkdownStyler.style(view)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: ScratchpadController
        let noteID: UUID
        var isEditing = false
        init(controller: ScratchpadController, noteID: UUID) {
            self.controller = controller
            self.noteID = noteID
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            isEditing = true
            MarkdownStyler.style(view)
            let text = view.string
            MainActor.assumeIsolated { controller.textChanged(text, note: noteID) }
            isEditing = false
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

enum MarkdownStyler {
    /// NSFontManager weights: 5 regular, 6 medium, 9 bold (a descriptor weight trait is ignored
    /// for a font picked by name, so Figtree's faces are selected this way).
    static func font(_ size: CGFloat, _ weight: Int) -> NSFont {
        NSFontManager.shared.font(withFamily: "Figtree", traits: [], weight: weight, size: size)
            ?? .systemFont(ofSize: size, weight: weight >= 9 ? .bold : (weight >= 6 ? .medium : .regular))
    }
    static let bodyFont = font(14, 6)

    static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = 24
        p.maximumLineHeight = 24
        return p
    }()

    static var base: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor(DS.foreground), .paragraphStyle: paragraph, .baselineOffset: 3]
    }

    private static let rules: [(NSRegularExpression, (NSTextStorage, NSTextCheckingResult) -> Void)] = {
        func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) }
        let muted = NSColor(DS.vast500)
        return [
            (re(#"^#{1,3} .*$"#), { s, m in
                s.addAttribute(.font, value: font(18, 9), range: m.range)
                let hp = NSMutableParagraphStyle(); hp.minimumLineHeight = 30; hp.maximumLineHeight = 30
                s.addAttribute(.paragraphStyle, value: hp, range: m.range)
                s.addAttribute(.baselineOffset, value: 5, range: m.range)
            }),
            (re(#"\*\*[^*\n]+\*\*"#), { s, m in s.addAttribute(.font, value: font(14, 9), range: m.range) }),
            (re(#"(?<![\w*])_[^_\n]+_(?!\w)"#), { s, m in
                // The bundled Figtree has no italic face; slant it instead.
                s.addAttribute(.obliqueness, value: 0.18, range: m.range)
            }),
            (re(#"`[^`\n]+`"#), { s, m in
                s.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), range: m.range)
                s.addAttribute(.backgroundColor, value: NSColor(DS.backgroundTertiary), range: m.range)
            }),
            (re(#"^> .*$"#), { s, m in s.addAttribute(.foregroundColor, value: NSColor(DS.vast600), range: m.range) }),
            (re(#"^- \[x\] .*$"#), { s, m in
                s.addAttribute(.foregroundColor, value: muted, range: m.range)
                s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
            }),
            (re(#"^(- \[[ x]\]|-|\d+\.|>|#{1,3}) "#), { s, m in
                s.addAttribute(.foregroundColor, value: muted, range: m.range)
            }),
        ]
    }()

    static func style(_ view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(base, range: full)
        for (regex, apply) in rules {
            regex.enumerateMatches(in: storage.string, range: full) { m, _, _ in if let m { apply(storage, m) } }
        }
        storage.endEditing()
        view.typingAttributes = base
    }
}
