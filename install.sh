#!/bin/bash
# Wysp installer
# Builds and installs wysp to ~/.local/bin

set -e

echo "Building wysp..."
zig build -Doptimize=ReleaseFast

# Create directories
mkdir -p ~/.local/bin
mkdir -p ~/.wysp/models

# Install binary
cp zig-out/bin/wysp ~/.local/bin/
chmod +x ~/.local/bin/wysp

# Copy icons if they exist
if [ -f logo.png ]; then
    cp logo.png ~/.wysp/
fi
if [ -f logo-recording.png ]; then
    cp logo-recording.png ~/.wysp/
fi

echo ""
echo "Installed wysp to ~/.local/bin/wysp"
echo ""

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo "Add ~/.local/bin to your PATH by adding this to ~/.bashrc or ~/.zshrc:"
    echo ""
    echo '  export PATH="$HOME/.local/bin:$PATH"'
    echo ""
fi

# Check for whisper model
if [ ! -f ~/.wysp/models/ggml-base.en.bin ] && [ ! -f ~/.ziew/models/whisper-base-en.bin ]; then
    echo "No whisper model found. Download one with:"
    echo ""
    echo "  curl -L -o ~/.wysp/models/ggml-base.en.bin \\"
    echo "    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
    echo ""
fi

echo "Run 'wysp' to start!"
