# RustleApp

RustleApp is a macOS voice-dictation app. Hold a hotkey, speak, and release it to transcribe and paste cleaned-up text into the app currently in focus. Speech recognition runs locally, so audio stays on your Mac.

## Technologies

- **Swift** for the macOS app and its menu bar interface.
- **AVFoundation** for audio capture and conversion.
- **Core Graphics** and **Accessibility APIs** for hotkey monitoring, focus context, and text insertion.
- **Python**, **FastAPI**, and **faster-whisper** for the local transcription server and speech recognition.
- **Whisper** for speech recognition; its model is downloaded on first use.
- **Claude** and **DeepSeek APIs** are optional providers for AI-assisted text polishing.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| Hold **Fn**, **Right Option**, or **Right Command** | Start dictation; release to transcribe and paste. Choose the key in Settings. |
| **Control + Option + N** | Open or toggle the Scratchpad from anywhere. |
| **Command + T** | Create a new Scratchpad tab. |
| **Command + W** | Close the current Scratchpad tab. |
| **Control + Tab** / **Control + Shift + Tab** | Switch to the next / previous Scratchpad tab. |
| **Command + Shift + ]** / **Command + Shift + [** | Switch to the next / previous Scratchpad tab. |
| **Command + B** / **Command + I** / **Command + K** | Apply bold / italic / insert link in the Scratchpad. |
| **Command + Shift + C** | Copy the current Scratchpad note. |
| **Escape** | Close the Scratchpad. |

## Installation

### Requirements

- macOS 14 (Sonoma) or later. Apple silicon is recommended; Intel Macs are supported but may transcribe more slowly.
- Apple's Swift command-line tools. Install them with `xcode-select --install` if needed.
- Python 3.10 or later. If needed, install it with [Homebrew](https://brew.sh): `brew install python@3.12`.
- Around 2 GB of free disk space for the server dependencies and Whisper model.
- An internet connection during setup and the first dictation to download the model. Transcription works offline afterward.

### Install

```bash
git clone <repository-url> RustleApp
cd RustleApp
./scripts/install.sh
```

The installer prepares the Python environment, creates a local signing certificate, builds the app, copies it to `/Applications` (or `~/Applications` if needed), and opens it.

Keep the repository folder in place after installation. The app starts its transcription server from that folder. If you move it, run `./scripts/install.sh` again from its new location.

### First launch

On first launch, RustleApp guides you through a short setup for your name, language, dictation hotkey, and writing preferences. It also asks for Microphone and Accessibility permissions. You can change your preferences later in Settings.

If you use the **Fn** key as your hotkey, open System Settings → Keyboard and set “Press 🌐 key to” to **Do Nothing**. macOS may also request System Audio Recording permission when you first record a meeting.
