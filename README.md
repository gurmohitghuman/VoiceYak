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

Download the latest `VoiceYak-x.y.dmg` from [Releases](https://github.com/g-ghuman/VoiceYak/releases), open it, and drag VoiceYak to Applications.

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

Building requires the full [Xcode](https://apps.apple.com/app/xcode/id497799835) app (free on the Mac App Store). The Command Line Tools alone are not enough. After installing Xcode, launch it once so it can finish setup, then point the command line tools at it:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

If you skip this and only have the Command Line Tools, `xcodebuild` fails with "tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance". The command above fixes it.

Then build:

```sh
git clone https://github.com/g-ghuman/VoiceYak.git
cd VoiceYak
./Scripts/fetch-sherpa-onnx.sh   # downloads the prebuilt sherpa-onnx static library
xcodebuild -project VoiceYak.xcodeproj -scheme VoiceYak -configuration Release build CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-
```

The built app lands in Xcode's DerivedData folder; the last lines of the build output show the full path. Move `VoiceYak.app` from there to `/Applications`.

If you don't want to install Xcode, grab a prebuilt app from [Releases](https://github.com/g-ghuman/VoiceYak/releases) instead and follow "Installing a downloaded build" above.

Or open `VoiceYak.xcodeproj` in Xcode, pick your own team under Signing & Capabilities (a free personal team works), and run. The project does not ship with a development team set, so Xcode asks once and remembers your choice. Building with your own team keeps the app's signature stable across rebuilds, so macOS permission grants stick; the ad-hoc command above re-signs on every build, which makes macOS ask for Microphone and Accessibility again after each rebuild.

The app guides you through permissions and the model download on first launch.

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
