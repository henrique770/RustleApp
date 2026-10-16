import AppKit
import SwiftUI

/// The hub window, rebuilt from Wispr Flow's hub layout (recovered with REA from the renderer CSS):
/// a 216 px sand sidebar, and the page as an inset card (radius 24/24/16/16, 1 px border,
/// 8 px right/bottom margin) under a 52 px title-bar strip with the traffic lights.
struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var page: Page
    @AppStorage(Prefs.onboardingDone) private var onboardingDone = false

    init(model: AppModel, initialPage: Page = .home) {
        self.model = model
        _page = State(initialValue: initialPage)
    }

    enum Page: String, CaseIterable, Identifiable {
        case home, notetaker, dictionary, snippets, style, notes, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: return "Início"
            case .notetaker: return "Notetaker"
            case .dictionary: return "Dicionário"
            case .snippets: return "Snippets"
            case .style: return "Estilo"
            case .notes: return "Notas"
            case .settings: return "Configurações"
            }
        }
        var icon: String {
            switch self {
            case .home: return "square.grid.2x2"
            case .notetaker: return "record.circle"
            case .dictionary: return "book.closed"
            case .snippets: return "scissors"
            case .style: return "textformat"
            case .notes: return "note.text"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        if onboardingDone {
            hub
        } else {
            // First run: the questionnaire fills the window (Wispr shows its onboarding the same way).
            OnboardingView(model: model) {
                onboardingDone = true
                page = .home
            }
            .frame(minWidth: 900, minHeight: 600)
            .ignoresSafeArea()
        }
    }

    private var hub: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, page: $page)
            VStack(spacing: 0) {
                Color.clear.frame(height: 52)   // title-bar strip (.contentContainer.noProgressBar height:52px)
                PageCard {
                    switch page {
                    case .home: HomePage(model: model, page: $page)
                    case .notetaker: NotetakerPage(model: model)
                    case .dictionary: DictionaryPage(model: model)
                    case .snippets: SnippetsPage(model: model)
                    case .style: StylePage(model: model)
                    case .notes: NotesPage(model: model)
                    case .settings: SettingsPage(model: model)
                    }
                }
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
        }
        .background(DS.backgroundTertiary)
        .foregroundColor(DS.foreground)
        .font(DS.ui(15))
        .frame(minWidth: 900, minHeight: 600)
        .ignoresSafeArea()
        .onChange(of: model.pageRequest) { request in
            guard let request else { return }
            page = request
            model.pageRequest = nil
        }
    }
}

// MARK: - Frame

/// .page { border-radius:24px 24px 16px 16px; border:1px solid var(--border); background:var(--background) }
private struct PageCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 16,
                                           bottomTrailingRadius: 16, topTrailingRadius: 24)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(DS.background))
            .clipShape(shape)
            .overlay(shape.stroke(DS.border, lineWidth: 1))
    }
}

/// Scrollable page body: padding 40/40/0, content max-width ~800 (.pageScrollable).
private struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 800, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 40)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Sidebar

/// .container { width:216px; padding:12px; gap:10px } / .item { padding:8px; radius:6px; 15/20 w550 }
private struct Sidebar: View {
    @ObservedObject var model: AppModel
    @Binding var page: MainView.Page

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: 28) // room for the traffic lights (trafficLightPosition y:19)
            BrandRow()
                .padding(.bottom, 16)
            VStack(spacing: 4) {
                ForEach([MainView.Page.home, .notetaker, .dictionary, .snippets, .style, .notes]) { p in
                    SidebarItem(title: p.title, icon: p.icon, active: page == p,
                                recording: p == .notetaker && model.activeMeetingID != nil) {
                        // Clicking Notetaker again returns to the meeting list.
                        if p == .notetaker && page == .notetaker { model.openMeetingID = nil }
                        page = p
                    }
                }
            }
            Spacer(minLength: 0)
            if !model.permissions.allGranted {
                PermissionNudge(model: model) { page = .settings }
            }
            Rectangle().fill(DS.border).frame(height: 1).padding(.top, 8)
            VStack(spacing: 4) {
                SidebarItem(title: MainView.Page.settings.title, icon: MainView.Page.settings.icon,
                            active: page == .settings) { page = .settings }
                SidebarItem(title: "Ajuda", icon: "questionmark.circle", active: false) {
                    NSWorkspace.shared.open(Log.url)
                }
            }
            .padding(.top, 8)
        }
        .padding(12)
        .frame(width: 216)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Brand row in the sidebar's .flowSection position (our own mark, not Wispr's logo).
private struct BrandRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(DS.vast950).frame(width: 25, height: 25)
                HStack(spacing: 1.5) {
                    ForEach([5.0, 10, 14, 8, 4], id: \.self) { h in
                        Capsule().fill(DS.sand50).frame(width: 2, height: h)
                    }
                }
            }
            Text("Rustle").font(DS.ui(18, .bold)).tracking(-0.3)
            Text("Local")
                .font(DS.ui(11, .semibold))
                .foregroundColor(DS.fathom950)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color(hex: 0xE2F5F2)))
        }
        .padding(.horizontal, 5)
    }
}

private struct SidebarItem: View {
    let title: String
    let icon: String
    let active: Bool
    var recording = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 20, height: 20)
                Text(title).font(DS.ui(15, DS.w550))
                Spacer(minLength: 0)
                if recording { RecordingDot() }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(active || hover ? DS.neutral200 : DS.backgroundTertiary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Bordered card in the sidebar's CTA slot (.studentChallengeItem style) for missing permissions.
private struct PermissionNudge: View {
    @ObservedObject var model: AppModel
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Conceda as permissões").font(DS.ui(15, .semibold))
                Text("Sem Acessibilidade o RustleApp não detecta o fn nem cola o texto.")
                    .font(DS.ui(13)).foregroundColor(DS.neutral600)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(DS.neutral200))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.border, lineWidth: 1))
            .shadow(color: Color(hex: 0x1A1A1A, opacity: 0.1), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }
}

// MARK: - Home

private struct HomePage: View {
    @ObservedObject var model: AppModel
    @Binding var page: MainView.Page
    @AppStorage(Prefs.hotkey) private var hotkey = "fn"
    @State private var query = ""
    @State private var searching = false

    private var hotkeyLabel: String { HotkeyMonitor.Trigger(rawValue: hotkey)?.label ?? "fn" }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline) {
                    PageTitle(text: model.displayFirstName.isEmpty ? "Bem-vindo de volta" : "Bem-vindo de volta, \(model.displayFirstName)", size: 34)
                    Spacer()
                    StatusChip(state: model.serverState)
                }

                // .root { gap:16px } .stat { baseline, gap:8px } .value { EBGaramond 28 } .label { 16 }
                HStack(spacing: 40) {
                    Stat(value: "\(model.dayStreak)", label: model.dayStreak == 1 ? "dia seguido" : "dias seguidos")
                    Stat(value: model.totalWords.formatted(), label: "palavras no total")
                    Stat(value: model.wordsPerMinute > 0 ? "\(model.wordsPerMinute)" : "—", label: "ppm")
                }

                HotkeyHint(label: hotkeyLabel)

                if !model.permissions.allGranted {
                    PermissionBanner(model: model)
                }

                HistoryList(model: model, query: $query, searching: $searching)
            }
        }
    }
}

private struct StatusChip: View {
    let state: AppModel.ServerState
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(DS.ui(13, .medium)).foregroundColor(DS.neutral600)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(DS.backgroundTertiary))
        .help(help)
    }
    private var color: Color {
        switch state { case .online: return DS.success500; case .starting: return DS.glow300; case .offline: return DS.destructive500 }
    }
    private var text: String {
        switch state { case .online: return "Transcrição local ativa"; case .starting: return "Carregando modelo…"; case .offline: return "Servidor parado" }
    }
    private var help: String {
        if case .offline(let msg) = state { return msg }
        return ""
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(DS.display(28)).tracking(-1.1)
            Text(label).font(DS.ui(16)).foregroundColor(DS.neutral600)
        }
    }
}

/// Dark rounded hint card ("Hold fn to dictate"), using the Flow bar's black/vast palette.
private struct HotkeyHint: View {
    let label: String
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Fale naturalmente, em qualquer app")
                    .font(DS.display(24)).tracking(-0.9).foregroundColor(DS.sand50)
                HStack(spacing: 6) {
                    Text("Segure").foregroundColor(DS.vast300)
                    KeyCap(text: label)
                    Text("para ditar e solte para colar. Ou clique na barra no rodapé da tela.")
                        .foregroundColor(DS.vast300)
                }
                .font(DS.ui(15))
            }
            Spacer()
            MiniWave()
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16).fill(DS.vast950))
    }
}

private struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(DS.ui(13, .semibold))
            .foregroundColor(DS.sand50)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(DS.vast900))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DS.vast700, lineWidth: 1))
    }
}

private struct MiniWave: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array([8.0, 16, 24, 14, 28, 18, 10, 20, 12].enumerated()), id: \.offset) { _, h in
                Capsule().fill(DS.sand50).frame(width: 3, height: h)
            }
        }
        .frame(width: 73, height: 30)
        .padding(.horizontal, 8)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(DS.vast900, lineWidth: 1))
    }
}

private struct PermissionBanner: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(DS.glow300).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("Falta permissão: \(missing)").font(DS.ui(15, DS.w550))
                Text("Ative o RustleApp em Ajustes do Sistema → Privacidade e Segurança. Se ele já aparece ativado, use Reparar permissões e depois Reiniciar app.")
                    .font(DS.ui(15)).foregroundColor(DS.neutral600)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Abrir Ajustes") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }.buttonStyle(PrimaryButtonStyle())
                    Button("Reparar permissões") { model.repairPermissions() }.buttonStyle(SecondaryButtonStyle())
                    Button("Reiniciar app") { model.relaunch() }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xFDF3EA)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xFACDA1), lineWidth: 1))
    }
    private var missing: String {
        var m: [String] = []
        if !model.permissions.accessibility { m.append("Acessibilidade") }
        if !model.permissions.microphone { m.append("Microfone") }
        return m.joined(separator: ", ")
    }
}

/// Dictation history grouped by day: sticky uppercase header (12/20 w600 .075em), a bordered
/// section card (radius 16), rows = 98 px time column (13 px tertiary) + transcript (15/20),
/// hover reveals the action buttons.
private struct HistoryList: View {
    @ObservedObject var model: AppModel
    @Binding var query: String
    @Binding var searching: Bool

    private var groups: [(String, [AppModel.HistoryEntry])] {
        let items = query.isEmpty ? model.history
            : model.history.filter { $0.text.localizedCaseInsensitiveContains(query) }
        let cal = Calendar.current
        var order: [String] = []
        var map: [String: [AppModel.HistoryEntry]] = [:]
        for e in items {
            let key: String
            if cal.isDateInToday(e.date) { key = "Hoje" }
            else if cal.isDateInYesterday(e.date) { key = "Ontem" }
            else { key = e.date.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(e)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if searching {
                    HubTextField(placeholder: "Buscar transcrições anteriores", text: $query)
                        .frame(maxWidth: 320)
                } else {
                    SectionLabel(text: "Histórico")
                }
                Spacer()
                IconButton(systemName: searching ? "xmark" : "magnifyingglass", help: "Buscar") {
                    searching.toggle(); if !searching { query = "" }
                }
            }
            .padding(.bottom, 8)

            if model.history.isEmpty {
                EmptyHistory()
            } else if groups.isEmpty {
                Text("Nada encontrado.").font(DS.ui(15)).foregroundColor(DS.foregroundTertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ForEach(groups, id: \.0) { title, entries in
                    SectionLabel(text: title).padding(.top, 16).padding(.bottom, 8)
                    ListCard {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                            HistoryRow(entry: e) { model.history.removeAll { $0.id == e.id } }
                            if i < entries.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: AppModel.HistoryEntry
    let delete: () -> Void
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                .frame(width: 98, alignment: .leading)
                .padding(16)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text).font(DS.ui(15)).foregroundColor(DS.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.pasted || entry.appName != nil {
                    HStack(spacing: 6) {
                        if let app = entry.appName { Text(app) }
                        if !entry.pasted { Text("· não colado").foregroundColor(DS.glow300) }
                    }
                    .font(DS.ui(12)).foregroundColor(DS.foregroundTertiary)
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                IconButton(systemName: copied ? "checkmark" : "doc.on.doc", help: "Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                IconButton(systemName: "trash", help: "Apagar", action: delete)
            }
            .padding(.vertical, 10).padding(.trailing, 8)
            .opacity(hover ? 1 : 0)
        }
        .background(hover ? DS.backgroundTertiary : Color.clear)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// .emptyTable: icon tile (padding 16, radius 6, tertiary bg) + 20/28 w600 title + 15/20 body.
private struct EmptyHistory: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform")
                .font(.system(size: 20))
                .foregroundColor(DS.foregroundTertiary)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 6).fill(DS.backgroundTertiary))
            VStack(spacing: 8) {
                Text("Nenhum ditado ainda").font(DS.ui(20, .semibold))
                Text("Assim que você ditar em diferentes apps, todo o histórico aparece aqui.")
                    .font(DS.ui(15)).foregroundColor(DS.neutral600)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 377)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

// MARK: - Shared page header

private struct PageHeader<Trailing: View>: View {
    let title: String
    let description: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 12) {
                PageTitle(text: title)
                Text(description).font(DS.ui(15)).foregroundColor(DS.neutral600)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            trailing
        }
    }
}

// MARK: - Dictionary

private struct DictionaryPage: View {
    @ObservedObject var model: AppModel
    @State private var adding = false
    @State private var word = ""
    @State private var query = ""

    private var words: [String] {
        let all = model.serverSettings.dictionary
        return query.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Dicionário",
                           description: "Palavras, nomes e siglas que o RustleApp deve sempre acertar. Elas são enviadas ao modelo como dica de reconhecimento.") {
                    Button("Adicionar") { adding = true }.buttonStyle(PrimaryButtonStyle())
                }
                if adding {
                    HStack(spacing: 8) {
                        HubTextField(placeholder: "Adicionar uma palavra nova", text: $word, onSubmit: add)
                        Button("Salvar", action: add).buttonStyle(PrimaryButtonStyle())
                        Button("Cancelar") { adding = false; word = "" }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                HubTextField(placeholder: "Buscar no seu vocabulário", text: $query)
                if words.isEmpty {
                    Text(model.serverSettings.dictionary.isEmpty ? "Seu dicionário está vazio." : "Nada encontrado.")
                        .font(DS.ui(15)).foregroundColor(DS.foregroundTertiary)
                } else {
                    ListCard {
                        ForEach(Array(words.enumerated()), id: \.element) { i, w in
                            WordRow(text: w) { model.serverSettings.dictionary.removeAll { $0 == w } }
                            if i < words.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                        }
                    }
                }
            }
        }
    }

    private func add() {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        if !model.serverSettings.dictionary.contains(w) { model.serverSettings.dictionary.insert(w, at: 0) }
        word = ""; adding = false
    }
}

/// .item .wordContainer>p { padding:16px 4px 16px 16px; 15/20 } with hover actions.
private struct WordRow: View {
    let text: String
    var detail: String? = nil
    let delete: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(DS.ui(15)).lineLimit(1)
            if let detail {
                Image(systemName: "arrow.right").font(.system(size: 11)).foregroundColor(DS.foregroundTertiary)
                Text(detail).font(DS.ui(15)).foregroundColor(DS.neutral600).lineLimit(2)
            }
            Spacer()
            IconButton(systemName: "trash", help: "Apagar", action: delete).opacity(hover ? 1 : 0)
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
        .frame(minHeight: 52)
        .background(hover ? DS.backgroundTertiary : Color.clear)
        .onHover { hover = $0 }
    }
}

// MARK: - Snippets

private struct SnippetsPage: View {
    @ObservedObject var model: AppModel
    @State private var adding = false
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var spoken = ""
    @State private var written = ""

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Snippets",
                           description: "Diga um atalho e o RustleApp insere o texto completo. Ótimo para assinaturas, links e respostas que você repete.") {
                    Button("Adicionar") { adding = true }.buttonStyle(PrimaryButtonStyle())
                }
                if adding {
                    VStack(alignment: .leading, spacing: 8) {
                        HubTextField(placeholder: "Atalho falado (ex.: minha assinatura)", text: $trigger)
                        HubTextField(placeholder: "Texto inserido", text: $expansion)
                        HStack {
                            Button("Salvar") {
                                let t = trigger.trimmingCharacters(in: .whitespaces)
                                guard !t.isEmpty, !expansion.isEmpty else { return }
                                model.serverSettings.snippets[t] = expansion
                                trigger = ""; expansion = ""; adding = false
                            }.buttonStyle(PrimaryButtonStyle())
                            Button("Cancelar") { adding = false }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
                pairs(model.serverSettings.snippets, empty: "Nenhum snippet ainda.") { model.serverSettings.snippets[$0] = nil }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Substituições")
                    Text("Troca uma palavra falada pela forma escrita em todo ditado.")
                        .font(DS.ui(15)).foregroundColor(DS.neutral600)
                }
                .padding(.top, 8)
                HStack(spacing: 8) {
                    HubTextField(placeholder: "Falado (ex.: rustle app)", text: $spoken)
                    HubTextField(placeholder: "Escrito (ex.: RustleApp)", text: $written)
                    Button("Adicionar") {
                        let s = spoken.trimmingCharacters(in: .whitespaces)
                        guard !s.isEmpty, !written.isEmpty else { return }
                        model.serverSettings.replacements[s] = written
                        spoken = ""; written = ""
                    }.buttonStyle(SecondaryButtonStyle())
                }
                pairs(model.serverSettings.replacements, empty: "Nenhuma substituição.") { model.serverSettings.replacements[$0] = nil }
            }
        }
    }

    @ViewBuilder
    private func pairs(_ dict: [String: String], empty: String, remove: @escaping (String) -> Void) -> some View {
        let keys = dict.keys.sorted()
        if keys.isEmpty {
            Text(empty).font(DS.ui(15)).foregroundColor(DS.foregroundTertiary)
        } else {
            ListCard {
                ForEach(Array(keys.enumerated()), id: \.element) { i, k in
                    WordRow(text: k, detail: dict[k]) { remove(k) }
                    if i < keys.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                }
            }
        }
    }
}

// MARK: - Style

/// Wispr's Style page structure: tabs per app category, and tone cards
/// (Formal / Casual / very casual / Excited) with a sample message.
private struct StylePage: View {
    @ObservedObject var model: AppModel
    @State private var tab = "personal"

    private let tabs: [(String, String)] = [
        ("personal", "Mensagens pessoais"), ("work", "Mensagens de trabalho"), ("email", "E-mail"), ("other", "Outros"),
    ]
    private let tones: [(id: String, title: String, subtitle: String)] = [
        ("formal", "Formal.", "Maiúsculas + pontuação"),
        ("casual", "Casual", "Maiúsculas + menos pontuação"),
        ("very_casual", "bem casual", "Sem maiúsculas + menos pontuação"),
        ("excited", "Animado!", "Mais exclamações"),
    ]

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Estilo",
                           description: "Escolha o tom do texto conforme o tipo de app em que você está ditando.") { EmptyView() }

                HStack(spacing: 4) {
                    ForEach(tabs, id: \.0) { id, label in
                        Button { tab = id } label: {
                            Text(label)
                                .font(DS.ui(15, tab == id ? DS.w550 : .regular))
                                .foregroundColor(tab == id ? DS.foreground : DS.neutral600)
                                .padding(.horizontal, 12).frame(height: 32)
                                .background(RoundedRectangle(cornerRadius: 8).fill(tab == id ? DS.card : Color.clear))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tab == id ? DS.border : Color.clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.backgroundTertiary))

                Text(appsHint).font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    ForEach(tones, id: \.id) { tone in
                        ToneCard(title: tone.title, subtitle: tone.subtitle, sample: sample(tone.id),
                                 selected: model.serverSettings.styles[tab] == tone.id) {
                            model.serverSettings.styles[tab] = tone.id
                        }
                    }
                }
            }
        }
    }

    private var appsHint: String {
        switch tab {
        case "personal": return "Aplica-se a WhatsApp, Mensagens, Telegram, Discord…"
        case "work": return "Aplica-se a Slack, Teams…"
        case "email": return "Aplica-se a Mail, Outlook, Spark…"
        default: return "Aplica-se aos demais apps."
        }
    }

    private func sample(_ tone: String) -> String {
        let base: String
        switch tab {
        case "work": base = "Oi, se você estiver livre, vamos conversar sobre os ótimos resultados"
        case "email": base = "Oi Ana, foi ótimo falar com você hoje. Até a próxima conversa"
        case "other": base = "Até agora estou gostando da nova rotina de treinos"
        default: base = "Oi, você está livre para almoçar amanhã? Pode ser ao meio-dia"
        }
        switch tone {
        case "formal": return base + "."
        case "casual": return base.replacingOccurrences(of: ",", with: "")
        case "very_casual": return base.lowercased().replacingOccurrences(of: ",", with: "")
        default: return base + "!"
        }
    }
}

private struct ToneCard: View {
    let title: String
    let subtitle: String
    let sample: String
    let selected: Bool
    let pick: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.display(26)).tracking(-1)
                    Text(subtitle).font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                }
                Text(sample)
                    .font(DS.ui(14))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(DS.backgroundTertiary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(selected ? DS.dawn100 : DS.card))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? DS.dawn700 : (hover ? DS.sand700 : DS.border),
                                                               lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Notes (Scratchpad)

private struct NotesPage: View {
    @ObservedObject var model: AppModel
    @State private var selection: UUID?
    @State private var query = ""

    private var notes: [AppModel.Note] {
        (query.isEmpty ? model.notes : model.notes.filter { $0.body.localizedCaseInsensitiveContains(query) })
            .sorted { $0.pinned && !$1.pinned }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    PageTitle(text: "Notas")
                    Spacer()
                    IconButton(systemName: "macwindow.on.rectangle", help: "Abrir o Scratchpad (\(GlobalShortcut.label))") { model.openScratchpad(nil) }
                    IconButton(systemName: "square.and.pencil", help: "Nova nota") { newNote() }
                }
                HubTextField(placeholder: "Buscar nas suas notas", text: $query)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(notes) { note in
                            NoteRow(note: note, selected: selection == note.id) { selection = note.id }
                                .contextMenu { Button("Apagar", role: .destructive) { delete(note.id) } }
                        }
                        if notes.isEmpty {
                            Text("Nenhuma nota encontrada").font(DS.ui(15)).foregroundColor(DS.foregroundTertiary)
                                .padding(.top, 24)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .padding(24)
            .frame(width: 280)

            Rectangle().fill(DS.border).frame(width: 1)

            Group {
                if let i = model.notes.firstIndex(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.notes[i].updated.formatted(date: .abbreviated, time: .shortened))
                                .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                            Spacer()
                            IconButton(systemName: model.notes[i].pinned ? "pin.fill" : "pin", help: model.notes[i].pinned ? "Desafixar" : "Fixar") {
                                model.notes[i].pinned.toggle()
                            }
                            IconButton(systemName: "macwindow.on.rectangle", help: "Abrir no Scratchpad") { model.openScratchpad(model.notes[i].id) }
                            IconButton(systemName: "trash", help: "Apagar nota") { delete(model.notes[i].id) }
                        }
                        TextEditor(text: Binding(
                            get: { model.notes[i].body },
                            set: { model.notes[i].body = $0; model.notes[i].updated = Date() }))
                            .font(DS.ui(16))
                            .scrollContentBackground(.hidden)
                            .lineSpacing(4)
                        Text("Clique no texto e segure fn para ditar direto na nota. Para anotar sem sair do app em uso, abra o Scratchpad com \(GlobalShortcut.label).")
                            .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                    }
                    .padding(.horizontal, 40).padding(.vertical, 32)
                } else {
                    VStack(spacing: 16) {
                        PageTitle(text: "Para pensamentos rápidos que você quer retomar depois", size: 24)
                        Text("Uma lista de tarefas, uma mensagem para revisar antes de enviar, uma ideia solta.\nO Scratchpad é o seu espaço para salvar, criar e explorar.")
                            .font(DS.ui(15)).foregroundColor(DS.neutral600).multilineTextAlignment(.center)
                        HStack(spacing: 8) {
                            Button("Abrir Scratchpad") { model.openScratchpad(nil) }.buttonStyle(PrimaryButtonStyle())
                            Button("Nova nota aqui") { newNote() }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .padding(.horizontal, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = model.notes.first?.id } }
    }

    private func newNote() {
        let n = AppModel.Note()
        model.notes.insert(n, at: 0)
        selection = n.id
        query = ""
    }

    private func delete(_ id: UUID) {
        model.notes.removeAll { $0.id == id }
        if selection == id { selection = model.notes.first?.id }
    }
}

private struct NoteRow: View {
    let note: AppModel.Note
    let selected: Bool
    let select: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if note.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(DS.foregroundTertiary) }
                    Text(note.title).font(DS.ui(15, DS.w550)).lineLimit(1)
                }
                Text(preview).font(DS.ui(13)).foregroundColor(DS.foregroundTertiary).lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? DS.dawn100 : (hover ? DS.backgroundTertiary : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
    private var preview: String {
        let rest = note.body.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        return rest.isEmpty ? note.updated.formatted(date: .abbreviated, time: .omitted) : rest
    }
}

// MARK: - Settings

/// .container { padding:48px; gap:36px } .section { gap:16px } .card { padding:20; radius:12; tertiary }
/// rows: label 15/550 + description neutral-600, controls 164 px.
/// Paste-and-save field for one provider's API key (stored in the Keychain).
private struct APIKeyField: View {
    let title: String
    let placeholder: String
    @Binding var key: String
    @Binding var saved: Bool
    let save: () -> Bool
    let onSaved: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(DS.ui(15, DS.w550))
            HStack(spacing: 8) {
                SecureField("", text: $key, prompt: Text(placeholder).foregroundColor(DS.vast500))
                    .textFieldStyle(.plain).font(DS.ui(15))
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DS.card))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.border, lineWidth: 1))
                    .onChange(of: key) { _ in saved = false }
                Button(saved ? "Salva ✓" : "Salvar") {
                    saved = save()
                    onSaved()
                }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

private struct SettingsPage: View {
    @ObservedObject var model: AppModel
    @AppStorage(Prefs.hotkey) private var hotkey = "fn"
    @AppStorage(Prefs.language) private var language = "pt"
    @AppStorage(Prefs.whisperModel) private var whisperModel = "small"
    @AppStorage(Prefs.meetingWhisperModel) private var meetingWhisperModel = "large-v3-turbo"
    @AppStorage(Prefs.scratchpadOpenBehavior) private var scratchpadOpen = "resume"
    @State private var apiKey = Keychain.readAPIKey() ?? ""
    @State private var keySaved = false
    @State private var deepseekKey = Keychain.readAPIKey(Keychain.deepseek) ?? ""
    @State private var deepseekSaved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 12) {
                    PageTitle(text: "Configurações")
                    Text("Atalhos, idioma, modelo de transcrição e permissões.")
                        .font(DS.ui(15)).foregroundColor(DS.neutral600)
                }

                SettingsSection(title: "Perfil") {
                    SettingsCard {
                        SettingsRow(label: "Nome", description: "Aparece na tela de início (“Bem-vindo de volta, …”).") {
                            ProfileField(placeholder: "Nome", text: $model.firstName)
                        }
                        SettingsRow(label: "Sobrenome", description: "Opcional.") {
                            ProfileField(placeholder: "Sobrenome", text: $model.lastName)
                        }
                        SettingsRow(label: "Questionário inicial", description: "Refaça as perguntas da primeira abertura: nome, idioma, atalho, estilo e permissões.") {
                            Button("Refazer") { UserDefaults.standard.set(false, forKey: Prefs.onboardingDone) }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }

                SettingsSection(title: "Geral") {
                    SettingsCard {
                        SettingsRow(label: "Atalho de ditado", description: "Segure para ditar e solte para colar. Com fn, defina em Ajustes → Teclado “Pressionar a tecla 🌐 para: Não Fazer Nada”.") {
                            Picker("", selection: $hotkey) {
                                Text("fn").tag("fn")
                                Text("Option direito").tag("right_option")
                                Text("Command direito").tag("right_command")
                            }
                            .labelsHidden()
                            .onChange(of: hotkey) { _ in model.hotkeyChanged() }
                        }
                        SettingsRow(label: "Idioma", description: "Idioma em que você costuma falar.") {
                            Picker("", selection: $language) {
                                Text("Português").tag("pt")
                                Text("Inglês").tag("en")
                                Text("Automático").tag("auto")
                            }.labelsHidden()
                        }
                    }
                }

                SettingsSection(title: "Scratchpad") {
                    SettingsCard {
                        SettingsRow(label: "Abrir o Scratchpad", description: "Atalho global; também no menu da barra de status. Se uma colagem falhar, o texto ditado abre no Scratchpad.") {
                            HStack(spacing: 8) {
                                Text(GlobalShortcut.label).font(DS.ui(14, .semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(DS.card))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.border, lineWidth: 1))
                                Button("Abrir") { model.openScratchpad(nil) }.buttonStyle(SecondaryButtonStyle())
                            }
                        }
                        SettingsRow(label: "Ao abrir o Scratchpad", description: "Escolha o que acontece quando você abre o Scratchpad.") {
                            Picker("", selection: $scratchpadOpen) {
                                Text("Retomar última nota").tag("resume")
                                Text("Abrir em nova aba").tag("new_tab")
                                Text("Última nota fixada").tag("last_pinned")
                            }.labelsHidden()
                        }
                    }
                }

                SettingsSection(title: "Transcrição") {
                    SettingsCard {
                        SettingsRow(label: "Modelo Whisper (local)", description: "Roda no seu Mac; o áudio não sai do computador. Trocar exige reiniciar o servidor.") {
                            Picker("", selection: $whisperModel) {
                                Text("base (rápido)").tag("base")
                                Text("small (recomendado)").tag("small")
                                Text("medium (preciso)").tag("medium")
                                Text("large-v3-turbo (melhor em português)").tag("large-v3-turbo")
                            }.labelsHidden()
                        }
                        SettingsRow(label: "Modelo das reuniões (Notetaker)", description: "As reuniões rodam em segundo plano, então podem usar um modelo maior e mais preciso. O turbo baixa ~1,6 GB na primeira vez. Trocar exige reiniciar o servidor.") {
                            Picker("", selection: $meetingWhisperModel) {
                                Text("Igual ao ditado").tag("")
                                Text("medium").tag("medium")
                                Text("large-v3-turbo (recomendado)").tag("large-v3-turbo")
                            }.labelsHidden()
                        }
                        SettingsRow(label: "Servidor de transcrição", description: serverDescription) {
                            Button("Reiniciar") { model.restartServer() }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }

                SettingsSection(title: "Polimento com IA") {
                    SettingsCard {
                        SettingsRow(label: "Reescrever ditados com IA", description: "Remove hesitações e autocorreções e ajusta o tom ao app em uso. Opcional; sem chave, usa só regras locais.") {
                            Toggle("", isOn: $model.serverSettings.use_claude).toggleStyle(.switch).labelsHidden()
                        }
                        SettingsRow(label: "Provedor de IA", description: "Usado no polimento, resumos de reuniões, perguntas e Scratchpad. Se faltar a chave dele, usa o outro.") {
                            Picker("", selection: $model.serverSettings.ai_provider) {
                                Text("Claude").tag("claude")
                                Text("DeepSeek").tag("deepseek")
                            }.labelsHidden()
                        }
                        APIKeyField(title: "Chave da API Anthropic", placeholder: "sk-ant-…", key: $apiKey, saved: $keySaved) {
                            Keychain.saveAPIKey(apiKey, account: Keychain.anthropic)
                        } onSaved: { model.restartServer() }
                        APIKeyField(title: "Chave da API DeepSeek", placeholder: "sk-…", key: $deepseekKey, saved: $deepseekSaved) {
                            Keychain.saveAPIKey(deepseekKey, account: Keychain.deepseek)
                        } onSaved: { model.restartServer() }
                        Text("Guardadas no Chaveiro do macOS. Deixe vazio e salve para remover.")
                            .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                    }
                }

                SettingsSection(title: "Permissões") {
                    SettingsCard {
                        PermissionRow(label: "Acessibilidade", description: "Detecta o fn em qualquer app e cola o texto.", ok: model.permissions.accessibility, pane: "Privacy_Accessibility")
                        PermissionRow(label: "Microfone", description: "Grava sua voz enquanto você segura o atalho.", ok: model.permissions.microphone, pane: "Privacy_Microphone")
                        PermissionRow(label: "Gravação de áudio do sistema", description: model.systemAudioError.map { "Notetaker: \($0)." } ?? "Notetaker: grava o som da chamada (os outros participantes). O macOS pede na primeira gravação.", ok: model.systemAudioError == nil, pane: "Privacy_AudioCapture", optional: true)
                        PermissionRow(label: "Monitoramento de Entrada", description: "Opcional: detecção extra do atalho.", ok: model.permissions.inputMonitoring, pane: "Privacy_ListenEvent", optional: true)
                        HStack(spacing: 8) {
                            Button("Reparar permissões") { model.repairPermissions() }.buttonStyle(SecondaryButtonStyle())
                            Button("Reiniciar app") { model.relaunch() }.buttonStyle(SecondaryButtonStyle())
                            Button("Testar colagem") { model.testPaste() }.buttonStyle(SecondaryButtonStyle())
                            Spacer()
                            Button("Abrir log") { NSWorkspace.shared.open(Log.url) }.buttonStyle(.link)
                        }
                    }
                }
            }
            .padding(48)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    private var serverDescription: String {
        switch model.serverState {
        case .online: return "Online em 127.0.0.1:8765."
        case .starting: return "Iniciando e carregando o modelo…"
        case .offline(let msg): return msg
        }
    }
}

private struct ProfileField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(DS.vast500))
            .textFieldStyle(.plain).font(DS.ui(15))
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.border, lineWidth: 1))
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(DS.ui(15, .semibold))
            content
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let label: String
    let description: String
    @ViewBuilder var control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(DS.ui(15, DS.w550))
                Text(description).font(DS.ui(15)).foregroundColor(DS.neutral600)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control.frame(width: 164, alignment: .trailing)
        }
    }
}

private struct PermissionRow: View {
    let label: String
    let description: String
    let ok: Bool
    let pane: String
    var optional = false
    var body: some View {
        SettingsRow(label: label, description: description) {
            if ok {
                Label("Concedida", systemImage: "checkmark.circle.fill")
                    .font(DS.ui(14, .medium)).foregroundColor(DS.success500)
            } else {
                Button(optional ? "Ativar" : "Conceder") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}
