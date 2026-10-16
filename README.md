# RustleApp

A small, working, clean-room voice-dictation app for macOS, modelled on how Wispr Flow works
(see [FINDINGS.md](FINDINGS.md)). Hold a key, speak, release, and the cleaned-up text is pasted
into whatever app has focus.

```
RustleApp.app (Swift, menu bar)                rustle-server (Python, localhost:8765)
 HotkeyMonitor   CGEventTap, hold Fn            /v1/dictate
 AudioRecorder   AVAudioEngine → 16k PCM16 ──▶   faster-whisper ASR (local, offline)
 FocusContext    AX: app, text before cursor ─▶  Formatter: rules (+ optional Claude polish)
 TextInserter    clipboard + Cmd+V + restore ◀── {"raw", "text"}
```

| Wispr Flow (observed) | RustleApp |
|---|---|
| Swift helper: CGEventTap / IOHID Fn key | `HotkeyMonitor.swift`: listen-only tap on flagsChanged |
| AudioWorklet, 16 kHz PCM16 | `AudioRecorder.swift`: AVAudioEngine + AVAudioConverter |
| `flow_api.v1.Context` (app, textbox) | `FocusContext.swift` (same fields, subset) |
| gRPC `TranscribeStream` to Baseten/Modal | one HTTP POST per utterance to a local server |
| server transcriber → formatter | faster-whisper → `formatter.py` |
| dictionary / replacements / snippets, hub window | `MainWindow.swift` + `~/Library/Application Support/RustleApp/settings.json` |
| `PasteText` → clipboard, Cmd+V, restore after 500 ms, ConcealedType | `TextInserter.swift` |

## Instalação

### Requisitos

- Mac com **macOS 14 (Sonoma) ou mais recente**. Apple Silicon é recomendado; Intel funciona, mas transcreve mais devagar.
- **Ferramentas de linha de comando da Apple** (Swift): `xcode-select --install`.
- **Python 3.10+**. Se não tiver, instale pelo [Homebrew](https://brew.sh): `brew install python@3.12`.
- Cerca de **2 GB livres**: dependências do servidor e o modelo Whisper, baixado no primeiro uso.
- Internet só na instalação e no primeiro ditado, para baixar o modelo. Depois disso, a transcrição roda offline.

### Instalar

```bash
git clone <url-deste-repositório> RustleApp   # ou baixe e descompacte o .zip
cd RustleApp
./scripts/install.sh
```

O `install.sh` faz, nesta ordem:

1. Confere os requisitos.
2. Cria o ambiente Python do servidor (`server/.venv`).
3. Cria um certificado local de assinatura, para o macOS lembrar das permissões entre atualizações.
4. Compila o app e o copia para `/Applications`. Se essa pasta não aceitar escrita, usa `~/Applications`.
5. Abre o app.

> Não mova nem apague a pasta do repositório depois de instalar: o app inicia o servidor de
> transcrição a partir dela. Se mudar a pasta de lugar, rode `./scripts/install.sh` de novo.

### Primeira abertura

Na primeira abertura, o RustleApp mostra um questionário curto, como o onboarding do Wispr Flow:

| Etapa | Pergunta |
|---|---|
| Começar | **Seu nome** (aparece em “Bem-vindo de volta, …” na tela de início), o que você faz e onde mais digita |
| Preferências | idioma em que você fala, atalho de ditado (fn, Option direito ou Command direito) e tom da escrita por tipo de app |
| Permissões | **Microfone** e **Acessibilidade**, com um botão que leva direto ao Ajuste do Sistema |
| Pronto | como ditar e como abrir o Scratchpad |

Tudo isso pode ser mudado depois em **Configurações**. Em **Perfil** ficam o nome, o sobrenome e
o botão *Refazer* do questionário.

Se escolher a tecla **fn**, vá em Ajustes do Sistema → Teclado e defina *“Pressionar a tecla 🌐 para:
Não Fazer Nada”*. Para o Notetaker gravar o som das chamadas, o macOS pede **Gravação de áudio do
sistema** na primeira reunião.

### Atualizar

```bash
cd RustleApp
git pull
./scripts/install.sh
```

Suas notas, histórico e configurações ficam em `~/Library/Application Support/RustleApp/` e são mantidos.

### Desinstalar

```bash
rm -rf /Applications/RustleApp.app ~/Applications/RustleApp.app
rm -rf ~/Library/Application\ Support/RustleApp ~/Library/Logs/RustleApp*.log
defaults delete dev.rustleapp.client
security delete-identity -c "RustleApp Local Signing"
tccutil reset All dev.rustleapp.client
```

O último comando remove as permissões que o app recebeu. Depois disso, apague a pasta do repositório.

## Services it needs

1. **rustle-server** (required, local). FastAPI + [faster-whisper](https://github.com/SYSTRAN/faster-whisper).
   The model downloads from Hugging Face on first run (`base.en` is about 150 MB). After that, audio never
   leaves your Mac.
2. **Claude API** (optional). Set `RUSTLE_LLM=claude` for app-aware rewriting: self-corrections,
   tone per app, lists. This needs `ANTHROPIC_API_KEY` (or an `ant auth login` profile). If it's
   unavailable, slow (8 s timeout) or refused, the server quietly uses the rule-based output instead.
   Uses `claude-opus-5-5` at low effort with server-side refusal fallback enabled. Override the model
   with `RUSTLE_CLAUDE_MODEL`.
3. **DeepSeek API** (optional, alternative to Claude). Paste the key in Configurações → Polimento com IA
   (stored in the Keychain, passed to the server as `DEEPSEEK_API_KEY`) and pick "DeepSeek" as the
   provider (`ai_provider` in `rustle.json`, or `RUSTLE_LLM=deepseek`). It powers the dictation polish,
   meeting notes, meeting chat and Scratchpad transforms. When the preferred provider has no key, the
   other one is used. Model `deepseek-chat` by default; override with `RUSTLE_DEEPSEEK_MODEL`.

No account, auth server, or telemetry is involved.

## Run (desenvolvimento)

Para quem vai mexer no código. Para só usar o app, veja [Instalação](#instalação).

```bash
./scripts/create-signing-cert.sh   # once: local signing identity, so permissions survive rebuilds
./scripts/build-app.sh             # builds build/RustleApp.app
open build/RustleApp.app           # opens the main window and starts rustle-server automatically
```

RustleApp is a regular desktop app (Dock icon + main window) with a menu-bar item and a floating
dictation bar. The main window, modelled on Wispr Flow's hub, has:

| Section | What it does |
|---|---|
| Início | server status, permission checklist (with *Reparar permissões* / *Reiniciar app*), stats, paste test |
| Histórico | every dictation, searchable, with copy and raw transcript |
| Notas | local notes; click in one and hold Fn to dictate into it |
| Dicionário | words sent to Whisper as recognition hints |
| Snippets | spoken trigger → full text, plus spoken → written replacements |
| Configurações | hotkey, language (pt/en/auto), Whisper model, Claude polish + API key (Keychain) |

Data lives in `~/Library/Application Support/RustleApp/` (`history.json`, `notes.json`,
`settings.json`). The server reloads `settings.json` whenever the app changes it.

Grant **Microphone**, **Input Monitoring** (Fn key in any app) and **Accessibility** (Cmd+V) in
System Settings → Privacy & Security. Set `Keyboard → "Press 🌐 key to"` to *Do Nothing*.

## Troubleshooting

- **Fn only works while the RustleApp menu is open / "Sem permissão de Acessibilidade"** although the
  toggles look on: the grants belong to an older build with a different signature. In *Início*, click
  **Reparar permissões** (runs `tccutil reset` for this app), enable RustleApp again when macOS asks,
  then **Reiniciar app**. With the local signing certificate this only has to be done once.
- The floating bar and *Início* show what went wrong. *Testar colagem* checks the paste step alone.
- Logs: `~/Library/Logs/RustleApp.log` (app) and `~/Library/Logs/RustleApp-server.log` (server).
- If a paste isn't confirmed (no app asked for the text within 1 s), the text stays on the clipboard
  and the bar tells you to press ⌘V. The dictation is still saved in *Histórico*.
- Remove the signing certificate with `security delete-identity -c "RustleApp Local Signing"`.

## Tested

- Swift client builds (`swift build -c release`), and the `.app` bundle signs and its `Info.plist` lints.
- Server end to end with macOS `say` speech:
  - English (`base.en`): "Um, so I think we should, uh, ship the RustleApp demo on Friday. No wait,
    Thursday." came back as `So I think we should ship the RustleApp demo on Friday, no wait, Thursday.`
    in about 0.4 s on CPU.
  - Portuguese (`small`): "Hum, então eu acho que a gente devia lançar o RustleApp na sexta…" was
    transcribed correctly in about 1.8 s on CPU.
- App launch verified: main window opens, the server auto-starts (API v2), settings reload, per-request
  language, and server restart all work.
- Recording + transcription were exercised live by the user; paste was blocked by stale permissions,
  which the stable signature and *Reparar permissões* address. Paste after re-granting is not yet confirmed.
- The Claude polish path was checked only for its no-credentials fallback. No live API call was made.
- **Not yet tested:** live hotkey, mic, and paste. Those need the macOS permission prompts, which have
  to be granted by hand.

## Next steps toward Wispr parity
- Stream audio while you're still talking (WebSocket/gRPC) so the result is ready when you release.
- Check that a paste succeeded using delayed pasteboard rendering (`NSPasteboardItemDataProvider`).
- Fall back to setting `AXValue` directly for apps that ignore Cmd+V.
- Learn new dictionary words from edits made right after a paste.

## Notetaker (reuniões)

Rebuilt from Wispr Flow's Notetaker (evidence from REA: `MacCatapSystemAudioLoopbackCapture` /
`getDisplayMedia` loopback for system audio, a separate mic graph, `hub_meeting_*` UI strings and CSS modules).

- **Captura**: microfone = "Você", áudio do sistema = "Outros" (Core Audio process tap, macOS 14.2+;
  permissão "Gravação de áudio do sistema" pedida na primeira gravação). Cada fluxo é cortado nas pausas
  (6–25 s) e enviado a `POST /v1/transcribe`. Eco do alto-falante captado pelo mic é descartado.
- **Detecção**: Zoom, Teams, FaceTime, Webex, Slack huddle, Google Meet no navegador (título da janela),
  quando o app está usando o microfone → "Reunião detectada" no Flow bar; clique para iniciar.
- **Depois da reunião**: `POST /v1/notes` gera título, resumo em seções e itens de ação. Com chave da
  Anthropic (Configurações) usa Claude; sem chave, resumo extrativo local.
- **Chat**: `POST /v1/notes/ask` ("O que eu perdi?", e-mail de follow-up…).
- Dados em `~/Library/Application Support/RustleApp/meetings.json`.

## Scratchpad

Rebuilt from Wispr Flow's Scratchpad (evidence from REA: the `scratchpad` BrowserWindow config —
transparent panel 500×420, min 300×200, expanded 920×660, opened at the cursor and clamped to the work
area, visible on all Spaces —, the `hub_scratchpad_*` strings, the renderer CSS modules and
`POST /api/v1/transform/suggestions {content, count: 6}`).

- **Abrir**: atalho global **⌃⌥N** (de novo para fechar), menu da barra de status, ou a página Notas.
  Painel não-ativador: recebe o teclado sem tirar o app em uso da frente.
- **Abas e notas**: ⌘T nova aba, ⌘W fecha, ⌃Tab / ⌘⇧] alterna, duplo clique renomeia. Barra lateral
  com busca, fixar e apagar. As notas são as mesmas da página Notas do hub (`notes.json`).
- **Ditado**: com o Scratchpad em foco, segure fn e o texto entra no cursor. Se uma colagem falhar em
  outro app, o texto ditado abre numa aba nova do Scratchpad (como o "paste_failure" do Wispr).
- **Copiar / Enviar no app**: copia a nota, ou cola no app que estava em frente quando você abriu.
- **Histórico de versões**: Criada, Ditado, Edições digitadas, Transformação; clique para restaurar.
- **Formatação**: Markdown leve (negrito, itálico, código, link, título, listas, checklist, citação),
  com Enter continuando listas.
- **Transformações**: `POST /v1/transform/suggestions` e `POST /v1/transform`. Com chave da Anthropic,
  o Claude sugere e aplica qualquer pedido; sem chave, há 6 transformações locais (corrigir, tópicos,
  checklist, mais curto, parágrafo, título).
- **Configuração**: "Ao abrir o Scratchpad" — retomar última nota, nova aba ou última nota fixada.
