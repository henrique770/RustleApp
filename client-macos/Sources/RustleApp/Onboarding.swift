import AppKit
import AVFoundation
import SwiftUI

/// First-run questionnaire, modeled on Wispr Flow's onboarding (recovered with REA from the hub
/// and feature-tour bundles):
///  - steps: login → welcome-basic ("Welcome {{name}}! A few questions to get started.") →
///    about-yourself ("What do you do for work?") → spend-time-typing ("Where do you spend time
///    typing?") → … → permissions → language ("Set the language(s) you speak") → shortcut →
///    personalize-personal / work / email / other ("How do you write your …?");
///  - a progress tracker of uppercase sections (12px / 600 / .075em) over 48x4 bars;
///  - centered EB Garamond 36 titles (.questionTitle) and option cards (.optionCard: padding
///    20 24, radius 12, 1px border, selected 2px dawn-700).
/// Wispr gets your name from the account you sign up with (editable in Settings → Account, first
/// and last name). RustleApp has no account, so the name is the first question.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let onFinish: () -> Void

    enum Step: Int, CaseIterable {
        case name, about, typing, language, shortcut, style, permissions, done

        var section: Int {
            switch self {
            case .name, .about, .typing: return 0
            case .language, .shortcut, .style: return 1
            case .permissions: return 2
            case .done: return 3
            }
        }
    }
    static let sections = ["Começar", "Preferências", "Permissões", "Pronto"]

    @State private var step: Step = .name
    @State private var first = ""
    @State private var last = ""
    @AppStorage(Prefs.role) private var role = ""
    @AppStorage(Prefs.typingPlaces) private var typingPlaces = ""
    @AppStorage(Prefs.language) private var language = "pt"
    @AppStorage(Prefs.hotkey) private var hotkey = "fn"
    @FocusState private var nameFocused: Bool

    init(model: AppModel, initialStep: Step = .name, onFinish: @escaping () -> Void) {
        self.model = model
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
        _first = State(initialValue: model.firstName.isEmpty ? AppModel.systemFirstName : model.firstName)
        _last = State(initialValue: model.firstName.isEmpty ? AppModel.systemLastName : model.lastName)
    }

    private var name: String { first.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 28)   // traffic lights
            ProgressTracker(current: step)
            ScrollView {
                VStack(spacing: 24) {
                    content
                }
                .frame(maxWidth: step == .style ? 760 : 560)
                .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            footer
        }
        .background(DS.background)
        .foregroundColor(DS.foreground)
        .font(DS.ui(15))
        .animation(.easeOut(duration: 0.2), value: step)
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .name:
            QuestionTitle(text: "Bem-vindo ao RustleApp!", subtitle: "Algumas perguntas para começar. Primeiro: como você quer ser chamado?")
            VStack(alignment: .leading, spacing: 16) {
                LabeledField(label: "Nome", placeholder: "Seu nome", text: $first)
                    .focused($nameFocused)
                    .onSubmit { if canContinue { next() } }
                LabeledField(label: "Sobrenome (opcional)", placeholder: "Seu sobrenome", text: $last)
                    .onSubmit { if canContinue { next() } }
                Text("Aparece na tela de início. Você pode mudar depois em Configurações → Perfil.")
                    .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
            }
            .frame(maxWidth: 400)
            .onAppear { nameFocused = true }

        case .about:
            QuestionTitle(text: "Conte um pouco sobre você, \(name)", subtitle: "O que você faz no trabalho?")
            ChoiceGrid(options: Self.roles, selected: Set([role]), columns: 3) { role = role == $0 ? "" : $0 }

        case .typing:
            QuestionTitle(text: "Onde você passa mais tempo digitando?",
                          subtitle: "Isso ajuda a ajustar o RustleApp ao seu dia a dia. Marque todas que se aplicam.")
            ChoiceGrid(options: Self.places, selected: placesSet, columns: 2) { id in
                var set = placesSet
                if set.contains(id) { set.remove(id) } else { set.insert(id) }
                typingPlaces = set.sorted().joined(separator: ",")
            }

        case .language:
            QuestionTitle(text: "Em que idioma você fala?", subtitle: "A transcrição funciona melhor quando sabe o idioma. O modo automático detecta sozinho.")
            VStack(spacing: 12) {
                OptionCard(title: "Português", detail: "Recomendado se você dita em português", selected: language == "pt") { language = "pt" }
                OptionCard(title: "Inglês", detail: "English", selected: language == "en") { language = "en" }
                OptionCard(title: "Automático", detail: "Detecta o idioma a cada ditado (um pouco mais lento)", selected: language == "auto") { language = "auto" }
            }

        case .shortcut:
            QuestionTitle(text: "Escolha o atalho para ditar", subtitle: "Segure a tecla, fale e solte: o texto é colado onde estiver o cursor.")
            VStack(spacing: 12) {
                OptionCard(title: "fn", detail: "Recomendado. Em Ajustes → Teclado, defina “Pressionar a tecla 🌐 para: Não Fazer Nada”.",
                           selected: hotkey == "fn") { setHotkey("fn") }
                OptionCard(title: "Option direito", detail: "Bom para teclados sem a tecla fn", selected: hotkey == "right_option") { setHotkey("right_option") }
                OptionCard(title: "Command direito", detail: "Alternativa se você usa o Option para acentos", selected: hotkey == "right_command") { setHotkey("right_command") }
            }

        case .style:
            QuestionTitle(text: "Como você escreve?", subtitle: "O texto ditado segue o tom de cada tipo de app. Dá para mudar depois na aba Estilo.")
            VStack(spacing: 12) {
                ForEach(Self.styleCategories, id: \.id) { cat in
                    StyleRow(title: cat.title, detail: cat.detail,
                             selection: Binding(get: { model.serverSettings.styles[cat.id] ?? "formal" },
                                                set: { model.serverSettings.styles[cat.id] = $0 }),
                             tones: cat.id == "personal" ? ["formal", "casual", "very_casual"] : ["formal", "casual", "excited"])
                }
            }

        case .permissions:
            QuestionTitle(text: model.permissions.allGranted ? "Obrigado pela confiança" : "Dê ao RustleApp as permissões do Mac",
                          subtitle: "A transcrição roda no seu computador: o áudio não sai daqui.")
            VStack(spacing: 12) {
                PermissionCard(title: "Microfone", detail: "Para ouvir você enquanto segura o atalho.",
                               granted: model.permissions.microphone) {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        openPane("Privacy_Microphone")
                    }
                }
                PermissionCard(title: "Acessibilidade", detail: "Para detectar o atalho em qualquer app e colar o texto.",
                               granted: model.permissions.accessibility) {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    if !AXIsProcessTrustedWithOptions(options) { openPane("Privacy_Accessibility") }
                }
            }

        case .done:
            QuestionTitle(text: "Tudo pronto, \(name)!", subtitle: "Vá para qualquer app, clique numa caixa de texto e dite.")
            HStack(spacing: 8) {
                Text("Segure").foregroundColor(DS.neutral600)
                Text(HotkeyMonitor.Trigger(rawValue: hotkey)?.label ?? "fn")
                    .font(DS.ui(14, .semibold)).foregroundColor(DS.sand50)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(DS.vast900))
                Text("para ditar e solte para colar.").foregroundColor(DS.neutral600)
            }
            .font(DS.ui(15))
            Text("Para anotações rápidas, abra o Scratchpad com \(GlobalShortcut.label).")
                .font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if step != .name {
                Button("Voltar") { back() }.buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
            if [.about, .typing].contains(step) {
                Button("Pular") { next() }.buttonStyle(.plain).foregroundColor(DS.foregroundTertiary).padding(.horizontal, 8)
            }
            if step == .permissions && !model.permissions.allGranted {
                Button("Fazer depois") { next() }.buttonStyle(.plain).foregroundColor(DS.foregroundTertiary).padding(.horizontal, 8)
            }
            Button(step == .done ? "Começar a usar" : "Continuar") { next() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canContinue)
                .opacity(canContinue ? 1 : 0.4)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 32).padding(.vertical, 20)
        .overlay(alignment: .top) { Rectangle().fill(DS.border).frame(height: 1) }
    }

    private var canContinue: Bool {
        switch step {
        case .name: return !name.isEmpty
        case .permissions: return model.permissions.allGranted
        default: return true
        }
    }

    private func next() {
        if step == .name {
            model.firstName = name
            model.lastName = last.trimmingCharacters(in: .whitespaces)
        }
        if step == .done {
            onFinish()
            return
        }
        step = Step(rawValue: step.rawValue + 1) ?? .done
    }

    private func back() {
        step = Step(rawValue: step.rawValue - 1) ?? .name
    }

    private func setHotkey(_ value: String) {
        hotkey = value
        model.hotkeyChanged()
    }

    private func openPane(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    private var placesSet: Set<String> { Set(typingPlaces.split(separator: ",").map(String.init)) }

    // MARK: Options (Wispr's about_yourself_role_* and spend_time_typing_option_*)

    static let roles: [(id: String, label: String)] = [
        ("developer", "Desenvolvimento"), ("product", "Produto"), ("founder", "Fundador(a) / CEO"),
        ("sales", "Vendas"), ("marketing", "Marketing"), ("support", "Atendimento"),
        ("operations", "Operações"), ("data", "Análise de dados"), ("legal", "Jurídico"),
        ("healthcare", "Saúde"), ("educator", "Educação"), ("student", "Estudante"),
        ("writer", "Escrita / Conteúdo"), ("consultant", "Consultoria"), ("other", "Outro"),
    ]
    static let places: [(id: String, label: String)] = [
        ("messages", "Mensagens"), ("emails", "E-mails"), ("documents", "Documentos"),
        ("notes", "Anotações"), ("ai_chat", "Conversando com IA"), ("ai_code", "Programando com IA"),
        ("posts", "Posts e comentários"), ("other", "Outro lugar"),
    ]
    static let styleCategories: [(id: String, title: String, detail: String)] = [
        ("personal", "Mensagens pessoais", "WhatsApp, Telegram, iMessage"),
        ("work", "Mensagens de trabalho", "Slack, Teams, Discord"),
        ("email", "E-mails", "Mail, Gmail, Outlook"),
        ("other", "Outros apps", "Documentos, notas, navegador"),
    ]
}

// MARK: - Pieces

/// Section names over 48x4 bars; the current section is in foreground color.
private struct ProgressTracker: View {
    let current: OnboardingView.Step
    var body: some View {
        HStack(spacing: 32) {
            ForEach(Array(OnboardingView.sections.enumerated()), id: \.offset) { i, title in
                VStack(spacing: 8) {
                    Text(title.uppercased())
                        .font(DS.ui(12, .semibold)).tracking(12 * 0.075)
                        .foregroundColor(i <= current.section ? DS.foreground : DS.vast300)
                    HStack(spacing: 4) {
                        let steps = OnboardingView.Step.allCases.filter { $0.section == i }
                        ForEach(steps, id: \.self) { s in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(s.rawValue <= current.rawValue ? DS.vast900 : DS.neutral200)
                                .frame(width: 48 / CGFloat(max(1, steps.count)) * (steps.count == 1 ? 1 : 1.4), height: 4)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// .questionTitle: EB Garamond 36/40, letter-spacing -0.04em, centered.
private struct QuestionTitle: View {
    let text: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 12) {
            Text(text)
                .font(DS.display(36)).tracking(-0.04 * 36)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(DS.ui(15)).foregroundColor(DS.neutral600)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
    }
}

private struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(DS.ui(13, DS.w550)).foregroundColor(DS.neutral600)
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(DS.vast500))
                .textFieldStyle(.plain)
                .font(DS.ui(17))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.card))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border, lineWidth: 1))
        }
    }
}

/// .optionCard: padding 20 24, radius 12, 1px border; hover neutral-400; selected 2px dawn-700.
private struct OptionCard: View {
    let title: String
    let detail: String
    let selected: Bool
    let pick: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(DS.ui(16, DS.w550))
                    Text(detail).font(DS.ui(13)).foregroundColor(DS.neutral600)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(selected ? DS.dawn700 : DS.sand700)
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? DS.dawn100 : DS.card))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? DS.dawn700 : (hover ? DS.vast300 : DS.border), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct ChoiceGrid: View {
    let options: [(id: String, label: String)]
    let selected: Set<String>
    let columns: Int
    let toggle: (String) -> Void
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            ForEach(options, id: \.id) { option in
                ChoiceChip(label: option.label, selected: selected.contains(option.id)) { toggle(option.id) }
            }
        }
    }
}

private struct ChoiceChip: View {
    let label: String
    let selected: Bool
    let pick: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: pick) {
            Text(label)
                .font(DS.ui(14, selected ? DS.w550 : .regular))
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(selected ? DS.dawn100 : DS.card))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? DS.dawn700 : (hover ? DS.vast300 : DS.border), lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct StyleRow: View {
    let title: String
    let detail: String
    @Binding var selection: String
    let tones: [String]

    private static let labels = ["formal": "Formal.", "casual": "Casual", "very_casual": "bem casual", "excited": "Animado!"]

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.ui(15, DS.w550))
                Text(detail).font(DS.ui(13)).foregroundColor(DS.foregroundTertiary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                ForEach(tones, id: \.self) { tone in
                    Button { selection = tone } label: {
                        Text(Self.labels[tone] ?? tone)
                            .font(DS.display(17))
                            .padding(.horizontal, 12).frame(height: 32)
                            .foregroundColor(selection == tone ? DS.foreground : DS.neutral600)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selection == tone ? DS.card : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selection == tone ? DS.dawn700 : .clear, lineWidth: 1.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 10).fill(DS.backgroundTertiary))
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.border, lineWidth: 1))
    }
}

private struct PermissionCard: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(DS.ui(16, DS.w550))
                Text(detail).font(DS.ui(13)).foregroundColor(DS.neutral600)
            }
            Spacer()
            if granted {
                Label("Permitido", systemImage: "checkmark.circle.fill")
                    .font(DS.ui(14, .medium)).foregroundColor(DS.success500)
            } else {
                Button("Permitir", action: request).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(granted ? DS.success500.opacity(0.5) : DS.border, lineWidth: 1))
    }
}
