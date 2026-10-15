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

## Services it needs

1. **rustle-server** (required, local). FastAPI + [faster-whisper](https://github.com/SYSTRAN/faster-whisper).
   The model downloads from Hugging Face on first run (`base.en` is about 150 MB). After that, audio never
   leaves your Mac.
2. **Claude API** (optional). Set `RUSTLE_LLM=claude` for app-aware rewriting: self-corrections,
   tone per app, lists. This needs `ANTHROPIC_API_KEY` (or an `ant auth login` profile). If it's
   unavailable, slow (8 s timeout) or refused, the server quietly uses the rule-based output instead.
   Uses `claude-opus-5-5` at low effort with server-side refusal fallback enabled. Override the model
   with `RUSTLE_CLAUDE_MODEL`.

No account, auth server, or telemetry is involved.

## Run

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
