import AppKit
import SwiftUI

/// Notetaker, rebuilt from Wispr Flow's hub (strings and CSS modules recovered with REA):
///  - list: "New note" CTA, meetings grouped by day, live recording card, "meeting detected" banner;
///  - meeting page: title, meta, section pills (My Notes / Summary / Action Items), notepad,
///    Enhanced Summary, Action Items with owner name pills (.namePill: black, h25, radius 30);
///  - floating footer (.meetingFooter / .pill radius 32, elevated shadow) with the live waveform,
///    the "Ask anything" composer and a drawer with Transcript / Chat tabs.
struct NotetakerPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let id = model.openMeetingID, model.meeting(id) != nil {
            MeetingPage(model: model, id: id) { model.openMeetingID = nil }
                .id(id)
        } else {
            MeetingList(model: model)
        }
    }
}

// MARK: - List

private struct MeetingList: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var searching = false

    private var groups: [(String, [Meeting])] {
        let items = query.isEmpty ? model.meetings : model.meetings.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || $0.userNotes.localizedCaseInsensitiveContains(query)
                || $0.segments.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
        let cal = Calendar.current
        var order: [String] = []
        var map: [String: [Meeting]] = [:]
        for m in items {
            let key = cal.isDateInToday(m.started) ? "Hoje" : cal.isDateInYesterday(m.started) ? "Ontem"
                : m.started.formatted(.dateTime.weekday(.wide).day().month(.wide))
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(m)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        PageTitle(text: "Notetaker")
                        Text("Transcrição, resumo e itens de ação para cada reunião.")
                            .font(DS.ui(15)).foregroundColor(DS.neutral600)
                    }
                    Spacer(minLength: 24)
                    Button {
                        if let id = model.startMeeting(nil) { model.openMeetingID = id }
                    } label: {
                        Label(model.activeMeetingID == nil ? "Nova nota" : "Gravando…", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.activeMeetingID != nil)
                    .help("Nova nota — abre o bloco de notas e inicia o Notetaker")
                }

                if let id = model.activeMeetingID, let m = model.meeting(id) {
                    LiveMeetingCard(model: model, meeting: m)
                } else if let app = model.detectedMeetingApp {
                    DetectedBanner(app: app) {
                        if let id = model.startMeeting(app) { model.openMeetingID = id }
                    }
                }

                if model.meetings.isEmpty {
                    NotetakerEmpty { if let id = model.startMeeting(nil) { model.openMeetingID = id } }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            if searching {
                                HubTextField(placeholder: "Buscar reuniões e notas", text: $query).frame(maxWidth: 320)
                            } else {
                                SectionLabel(text: "Notas")
                            }
                            Spacer()
                            IconButton(systemName: searching ? "xmark" : "magnifyingglass", help: "Buscar reuniões") {
                                searching.toggle(); if !searching { query = "" }
                            }
                        }
                        .padding(.bottom, 8)
                        if groups.isEmpty {
                            Text("Nenhuma reunião encontrada.").font(DS.ui(15)).foregroundColor(DS.foregroundTertiary)
                                .frame(maxWidth: .infinity).padding(.vertical, 24)
                        }
                        ForEach(groups, id: \.0) { title, items in
                            SectionLabel(text: title).padding(.top, 16).padding(.bottom, 8)
                            ListCard {
                                ForEach(Array(items.enumerated()), id: \.element.id) { i, m in
                                    MeetingRow(model: model, meeting: m)
                                    if i < items.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                                }
                            }
                            .padding(.bottom, 8)
                        }
                    }
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }
}

private struct MeetingRow: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    @State private var hover = false
    @State private var confirmDelete = false

    var body: some View {
        Button { model.openMeetingID = meeting.id } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundColor(DS.foregroundTertiary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DS.backgroundTertiary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.displayTitle).font(DS.ui(15, DS.w550)).foregroundColor(DS.foreground).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(meeting.started.formatted(date: .omitted, time: .shortened))
                        Text("•")
                        Text(meeting.durationLabel)
                        if let app = meeting.appName { Text("•"); Text(app) }
                    }
                    .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                }
                Spacer(minLength: 8)
                MeetingStatusChip(model: model, meeting: meeting)
                IconButton(systemName: "trash", help: "Apagar") { confirmDelete = true }
                    .opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(hover ? DS.backgroundTertiary : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .confirmationDialog("Apagar esta reunião?", isPresented: $confirmDelete) {
            Button("Apagar", role: .destructive) { model.meetings.removeAll { $0.id == meeting.id } }
        } message: { Text("A transcrição, o resumo e suas notas serão apagados.") }
    }
}

private struct MeetingStatusChip: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    var body: some View {
        Group {
            if model.activeMeetingID == meeting.id {
                HStack(spacing: 6) { RecordingDot(); Text("Gravando") }
                    .foregroundColor(DS.destructive500)
            } else if meeting.status == .processing || model.busyMeetingIDs.contains(meeting.id) && meeting.summary.isEmpty {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Gerando resumo") }
                    .foregroundColor(DS.foregroundTertiary)
            } else if !meeting.actionItems.isEmpty {
                let open = meeting.actionItems.filter { !$0.done }.count
                Text(open == 0 ? "Tudo feito" : "\(open) \(open == 1 ? "item" : "itens") de ação")
                    .foregroundColor(DS.neutral600)
            }
        }
        .font(DS.ui(12, DS.w550))
    }
}

/// Dark "live" card, same treatment as the Home hotkey card (vast-950 background).
private struct LiveMeetingCard: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    var body: some View {
        HStack(spacing: 16) {
            LiveWaveform(levels: model.meetingLevels)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.displayTitle).font(DS.ui(15, DS.w550)).foregroundColor(DS.sand50).lineLimit(1)
                ElapsedLabel(levels: model.meetingLevels, prefix: "Gravando · ")
                    .font(DS.ui(13)).foregroundColor(DS.vast300)
            }
            Spacer()
            Button("Abrir") { model.openMeetingID = meeting.id }
                .buttonStyle(DarkButtonStyle(filled: false))
            Button { model.stopMeeting() } label: { Label("Parar", systemImage: "stop.fill") }
                .buttonStyle(DarkButtonStyle(filled: true))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(DS.vast950))
    }
}

private struct DetectedBanner: View {
    let app: String
    let start: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "video.fill").foregroundColor(DS.dawn700)
                .frame(width: 32, height: 32)
                .background(Circle().fill(DS.dawn400))
            VStack(alignment: .leading, spacing: 2) {
                Text("Reunião detectada").font(DS.ui(15, DS.w550))
                Text("Uma chamada começou no \(app). Quer que o Notetaker faça as anotações?")
                    .font(DS.ui(13)).foregroundColor(DS.neutral600)
            }
            Spacer()
            Button("Iniciar Notetaker", action: start).buttonStyle(PrimaryButtonStyle())
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(DS.dawn100))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(DS.dawn400, lineWidth: 1))
    }
}

/// Wispr's empty state: "Capture meetings with Notetaker" + the hero feature labels.
private struct NotetakerEmpty: View {
    let start: () -> Void
    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                PageTitle(text: "Capture reuniões com o Notetaker", size: 26)
                Text("Nunca perca um detalhe: transcrições precisas, resumos e itens de ação.")
                    .font(DS.ui(15)).foregroundColor(DS.neutral600)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Feature(icon: "text.bubble", title: "Transcrição ao vivo", detail: "Você e os outros, separados por voz.")
                Feature(icon: "sparkles", title: "Resumos aprimorados", detail: "Decisões e próximos passos ao final.")
                Feature(icon: "questionmark.bubble", title: "Pergunte qualquer coisa", detail: "“O que eu perdi?”, e-mail de follow-up…")
            }
            Button("Começar", action: start).buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40).padding(.horizontal, 24)
        .background(RoundedRectangle(cornerRadius: 16).fill(DS.backgroundTertiary))
    }

    private struct Feature: View {
        let icon: String
        let title: String
        let detail: String
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.system(size: 16)).foregroundColor(DS.dawn700)
                Text(title).font(DS.ui(15, DS.w550))
                Text(detail).font(DS.ui(13)).foregroundColor(DS.neutral600)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(DS.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.border, lineWidth: 1))
        }
    }
}

// MARK: - Meeting page

private enum MeetingSection: String, CaseIterable { case notes, summary, transcript, actions
    var title: String {
        switch self {
        case .notes: return "Minhas notas"; case .summary: return "Resumo"
        case .transcript: return "Transcrição"; case .actions: return "Itens de ação"
        }
    }
    var icon: String {
        switch self {
        case .notes: return "pencil.line"; case .summary: return "sparkles"
        case .transcript: return "text.bubble"; case .actions: return "checklist"
        }
    }
}

private struct MeetingPage: View {
    @ObservedObject var model: AppModel
    let id: UUID
    let back: () -> Void
    @State private var drawerOpen = false
    @State private var drawerTab: DrawerTab = .transcript

    private var meeting: Meeting { model.meeting(id) ?? Meeting() }
    private var isLive: Bool { model.activeMeetingID == id }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                MeetingTopBar(model: model, meeting: meeting, back: back)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            header(proxy: proxy)
                            NotepadSection(model: model, id: id).id(MeetingSection.notes)
                            SummarySection(model: model, id: id, isLive: isLive).id(MeetingSection.summary)
                            TranscriptSection(model: model, id: id, meeting: meeting, isLive: isLive).id(MeetingSection.transcript)
                            ActionItemsSection(model: model, id: id).id(MeetingSection.actions)
                        }
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(.horizontal, 40).padding(.top, 12)
                        .padding(.bottom, drawerOpen ? 460 : 140)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.never)
                }
            }
            MeetingFooter(model: model, id: id, isLive: isLive, drawerOpen: $drawerOpen, tab: $drawerTab)
                .padding(.bottom, 16)
        }
    }

    @ViewBuilder private func header(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("", text: Binding(get: { meeting.title }, set: { v in model.updateMeeting(id) { $0.title = v } }),
                      prompt: Text(meeting.displayTitle).foregroundColor(DS.sand700), axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.display(34)).tracking(-0.04 * 34)
                .foregroundColor(DS.foreground)
            HStack(spacing: 8) {
                MetaChip(icon: "calendar", text: meeting.started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                if isLive {
                    HStack(spacing: 6) { RecordingDot(); ElapsedLabel(levels: model.meetingLevels, prefix: "") }
                        .font(DS.ui(13, DS.w550)).foregroundColor(DS.destructive500)
                        .padding(.horizontal, 8).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xFDECEC)))
                } else {
                    MetaChip(icon: "clock", text: meeting.durationLabel)
                }
                if let app = meeting.appName { MetaChip(icon: "video", text: app) }
                MetaChip(icon: "person.2", text: speakersLabel)
            }
            // .pills row: "Meeting sections" (hub_meeting_pill_row_aria)
            HStack(spacing: 8) {
                ForEach(MeetingSection.allCases, id: \.self) { s in
                    SectionPill(icon: s.icon, title: s.title) {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(s, anchor: .top) }
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private var speakersLabel: String {
        let speakers = Set(meeting.segments.map(\.speaker))
        let you = meeting.name(of: .you), them = meeting.name(of: .them)
        if speakers.count == 2 { return them == Meeting.Speaker.them.label ? "\(you) e outros" : "\(you) e \(them)" }
        return speakers.contains(.them) ? them : you
    }
}

private struct MeetingTopBar: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    let back: () -> Void
    @State private var copied = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Todas as notas").font(DS.ui(14, DS.w550))
                }
                .foregroundColor(DS.neutral600)
                .padding(.horizontal, 8).frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            IconButton(systemName: copied ? "checkmark" : "doc.on.doc", help: "Copiar notas") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            IconButton(systemName: "trash", help: "Apagar reunião") { confirmDelete = true }
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)
        .confirmationDialog("Apagar esta reunião?", isPresented: $confirmDelete) {
            Button("Apagar", role: .destructive) {
                if model.activeMeetingID == meeting.id { model.stopMeeting() }
                let id = meeting.id
                back()
                model.meetings.removeAll { $0.id == id }
            }
        }
    }

    /// Notes as Markdown for pasting into a doc or email.
    private var markdown: String {
        var out = "# \(meeting.displayTitle)\n\n"
        if !meeting.userNotes.isEmpty { out += "## Minhas notas\n\(meeting.userNotes)\n\n" }
        for s in meeting.summary {
            out += "## \(s.heading)\n" + s.bullets.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !meeting.actionItems.isEmpty {
            out += "## Itens de ação\n" + meeting.actionItems.map {
                "- [\($0.done ? "x" : " ")] \($0.text)\($0.owner.isEmpty ? "" : " (\($0.owner))")"
            }.joined(separator: "\n") + "\n\n"
        }
        if !meeting.segments.isEmpty { out += "## Transcrição\n" + meeting.transcriptText + "\n" }
        return out
    }
}

private struct MetaChip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(DS.ui(13))
        }
        .foregroundColor(DS.vast700)
        .padding(.horizontal, 8).frame(height: 26)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.border, lineWidth: 1))
    }
}

/// .inBarPill: height 26, padding 0 8, radius 9999, 1 px border, 12/20 w550.
private struct SectionPill: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(title).font(DS.ui(12, DS.w550))
            }
            .foregroundColor(DS.foreground)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(hover ? DS.neutral200 : DS.background))
            .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct SectionHeading: View {
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(title).font(DS.ui(20, .semibold)).foregroundColor(DS.foreground)
            Spacer()
            if let trailing { trailing }
        }
    }
}

private struct NotepadSection: View {
    @ObservedObject var model: AppModel
    let id: UUID
    var body: some View {
        let text = Binding(get: { model.meeting(id)?.userNotes ?? "" },
                           set: { v in model.updateMeeting(id) { $0.userNotes = v } })
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Minhas notas")
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text("Escreva notas… o que você anotar aqui ganha prioridade no resumo.")
                        .font(DS.ui(16)).foregroundColor(DS.sand700)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(DS.ui(16))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 7).padding(.vertical, 10)
                    .frame(minHeight: 120)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(DS.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.border, lineWidth: 1))
        }
    }
}

private struct SummarySection: View {
    @ObservedObject var model: AppModel
    let id: UUID
    let isLive: Bool
    @State private var copied = false

    var body: some View {
        let m = model.meeting(id) ?? Meeting()
        let busy = model.busyMeetingIDs.contains(id) || m.status == .processing
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Resumo aprimorado", trailing: m.summary.isEmpty ? nil : AnyView(
                HStack(spacing: 4) {
                    if !busy && !isLive {
                        Button("Atualizar resumo") { model.generateNotes(id) }.buttonStyle(.link).font(DS.ui(13))
                    }
                    IconButton(systemName: copied ? "checkmark" : "doc.on.doc", help: "Copiar resumo") {
                        let text = m.summary.map { "\($0.heading)\n" + $0.bullets.map { "• \($0)" }.joined(separator: "\n") }
                            .joined(separator: "\n\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                }))

            if isLive {
                InfoCard(icon: "ear", title: "Ainda estamos ouvindo",
                         text: "Quando a reunião terminar, transformamos a transcrição em resumo e itens de ação.")
            } else if busy && m.summary.isEmpty {
                GeneratingCard()
            } else if m.summary.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(m.segments.isEmpty && m.userNotes.isEmpty
                         ? "Sem transcrição ou áudio para resumir."
                         : "A reunião foi curta demais para resumir.")
                        .font(DS.ui(15)).foregroundColor(DS.neutral600)
                    Button("Gerar resumo") { model.generateNotes(id) }.buttonStyle(SecondaryButtonStyle())
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(m.summary.enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(s.heading).font(DS.ui(16, .semibold))
                            ForEach(Array(s.bullets.enumerated()), id: \.offset) { _, b in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Circle().fill(DS.vast500).frame(width: 4, height: 4).offset(y: -3)
                                    Text(b).font(DS.ui(15)).lineSpacing(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    Text(m.summaryEngine == "claude" ? "Gerado com Claude"
                         : m.summaryEngine == "deepseek" ? "Gerado com DeepSeek"
                         : "Resumo local (sem IA) · adicione a chave do Claude ou do DeepSeek em Configurações para resumos completos")
                        .font(DS.ui(12)).foregroundColor(DS.foregroundTertiary)
                }
                .opacity(busy ? 0.5 : 1)
            }
        }
    }
}

/// The full transcript inline on the page, so it is visible without opening the drawer.
/// Scrolls inside its card so a long meeting does not push the action items far down.
private struct TranscriptSection: View {
    @ObservedObject var model: AppModel
    let id: UUID
    let meeting: Meeting
    let isLive: Bool
    @State private var copied = false
    @State private var renaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Transcrição", trailing: meeting.segments.isEmpty ? nil : AnyView(
                HStack(spacing: 4) {
                    Text("\(meeting.segments.count) falas").font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                    IconButton(systemName: "person.2", help: "Nomes de quem fala") { renaming = true }
                        .popover(isPresented: $renaming, arrowEdge: .bottom) {
                            SpeakerNamesEditor(model: model, id: id, meeting: meeting)
                        }
                    IconButton(systemName: copied ? "checkmark" : "doc.on.doc", help: "Copiar transcrição") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(meeting.transcriptText, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                }))
            if let suggestion = meeting.suggestedOtherName {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundColor(DS.chord600)
                    (Text("Quem fala no áudio do computador parece ser ") + Text(suggestion).bold() + Text("."))
                        .font(DS.ui(14))
                    Spacer()
                    Button("Usar") { model.updateMeeting(id) { $0.setName(suggestion, for: .them) } }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Editar") { renaming = true }.buttonStyle(SecondaryButtonStyle())
                    IconButton(systemName: "xmark", help: "Dispensar") { model.updateMeeting(id) { $0.suggestedOtherName = nil } }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.card))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border, lineWidth: 1))
            }
            TranscriptView(meeting: meeting, isLive: isLive, query: "")
                .frame(height: meeting.segments.count > 8 ? 460 : 220)
                .background(RoundedRectangle(cornerRadius: 12).fill(DS.card))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.border, lineWidth: 1))
        }
    }
}

/// Renames the two sides of the transcript: the mic (the user) and the computer audio.
private struct SpeakerNamesEditor: View {
    @ObservedObject var model: AppModel
    let id: UUID
    @State private var you: String
    @State private var them: String

    init(model: AppModel, id: UUID, meeting: Meeting) {
        self.model = model
        self.id = id
        let name = { (s: Meeting.Speaker) in meeting.name(of: s) == s.label ? "" : meeting.name(of: s) }
        _you = State(initialValue: name(.you))
        _them = State(initialValue: name(.them).isEmpty ? (meeting.suggestedOtherName ?? "") : name(.them))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nomes na transcrição").font(DS.ui(15, DS.w550))
            field("Seu microfone", placeholder: "Você", text: $you)
            field("Áudio do computador", placeholder: "Outros", text: $them)
            Text("Com várias pessoas na chamada, todas aparecem com o nome do áudio do computador.")
                .font(DS.ui(12)).foregroundColor(DS.foregroundTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Salvar") {
                    model.updateMeeting(id) { m in
                        m.setName(you, for: .you)
                        m.setName(them, for: .them)
                    }
                }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(DS.ui(12)).foregroundColor(DS.foregroundTertiary)
            TextField("", text: text, prompt: Text(placeholder))
                .textFieldStyle(.plain).font(DS.ui(14))
                .padding(.horizontal, 10).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.card))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.border, lineWidth: 1))
        }
    }
}

private struct InfoCard: View {
    let icon: String
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundColor(DS.dawn700)
                .frame(width: 30, height: 30).background(Circle().fill(DS.dawn400))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(DS.ui(15, DS.w550))
                Text(text).font(DS.ui(14)).foregroundColor(DS.neutral600).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.dawn100))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.dawn400, lineWidth: 1))
    }
}

/// "Generating Summary..." with the Flow bar's rainbow shimmer.
private struct GeneratingCard: View {
    @State private var phase: CGFloat = -1
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gerando resumo…").font(DS.ui(15, DS.w550))
                .overlay(
                    LinearGradient(colors: DS.rainbow, startPoint: .leading, endPoint: .trailing)
                        .mask(Text("Gerando resumo…").font(DS.ui(15, DS.w550)))
                        .opacity(0.9)
                )
            ForEach([0.92, 0.75, 0.84, 0.5], id: \.self) { w in
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [DS.sand600, DS.sand500, DS.sand600],
                                             startPoint: UnitPoint(x: phase, y: 0), endPoint: UnitPoint(x: phase + 1, y: 0)))
                        .frame(width: geo.size.width * w, height: 12)
                }
                .frame(height: 12)
            }
        }
        .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}

private struct ActionItemsSection: View {
    @ObservedObject var model: AppModel
    let id: UUID
    @State private var newItem = ""
    @State private var adding = false

    var body: some View {
        let m = model.meeting(id) ?? Meeting()
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Itens de ação", trailing: m.actionItems.contains { !$0.done } ? AnyView(
                Button("Marcar todos como concluídos") {
                    model.updateMeeting(id) { mm in for i in mm.actionItems.indices { mm.actionItems[i].done = true } }
                }.buttonStyle(.link).font(DS.ui(13))) : nil)
            if m.actionItems.isEmpty && !adding {
                Text(m.status == .ready && model.activeMeetingID != id
                     ? "Nenhum item de ação restante para esta reunião."
                     : "Os itens de ação aparecem quando a reunião termina.")
                    .font(DS.ui(15)).foregroundColor(DS.neutral600)
            }
            if !m.actionItems.isEmpty {
                ListCard {
                    ForEach(Array(m.actionItems.enumerated()), id: \.element.id) { i, item in
                        ActionItemRow(item: item,
                                      toggle: { model.updateMeeting(id) { $0.actionItems[i].done.toggle() } },
                                      delete: { model.updateMeeting(id) { $0.actionItems.removeAll { $0.id == item.id } } })
                        if i < m.actionItems.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                    }
                }
            }
            if adding {
                HStack(spacing: 8) {
                    HubTextField(placeholder: "Novo item de ação", text: $newItem) { commit() }
                    Button("Adicionar") { commit() }.buttonStyle(PrimaryButtonStyle())
                    Button("Cancelar") { adding = false; newItem = "" }.buttonStyle(SecondaryButtonStyle())
                }
            } else {
                Button { adding = true } label: {
                    Label("Adicionar item de ação", systemImage: "plus").font(DS.ui(14, DS.w550))
                }
                .buttonStyle(.plain).foregroundColor(DS.neutral600)
            }
        }
    }

    private func commit() {
        let text = newItem.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { model.updateMeeting(id) { $0.actionItems.append(.init(text: text)) } }
        newItem = ""
        adding = false
    }
}

private struct ActionItemRow: View {
    let item: Meeting.ActionItem
    let toggle: () -> Void
    let delete: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(item.done ? DS.success500 : DS.vast300)
            }
            .buttonStyle(.plain)
            Text(item.text).font(DS.ui(15))
                .strikethrough(item.done, color: DS.vast500)
                .foregroundColor(item.done ? DS.foregroundTertiary : DS.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !item.owner.isEmpty {
                // .namePill { height:25px; padding:0 10px; background:shade-black; color:white; radius:30px; 12/20 w600 }
                Text(item.owner).font(DS.ui(12, .semibold)).foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 10).frame(height: 25)
                    .frame(maxWidth: 232)
                    .background(Capsule().fill(Color.black))
                    .fixedSize()
            }
            IconButton(systemName: "xmark", help: "Remover", action: delete).opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(hover ? DS.backgroundTertiary : Color.clear)
        .onHover { hover = $0 }
    }
}

// MARK: - Floating footer + drawer

private enum DrawerTab { case transcript, chat }

private struct MeetingFooter: View {
    @ObservedObject var model: AppModel
    let id: UUID
    let isLive: Bool
    @Binding var drawerOpen: Bool
    @Binding var tab: DrawerTab
    @State private var question = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if drawerOpen {
                MeetingDrawer(model: model, id: id, isLive: isLive, tab: $tab, ask: send) {
                    withAnimation(.easeOut(duration: 0.2)) { drawerOpen = false }
                }
                .frame(height: 360)
                Rectangle().fill(DS.border).frame(height: 1)
            }
            HStack(spacing: 8) {
                if isLive {
                    Button { model.stopMeeting() } label: {
                        HStack(spacing: 8) {
                            LiveWaveform(levels: model.meetingLevels, compact: true)
                            RoundedRectangle(cornerRadius: 2).fill(DS.vast950).frame(width: 8, height: 8)
                                .frame(width: 20, height: 20).background(Circle().fill(DS.sand50))
                        }
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(Capsule().fill(Color.black))
                        .overlay(Capsule().strokeBorder(DS.vast900, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Parar o Notetaker")
                } else if model.activeMeetingID == nil {
                    Button { if model.startMeeting(model.meeting(id)?.appName) != nil { model.openMeetingID = model.activeMeetingID } } label: {
                        HStack(spacing: 6) { Circle().fill(DS.destructive500).frame(width: 8, height: 8); Text("Nova gravação").font(DS.ui(13, DS.w550)) }
                            .foregroundColor(DS.sand50)
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(Capsule().fill(Color.black))
                    }
                    .buttonStyle(.plain)
                    .help("Inicia uma nova nota com o Notetaker")
                }
                TextField("", text: $question, prompt: Text("Pergunte qualquer coisa").foregroundColor(DS.vast500))
                    .textFieldStyle(.plain)
                    .font(DS.ui(15))
                    .focused($composerFocused)
                    .onSubmit { send(question) }
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 6)
                if !question.isEmpty {
                    Button { send(question) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundColor(DS.sand50)
                            .frame(width: 28, height: 28).background(Circle().fill(DS.vast950))
                    }
                    .buttonStyle(.plain)
                }
                FooterToggle(icon: "text.bubble", label: "Transcrição", active: drawerOpen && tab == .transcript) {
                    toggle(.transcript)
                }
                FooterToggle(icon: "bubble.left.and.text.bubble.right", label: "Chat", active: drawerOpen && tab == .chat) {
                    toggle(.chat)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: drawerOpen ? 20 : 32).fill(DS.background))
        .clipShape(RoundedRectangle(cornerRadius: drawerOpen ? 20 : 32))
        // .pillElevated { box-shadow: 0 0 0 1px neutral-200, 0 4px 16px rgba(0,0,0,.1), 0 1px 4px rgba(0,0,0,.06) }
        .overlay(RoundedRectangle(cornerRadius: drawerOpen ? 20 : 32).strokeBorder(DS.neutral200, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .frame(maxWidth: 600)
        .padding(.horizontal, 24)
        .animation(.easeOut(duration: 0.2), value: drawerOpen)
    }

    private func toggle(_ t: DrawerTab) {
        withAnimation(.easeOut(duration: 0.2)) {
            if drawerOpen && tab == t { drawerOpen = false } else { tab = t; drawerOpen = true }
        }
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        model.askMeeting(id, q)
        question = ""
        withAnimation(.easeOut(duration: 0.2)) { tab = .chat; drawerOpen = true }
    }
}

private struct FooterToggle: View {
    let icon: String
    let label: String
    let active: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium))
                .foregroundColor(active ? DS.foreground : DS.neutral600)
                .frame(width: 36, height: 36)
                .background(Circle().fill(active || hover ? DS.neutral200 : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
    }
}

private struct MeetingDrawer: View {
    @ObservedObject var model: AppModel
    let id: UUID
    let isLive: Bool
    @Binding var tab: DrawerTab
    let ask: (String) -> Void
    let minimize: () -> Void
    @State private var searching = false
    @State private var query = ""
    @State private var copied = false

    var body: some View {
        let m = model.meeting(id) ?? Meeting()
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                DrawerTabButton(title: "Transcrição", active: tab == .transcript) { tab = .transcript }
                DrawerTabButton(title: "Chat", active: tab == .chat) { tab = .chat }
                Spacer()
                if tab == .transcript {
                    if searching {
                        TextField("", text: $query, prompt: Text("Buscar na transcrição…").foregroundColor(DS.vast500))
                            .textFieldStyle(.plain).font(DS.ui(13)).frame(width: 170)
                    }
                    IconButton(systemName: searching ? "xmark" : "magnifyingglass", help: "Buscar na transcrição") {
                        searching.toggle(); if !searching { query = "" }
                    }
                    IconButton(systemName: copied ? "checkmark" : "doc.on.doc", help: "Copiar transcrição") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(m.transcriptText, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                }
                IconButton(systemName: "chevron.down", help: "Minimizar", action: minimize)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            switch tab {
            case .transcript: TranscriptView(meeting: m, isLive: isLive, query: query)
            case .chat: ChatView(meeting: m, busy: model.busyMeetingIDs.contains(id), ask: ask)
            }
        }
    }
}

private struct DrawerTabButton: View {
    let title: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(DS.ui(14, DS.w550))
                .foregroundColor(active ? DS.foreground : DS.foregroundTertiary)
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? DS.neutral200 : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

private struct TranscriptView: View {
    let meeting: Meeting
    let isLive: Bool
    let query: String

    var body: some View {
        let segments = meeting.orderedSegments.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if meeting.segments.isEmpty {
                        VStack(spacing: 6) {
                            Text(isLive ? "Bem-vindo ao Notetaker!" : "Sem transcrição").font(DS.ui(15, DS.w550))
                            Text(isLive ? "Experimente dizer “Oi, Notetaker”. As falas aparecem aqui a cada pausa."
                                        : "Nada foi captado nesta reunião.")
                                .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 48)
                    }
                    ForEach(segments) { seg in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Self.clock(seg.start)).font(DS.ui(12).monospacedDigit())
                                .foregroundColor(DS.foregroundTertiary).frame(width: 40, alignment: .leading)
                            // .speaker { display:inline; font-weight:550 }
                            (Text(meeting.name(of: seg.speaker) + ": ").font(DS.ui(15, DS.w550))
                                .foregroundColor(seg.speaker == .you ? DS.chord600 : DS.foreground)
                             + Text(seg.text).font(DS.ui(15)))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .id(seg.id)
                    }
                    if isLive && !meeting.segments.isEmpty {
                        HStack(spacing: 6) { RecordingDot(); Text("Ouvindo…") }
                            .font(DS.ui(12)).foregroundColor(DS.foregroundTertiary)
                            .id("tail")
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
            .onChange(of: meeting.segments.count) {
                withAnimation { proxy.scrollTo(isLive ? AnyHashable("tail") : AnyHashable(segments.last?.id), anchor: .bottom) }
            }
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

private struct ChatView: View {
    let meeting: Meeting
    let busy: Bool
    let ask: (String) -> Void
    private static let prompts = ["O que eu perdi?", "Escreva um e-mail de follow-up", "Sugira perguntas",
                                  "Identifique pontos cegos", "Deixe as notas mais longas"]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if meeting.chat.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Pergunte qualquer coisa sobre esta reunião").font(DS.ui(15, DS.w550))
                            FlowLayout(spacing: 8) {
                                ForEach(Self.prompts, id: \.self) { p in
                                    Button { ask(p) } label: {
                                        Text(p).font(DS.ui(13, DS.w550)).foregroundColor(DS.foreground)
                                            .padding(.horizontal, 12).frame(height: 30)
                                            .background(Capsule().fill(DS.backgroundTertiary))
                                            .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.top, 16)
                    }
                    ForEach(meeting.chat) { msg in
                        if msg.fromUser {
                            HStack {
                                Spacer(minLength: 60)
                                Text(msg.text).font(DS.ui(15))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(DS.sand600))
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text(msg.text).font(DS.ui(15)).lineSpacing(3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if busy {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Pensando…") }
                            .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
            .onChange(of: meeting.chat.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: busy) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }
}

/// Wrapping row for the suggestion pills.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

// MARK: - Live pieces

/// White bars from the mic + system level (.waveformPill style).
struct LiveWaveform: View {
    @ObservedObject var levels: MeetingLevels
    var compact = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(levels.bars.suffix(compact ? 9 : 15).enumerated()), id: \.offset) { _, v in
                Capsule().fill(Color.white).frame(width: 2.5, height: max(3, v * (compact ? 16 : 22)))
            }
        }
        .frame(height: compact ? 18 : 24)
        .padding(.horizontal, compact ? 0 : 12)
        .frame(height: compact ? nil : 40)
        .background(compact ? nil : Capsule().fill(Color.black))
        .animation(.linear(duration: 0.08), value: levels.bars)
    }
}

struct ElapsedLabel: View {
    @ObservedObject var levels: MeetingLevels
    let prefix: String
    var body: some View {
        let s = Int(levels.elapsed)
        Text(prefix + (s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                                 : String(format: "%02d:%02d", s / 60, s % 60)))
            .monospacedDigit()
    }
}

/// Outlined / filled buttons on the dark live card.
struct DarkButtonStyle: ButtonStyle {
    let filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.ui(14, DS.w550))
            .foregroundColor(filled ? DS.vast950 : DS.sand50)
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(filled ? DS.sand50 : Color.white.opacity(configuration.isPressed ? 0.15 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(filled ? 0 : 0.2), lineWidth: 1))
            .contentShape(Rectangle())
    }
}
