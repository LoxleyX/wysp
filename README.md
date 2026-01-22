# Wysp

**Local voice-to-text for any application.** Hold a hotkey, speak, release — your words appear at the cursor. 100% offline, no cloud, no telemetry.

![Wysp Logo](logo.png)

## Features

- **Completely Local** — Uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for on-device speech recognition. Your voice never leaves your machine.
- **Universal Input** — Works with any application. Text is injected via simulated keystrokes.
- **Push-to-Talk** — Hold `Ctrl+Shift+Space` to record, release to transcribe and type.
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

### Linux (X11)

```bash
# Debian/Ubuntu
sudo apt install libgtk-3-dev libx11-dev libxtst-dev

# Fedora
sudo dnf install gtk3-devel libX11-devel libXtst-devel
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

Download a whisper.cpp compatible model:

```bash
# Create models directory
mkdir -p ~/.wysp/models

# Download base.en model (~150MB, good balance of speed/accuracy)
curl -L -o ~/.wysp/models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin

# Or tiny.en for faster transcription (~75MB, less accurate)
curl -L -o ~/.wysp/models/ggml-tiny.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin
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
git clone https://github.com/anthropics/wysp
cd wysp
zig build
```

The binary will be at `./zig-out/bin/wysp`.

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

## Custom Icons

Place custom icons in the wysp directory:

- `logo.png` — Idle state icon
- `logo-recording.png` — Recording state icon (red recommended)

## Platform Support

| Platform | Hotkey | Text Injection | Tray Icon |
|----------|--------|----------------|-----------|
| Linux X11 | XGrabKey | XTest | GTK StatusIcon |
| Linux Wayland | evdev | wtype/ydotool | GTK StatusIcon |
| Windows | Low-level hook | SendInput | Shell_NotifyIcon |

Windows support is implemented but untested. Requires building whisper.cpp for Windows.

## Troubleshooting

### Hotkey not working

- **X11**: Another application may have grabbed `Ctrl+Shift+Space`. Try closing other apps or check for conflicts.
- **Wayland**: Ensure you're in the `input` group and have logged out/in.

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
│  (X11/evdev)│     │ (miniaudio) │     │   (STT)     │
└─────────────┘     └─────────────┘     └─────────────┘
                                              │
┌─────────────┐     ┌─────────────┐           │
│ System Tray │◀────│   Overlay   │◀──────────┘
│   (GTK)     │     │   (GTK)     │           │
└─────────────┘     └─────────────┘           ▼
                                        ┌─────────────┐
                                        │ Text Inject │
                                        │  (XTest)    │
                                        └─────────────┘
```

## License

MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgments

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — High-performance C++ inference for OpenAI's Whisper
- [miniaudio](https://github.com/mackron/miniaudio) — Single-header audio library
- [Zig](https://ziglang.org/) — A language for high-performance, low-level programming
