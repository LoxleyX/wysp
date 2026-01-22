<p align="center">
  <img src="logo.png" alt="Wysp" width="120" height="120">
</p>

<h1 align="center">Wysp</h1>

<p align="center">
  <strong>Local voice-to-text for any application.</strong>
</p>

<p align="center">
  Hold a hotkey, speak, release — your words appear at the cursor.<br>
  100% offline. No cloud. No telemetry.
</p>

<p align="center">
  <a href="https://github.com/LoxleyX/wysp/blob/main/LICENSE"><img src="https://img.shields.io/github/license/LoxleyX/wysp?style=flat-square" alt="license"></a>
  <img src="https://img.shields.io/badge/100%25-local-brightgreen?style=flat-square" alt="100% local">
  <img src="https://img.shields.io/badge/built_with-Zig-f7a41d?style=flat-square" alt="built with Zig">
  <img src="https://img.shields.io/badge/platforms-Linux%20%7C%20Windows-blue?style=flat-square" alt="platforms">
</p>

---

## Installation

### Linux (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/LoxleyX/wysp/main/scripts/install.sh | sh
```

Or download from [Releases](https://github.com/LoxleyX/wysp/releases):
- `wysp-linux-x86_64.tar.gz` — Binary tarball
- `wysp_*_amd64.deb` — Debian/Ubuntu package

### Windows

Download `wysp-windows-x86_64.zip` from [Releases](https://github.com/LoxleyX/wysp/releases) and extract to a folder of your choice.

### From Source

See [Building](#building) below.

---

## Features

- **Completely Local** — Uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for on-device speech recognition. Your voice never leaves your machine.
- **Universal Input** — Works with any application. Text is injected via simulated keystrokes.
- **Push-to-Talk** — Hold your hotkey to record, release to transcribe and type. Default: `Ctrl+Shift+Space`
- **Configurable Hotkey** — Change the hotkey via `~/.wysp/config.json`
- **Toggle Mode** — Optional tap-to-start, tap-to-stop mode for longer dictation.
- **System Tray** — Runs quietly in your system tray with visual feedback when recording.
- **Recent History** — Access your last 10 transcriptions from the tray menu. Click to copy.
- **Custom Icons** — Supports custom tray icons for idle and recording states.

## Privacy

Wysp contains **zero networking code**. An audit of the binary shows:

- No socket/connect/send/recv symbols
- No HTTP, curl, or SSL libraries linked
- No cloud API references in whisper.cpp

Data flow: `Microphone → RAM → whisper.cpp (local model) → Keystrokes`

You can verify this yourself or run Wysp with your network disabled.

## Requirements

### Windows

No additional dependencies required. Just download and run.

Configuration is stored in `%USERPROFILE%\.wysp\config.json`.

### Linux (X11)

```bash
# Debian/Ubuntu
sudo apt install libgtk-3-0 libx11-6 libxtst6

# Fedora
sudo dnf install gtk3 libX11 libXtst
```

### Linux (Wayland)

Wayland support requires membership in the `input` group for global hotkeys:

```bash
sudo usermod -aG input $USER
# Log out and back in
```

For text injection on Wayland, install one of:
```bash
sudo apt install wtype   # or
sudo apt install ydotool
```

### Whisper Model

Wysp will prompt you to download a model on first run, or you can select one from the tray menu.

Models are stored in:
- **Linux**: `~/.wysp/models/`
- **Windows**: `%USERPROFILE%\.wysp\models\`

To download manually:

```bash
# Linux
mkdir -p ~/.wysp/models
curl -L -o ~/.wysp/models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

```powershell
# Windows (PowerShell)
mkdir "$env:USERPROFILE\.wysp\models" -Force
Invoke-WebRequest -Uri "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin" `
  -OutFile "$env:USERPROFILE\.wysp\models\ggml-base.en.bin"
```

### Whisper.cpp Libraries

Wysp links against pre-built whisper.cpp libraries. You can either:

**Option A: Build whisper.cpp yourself**
```bash
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp
cmake -B build
cmake --build build
# Copy libraries to ~/.wysp/lib/ or adjust build.zig paths
```

**Option B: Use existing ziew installation**

If you have [ziew](https://github.com/anthropics/ziew) installed, Wysp will use its whisper libraries from `~/.ziew/lib/`.

## Building

Requires [Zig](https://ziglang.org/download/) (0.13.0 or later):

```bash
git clone https://github.com/LoxleyX/wysp
cd wysp
zig build
```

The binary will be at `./zig-out/bin/wysp`.

For building on Linux, you'll also need development headers:
```bash
# Debian/Ubuntu
sudo apt install libgtk-3-dev libx11-dev libxtst-dev
```

## Usage

```bash
./zig-out/bin/wysp
```

- **Hold `Ctrl+Shift+Space`** — Start recording
- **Release** — Stop recording, transcribe, and type the result
- **Right-click tray icon** — Access menu (toggle mode, history, quit)

### Toggle Mode

Enable "Toggle Mode" in the tray menu to switch from hold-to-record to:

- **Press `Ctrl+Shift+Space`** — Start recording
- **Press again** — Stop and transcribe

This is useful for longer dictation where holding the keys is uncomfortable.

### Recent Transcriptions

The tray menu shows your last 10 transcriptions. Click any entry to copy it to your clipboard.

## Configuration

Wysp stores its configuration in:
- **Linux**: `~/.wysp/config.json`
- **Windows**: `%USERPROFILE%\.wysp\config.json`

You can edit this file directly or use the "Edit Config" option in the tray menu.

```json
{
  "hotkey": "Ctrl+Shift+Space",
  "toggle_mode": false,
  "model": "base",
  "language": "english"
}
```

### Model Selection

Select your whisper model from the tray menu. If the model isn't downloaded yet, Wysp will automatically download it.

| Model | Size | Speed | Accuracy |
|-------|------|-------|----------|
| tiny | ~75MB | Fastest | Basic |
| base | ~150MB | Fast | Good |
| small | ~500MB | Medium | Better |
| medium | ~1.5GB | Slow | Great |
| large | ~3GB | Slowest | Best |

### Language Selection

- **English** — Uses English-optimized models (`.en` suffix). Faster and more accurate for English.
- **Multilingual** — Uses general models that support 99+ languages. Wysp auto-detects the language.

### Changing the Hotkey

The hotkey format is `Modifier+Modifier+Key`. Supported modifiers:
- `Ctrl` / `Control`
- `Shift`
- `Alt`
- `Super` / `Win` / `Meta`

Supported keys:
- Letters: `A`-`Z`
- Numbers: `0`-`9`
- Function keys: `F1`-`F12`
- Special: `Space`, `Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, `Insert`, `Home`, `End`, `PageUp`, `PageDown`
- Arrows: `Up`, `Down`, `Left`, `Right`

Examples:
```json
{"hotkey": "Ctrl+Shift+Space"}
{"hotkey": "Super+V"}
{"hotkey": "Alt+Shift+R"}
{"hotkey": "Ctrl+F9"}
```

**Note:** Restart Wysp after changing the hotkey.

## Custom Icons

Place custom icons in the wysp config directory:
- **Linux**: `~/.wysp/`
- **Windows**: `%USERPROFILE%\.wysp\`

Files:
- `logo.png` — Idle state icon
- `logo-recording.png` — Recording state icon (red recommended)

## Platform Support

| Platform | Hotkey | Text Injection | Tray Icon |
|----------|--------|----------------|-----------|
| Linux X11 | XGrabKey | XTest | GTK StatusIcon |
| Linux Wayland | evdev | wtype/ydotool | GTK StatusIcon |
| Windows | Low-level keyboard hook | SendInput | Shell_NotifyIcon |

Pre-built binaries are available for Linux (x86_64) and Windows (x86_64).

## Troubleshooting

### Hotkey not working

- **Windows**: Try running as administrator, or use a different hotkey combination.
- **X11**: Another application may have grabbed your hotkey. Try a different key combination.
- **Wayland**: Ensure you're in the `input` group and have logged out/in.
- **Invalid key**: Check that your hotkey uses supported modifiers and keys (see Configuration section).

### [BLANK_AUDIO] result

- Speak louder or closer to the microphone
- Hold the hotkey longer (minimum 0.3 seconds)
- Check your default audio input device

### Transcription is slow

- Use the `tiny.en` model instead of `base.en`
- Wysp uses 8 CPU threads by default

### No tray icon

- Ensure your desktop environment supports system tray icons
- Some DEs require extensions (e.g., GNOME needs AppIndicator extension)

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Hotkey    │────▶│   Audio     │────▶│  Whisper    │
│             │     │ (miniaudio) │     │   (STT)     │
└─────────────┘     └─────────────┘     └─────────────┘
                                              │
┌─────────────┐     ┌─────────────┐           │
│ System Tray │◀────│   Overlay   │◀──────────┘
│             │     │             │           │
└─────────────┘     └─────────────┘           ▼
                                        ┌─────────────┐
                                        │ Text Inject │
                                        │             │
                                        └─────────────┘
```

Platform-specific implementations:
- **Linux**: X11/evdev hotkeys, GTK tray/overlay, XTest injection
- **Windows**: Low-level hooks, Shell_NotifyIcon tray, SendInput injection

## License

MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgments

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — High-performance C++ inference for OpenAI's Whisper
- [miniaudio](https://github.com/mackron/miniaudio) — Single-header audio library
- [Zig](https://ziglang.org/) — A language for high-performance, low-level programming
