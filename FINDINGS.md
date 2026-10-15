# Wispr Flow — how it works (reverse-engineering notes)

Target: `/Applications/Wispr Flow.app` v1.6.1147 (`com.electron.wispr-flow`). Your Desktop folder was
empty; this is the only copy on the machine. Analysis was **static only**: the app was never launched,
and no traffic was captured.

REA evidence IDs used below:

| ID | What |
|---|---|
| `ev_3501b69c…77b0` | `analyze_javascript_application` on `app.asar` (partial coverage — see limits) |
| `ev_32ea1dbb…bdf5` | `inspect_electron_fuses` |
| `ev_7510c130…769c` | `inspect_macho` on the Swift helper |
| `ev_187a03a9…bca` | `search_strings` paste / clipboard / pasteboard in the Swift helper |
| `ev_d8ee6436…c1` | `search_strings` event tap / Fn / AX / secure input in the Swift helper |

Background: wisprflow.ai says it "works anywhere you can type", removes filler words, adapts tone per
app, learns your words, and supports snippets. The privacy policy says optional "Context Awareness"
sends on-screen text from the active app, and that third-party AI providers process the data.

---

## Architecture

```
Electron main (index.js) ──stdin/stdout JSON──▶ Swift helper "Wispr Flow.app" (LSUIElement)
   │  ▲                                         • CGEventTap hotkeys, IOHID (Fn / mic ring)
   │  │ IPC                                      • AX focused element + textbox monitoring
   ▼  │                                          • clipboard + Cmd+V paste, clipboard restore
Renderer windows (status/overlay/hub)
   • getUserMedia + AudioWorklet "recorder-processor"
   │
   ▼  16 kHz PCM16 (Opus worker also present)
gRPC  flow_api.v1.TranscriptionService/TranscribeStream  (bidirectional stream)
   → host chosen at runtime from inference-info.wisprflow.com/dictation_url.txt (allowlisted)
   → HTTP fallback path if the stream fails
```

---

## 1. Speech capture

**Proven (from shipped files)**
- `Info.plist`: `NSMicrophoneUsageDescription` ("…to transcribe your speech"). The entitlement
  `com.apple.security.device.audio-input` is present (codesign).
- `renderer/dist/recorderWorklet.js` registers an `AudioWorkletProcessor` named `recorder-processor`.
  It buffers 640 Float32 samples per input stream (40 ms at 16 kHz) and posts them on start/stop.
- Renderer bundles (`status`, `overlay`, `hub`, …) call `getUserMedia`. Main-process IPC names include
  `media:getUserMediaError` and `media:audioInterruption`, plus an `AudioWorkletLoadError` notification.
- `index.js` packs audio as Int16 at `16e3`. It also resamples 16 kHz → 24 kHz for a separate
  `audio.append` / `audio.commit` (`encoding:"pcm16", sample_rate:24e3`) realtime-style channel.
- `opusEncoder.worker.js`, `incrementalOpusEncoder.worker.js` and `opusscript_native_wasm.wasm` ship with it.
- Push-to-talk lives in the Swift helper: it imports `CGEventTapCreate` and `IOHIDManager*`, and has the
  strings "Keyboard service event tap…" and "Found an external non-Apple keyboard. Assuming no Fn key
  available.". The helper `Info.plist` also mentions a BLE "mic ring". A Jabra connector is a native module.

**Inferred**
- Normal dictation sends PCM16 over gRPC (the `Metadata.audio_encoding` enum exists). Opus looks
  aimed at meeting recording and uploads (`meetingRecorder/opusEncoder.worker` appears in `package.json`
  scripts). The actual enum values weren't recovered.
- The 24 kHz `audio.append` path is probably the voice/agent ("instruct") mode, since its event names
  look like a realtime-LLM protocol.

**Hidden**
- Which device and window owns the AudioContext at runtime, and any VAD thresholds the server applies.

## 2. Getting transcription results

**Proven**
- gRPC service recovered from protobuf-ts descriptors in `index.js`:
  `flow_api.v1.TranscriptionService { Transcribe (unary); TranscribeStream (client+server streaming) }`.
- `Request { init | context | payload | commit }`
  - `Init { metadata{user_id, session_id, request_id, audio_encoding, client, …}, preferences, state }`
  - `Context { app{name,bundle_id,url,type}, textbox{contents,before_text,selected_text,after_text},
     vocabulary{screen_content_ax, screen_content_ocr, variable_names, file_names}, content_text,
     content_html, screenshot, conversation, session_dictation_apps }`
  - `Preferences { user, language, vocabulary{dictionary_personal/team/starred},
     replacements{replacements_*, snippets_*}, style_config{general_style, tagging, signature, editing_strength} }`
  - `Payload { audio_packets{items[]} | audio_file{data} }`
- `Response { result | state | all_states | heartbeat }`
  - `State.progress { transcriber, transcriber_finished, formatter, formatter_finished, post_processing_finished }`,
    plus `raw_text`, `formatted_text`, `candidate_beams[]`, `audio_snr`, `audio_volume`, `mean_alignment_score`.
  - `Result.output: Transcription { html, plaintext, num_tokens, languages, confidence }`.
  - `Heartbeat { audio_received_seconds, commit_ack }`.
- Endpoint selection: main fetches `https://inference-info.wisprflow.com/dictation_url.txt` with an
  8-second timeout and accepts only an allowlisted host: `inference.wisprflow.com`,
  `model-v31pl413.grpc.api.baseten.co`, or `wispr-ai-prod--prod-grpc-server-flowgrpcserver.us-east.modal.direct`.
- Stream metadata headers: `Authorization: Api-Key …`, `baseten-model-id: model-…`,
  `x-baseten-environment`, `disable-formatting`. Response headers read: `x-replica-id`, `x-proxy-region`.
- A fallback chain exists: `fallbackLevel`, `httpFallbackVersion`, `httpChunksSent`, `basetenUnavailableThisSession`.
- REST APIs: `api.wisprflow.ai` / `api-east.wisprflow.ai`. Supabase handles auth. Telemetry goes to PostHog,
  Sentry, Segment, and Datadog.

**Inferred**
- The server pipeline is transcriber (ASR) → formatter (LLM rewrite using context + style) → post-processing.
  This follows from the `Progress` fields and `formatted_text` vs `raw_text`. Streaming partials arrive as `State`
  messages and the final text as `Result`. The client sends `commit` when you release the key.
- Recognition is personalized by passing the dictionary and on-screen vocabulary (AX text, OCR, variable
  and file names) to the model.

**Hidden**
- The models themselves (ASR and formatter), prompts, and server-side logic all run on Baseten/Modal
  infrastructure and aren't in the app.
- Field-level semantics of enums (`Commit`, `AudioEncoding`, `Confidence`) beyond their names.

**Security observation (reported, not used):** the main bundle embeds what looks like a Baseten
`Api-Key` and a Supabase anon JWT, next to the model id. Supabase anon keys are public by design. The
Baseten key may be scoped or proxied, but that couldn't be determined statically. I didn't copy, test, or
use either value, and RustleApp doesn't depend on them.

## 3. Inserting text into other apps

**Proven**
- Main → helper message `PasteText { pasteId, text, htmlText?, captureKeystrokeTrace?, logAttributes? }`.
  The helper replies `PasteOutcome { success, timeElapsedMs, reason, pasteId }`, plus `PasteAnalytics`/`PasteBlocked`.
- Transport: main spawns the helper and writes escaped, delimiter-framed JSON (`HelperAPIRequest`/`Response`,
  quicktype-generated from one schema) to its **stdin**, max 100,000 chars. It reads replies from stdout.
- Swift helper strings and imports (`ev_187a03a9…`):
  - Saves the pasteboard ("Saved pasteboard types"), writes the text, posts the key chord
    (`CGEventCreateKeyboardEvent`, `CGEventPost`, `CGEventPostToPid`), then restores it
    ("Scheduling clipboard restoration in 500ms").
  - **Delayed rendering**: `DelayedClipboardProvider` (an `NSPasteboardItemDataProvider`). Success is detected
    when the target app actually asks for the data ("Failed Timeout timer cancelled - paste succeeded (data
    was requested)"). Otherwise: "Delayed clipboard timeout -- failed paste likely".
  - Marks its clipboard writes `org.nspasteboard.ConcealedType`.
  - Fallbacks: "Performed paste operation using fallback element", "…after app activation", "…as last resort",
    plus a direct `AXValue` set for some flows ("direct AXValue set did not stick, falling back to clipboard paste").
  - Checks `IsSecureEventInputEnabled` ("Secure input is blocking keyboard shortcuts").
  - Context comes from `AXUIElementCopyAttributeValue` on `AXFocusedUIElement`, watched with `AXObserver` /
    `AXFocusedUIElementChanged`.
- Main checks `getTextBoxInfo()` first. If no editable field is focused, it shows a "void dictation"
  notification instead of pasting.

**Inferred**
- After pasting it watches the field to learn your edits ("Trying to capture edits of a dictated text but
  pasteId is nil"; DB migration `add-history-edit-distance`). These feed the personal dictionary.

**Hidden**
- Exact keystroke timings, per-app special cases (Slack formatted text is mentioned), and the decision logic
  for picking a fallback. Getting these would need decompiling the paste routine or a runtime trace.

## Coverage limits
- The REA JavaScript graph is **partial**: `main/index.js` (9.8 MB) ran out of analyzer heap, and several
  renderer chunks skipped semantic analysis. Main-process facts came from direct targeted reads of the
  extracted bundle, cross-checked with REA's inventory.
- REA flagged an integrity mismatch for `app.asar.unpacked/.../panel_activation.node`. Its observed bytes are
  treated as untrusted and weren't analyzed.
- Electron fuses: RunAsNode and `--inspect` are disabled and ASAR integrity is enforced, so runtime
  inspection would need other means. None was performed.
