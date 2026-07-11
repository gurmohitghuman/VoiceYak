# VoiceYak

**System-wide dictation for macOS. Completely private, 100% offline.**

VoiceYak is a free, open-source menu bar app. Hold a key, speak, release — your words are transcribed locally and pasted into whatever app you're typing in. No cloud, no account, no API costs. Audio never leaves your Mac.

## How it works

1. VoiceYak lives in your menu bar (no Dock icon)
2. In any app — Slack, your editor, a browser — **hold the push-to-talk key** (default: Right Option `⌥`)
3. A small pill appears at the bottom of the screen while you **speak**
4. **Release the key** — the audio is transcribed on-device and pasted at your cursor

Transcription is powered by [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (int8) running locally via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). It supports English and 24 other European languages, and transcribes short clips in well under a second on Apple Silicon.

## Screenshots

| ![Home dashboard with live status and dictation stats](docs/screenshots/home.png) | ![General settings: hotkey, behavior, permissions](docs/screenshots/general.png) |
|:--:|:--:|
| ![Voice model manager with multilingual and English models](docs/screenshots/voice-model.png) | ![Output settings: text processing, per-app formatting, clipboard](docs/screenshots/output.png) |
| ![Custom dictionary for names, brands, and jargon](docs/screenshots/dictionary.png) | ![Advanced settings: fast long dictations and live preview](docs/screenshots/advanced.png) |

## Requirements

- macOS 26.2+ on Apple Silicon
- ~700 MB of disk space for the speech model (downloaded on first launch)
- Microphone permission (recording) and Accessibility permission (global hotkey + paste)

## Installing a downloaded build

Release builds are not currently notarized with Apple, so macOS blocks the
first launch. This is a one-time step:

1. Move `VoiceYak.app` to `/Applications` and open it. macOS says it
   "could not verify VoiceYak is free of malware" — click **Done**
   (not "Move to Trash").
2. Open **System Settings → Privacy & Security**, scroll down to the
   Security section, and click **Open Anyway** next to the VoiceYak message.
3. Confirm and authenticate. macOS remembers the choice from then on.

If you prefer the Terminal, this clears the quarantine flag in one step:

```sh
xattr -d com.apple.quarantine /Applications/VoiceYak.app
```

Building from source avoids all of this.

## Building from source

```sh
git clone https://github.com/g-ghuman/VoiceYak.git
cd VoiceYak
./Scripts/fetch-sherpa-onnx.sh   # downloads the prebuilt sherpa-onnx static library
xcodebuild -project VoiceYak.xcodeproj -scheme VoiceYak -configuration Release build
```

Or open `VoiceYak.xcodeproj` in Xcode and run. The app guides you through permissions and the model download on first launch.

## Settings

- **Record key** — choose which modifier key to hold (Right/Left Option, Right Command, Right Control, Right Shift, Fn/Globe)
- **Show Dock icon** — keep VoiceYak visible in the Dock, or run it as a pure menu bar app
- **Text output** — auto-capitalize, trailing space, clipboard restore after paste
- **Recording** — maximum recording duration (10–120 s)

## Architecture

Small Swift/SwiftUI codebase (~2,500 lines), no third-party Swift dependencies:

```
VoiceYak/
├── App/            AppState (status state machine), AppDelegate (wiring)
├── Services/
│   ├── HotkeyManager       CGEvent tap for the push-to-talk key (listen-only)
│   ├── AudioRecorder       AVAudioEngine capture → 16 kHz mono Float32
│   ├── ParakeetService     sherpa-onnx offline recognizer
│   ├── TextOutputService   clipboard save → paste (⌘V) → clipboard restore
│   └── ModelDownloader     model download + extraction
├── Views/          Menu bar popover, recording pill, onboarding, settings
└── Helpers/        Constants, permissions, UserDefaults accessors
```

## Privacy

Everything runs on-device. VoiceYak makes exactly one kind of network request: downloading the speech model from GitHub on first setup. There is no telemetry, no analytics, no account.

## License

VoiceYak is released under the [MIT License](LICENSE).

Third-party components are listed with full license texts in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and in the app's Credits
tab. The main ones:

- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) — Apache-2.0 (built **without TTS** so no GPL code is linked)
- [ONNX Runtime](https://github.com/microsoft/onnxruntime) — MIT
- [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) — CC-BY-4.0 (downloaded at runtime)
