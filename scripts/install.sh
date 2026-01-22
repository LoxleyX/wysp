#!/bin/sh
# Wysp installer
# Usage: curl -fsSL raw.githubusercontent.com/LoxleyX/wysp/main/scripts/install.sh | sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="$HOME/.local/bin"
WYSP_DIR="$HOME/.wysp"
MODELS_DIR="$WYSP_DIR/models"

print_banner() {
    echo ""
    echo "${CYAN}${BOLD}"
    echo "  ██╗    ██╗██╗   ██╗███████╗██████╗ "
    echo "  ██║    ██║╚██╗ ██╔╝██╔════╝██╔══██╗"
    echo "  ██║ █╗ ██║ ╚████╔╝ ███████╗██████╔╝"
    echo "  ██║███╗██║  ╚██╔╝  ╚════██║██╔═══╝ "
    echo "  ╚███╔███╔╝   ██║   ███████║██║     "
    echo "   ╚══╝╚══╝    ╚═╝   ╚══════╝╚═╝     "
    echo "${NC}"
    echo "  ${BOLD}Local voice-to-text for any application.${NC}"
    echo "  ${BOLD}100% offline. No cloud. No telemetry.${NC}"
    echo ""
}

info() {
    echo "${BLUE}::${NC} $1"
}

success() {
    echo "${GREEN}✓${NC}  $1"
}

warn() {
    echo "${YELLOW}!${NC}  $1"
}

error() {
    echo "${RED}✗${NC}  $1"
    exit 1
}

detect_platform() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case "$OS" in
        linux)
            case "$ARCH" in
                x86_64) PLATFORM="linux-x86_64" ;;
                aarch64) PLATFORM="linux-aarch64" ;;
                *) error "Unsupported architecture: $ARCH" ;;
            esac
            ;;
        darwin)
            case "$ARCH" in
                x86_64) PLATFORM="macos-x86_64" ;;
                arm64) PLATFORM="macos-aarch64" ;;
                *) error "Unsupported architecture: $ARCH" ;;
            esac
            ;;
        *) error "Unsupported OS: $OS" ;;
    esac
}

check_dependencies() {
    info "Checking dependencies..."

    # Check for required Linux packages
    if [ "$OS" = "linux" ]; then
        if ! pkg-config --exists gtk+-3.0 2>/dev/null; then
            warn "GTK3 not found. Install with:"
            echo "    sudo apt install libgtk-3-dev   # Debian/Ubuntu"
            echo "    sudo dnf install gtk3-devel     # Fedora"
            exit 1
        fi
        success "GTK3 found"
    fi
}

download_binary() {
    info "Downloading wysp..."

    RELEASE_URL="https://github.com/LoxleyX/wysp/releases/latest/download/wysp-${PLATFORM}.tar.gz"

    mkdir -p "$INSTALL_DIR"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$RELEASE_URL" | tar -xz -C /tmp
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$RELEASE_URL" | tar -xz -C /tmp
    else
        error "curl or wget required"
    fi

    mv /tmp/wysp-${PLATFORM}/wysp "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/wysp"

    # Copy icons
    mkdir -p "$WYSP_DIR"
    mv /tmp/wysp-${PLATFORM}/logo*.png "$WYSP_DIR/" 2>/dev/null || true

    rm -rf /tmp/wysp-${PLATFORM}

    success "Installed wysp to $INSTALL_DIR/wysp"
}

download_model() {
    info "Checking for whisper model..."

    mkdir -p "$MODELS_DIR"

    if [ -f "$MODELS_DIR/ggml-base.en.bin" ] || [ -f "$HOME/.ziew/models/whisper-base-en.bin" ]; then
        success "Whisper model already installed"
        return
    fi

    echo ""
    echo "  No whisper model found. Choose a model to download:"
    echo ""
    echo "    ${BOLD}1)${NC} tiny.en  (~75MB)  - Fastest, less accurate"
    echo "    ${BOLD}2)${NC} base.en  (~150MB) - Good balance ${GREEN}(recommended)${NC}"
    echo "    ${BOLD}3)${NC} small.en (~500MB) - More accurate, slower"
    echo "    ${BOLD}4)${NC} Skip - I'll download manually"
    echo ""
    printf "  Choice [2]: "
    read -r choice

    case "${choice:-2}" in
        1) MODEL="ggml-tiny.en.bin" ;;
        2) MODEL="ggml-base.en.bin" ;;
        3) MODEL="ggml-small.en.bin" ;;
        4)
            warn "Skipping model download"
            echo "  Download manually from: https://huggingface.co/ggerganov/whisper.cpp"
            return
            ;;
        *) MODEL="ggml-base.en.bin" ;;
    esac

    info "Downloading $MODEL (this may take a moment)..."

    MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar -o "$MODELS_DIR/$MODEL" "$MODEL_URL"
    else
        wget --show-progress -O "$MODELS_DIR/$MODEL" "$MODEL_URL"
    fi

    success "Model downloaded to $MODELS_DIR/$MODEL"
}

setup_path() {
    if echo "$PATH" | grep -q "$INSTALL_DIR"; then
        return
    fi

    warn "$INSTALL_DIR is not in your PATH"
    echo ""
    echo "  Add this to your ~/.bashrc or ~/.zshrc:"
    echo ""
    echo "    ${BOLD}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
    echo ""
}

print_success() {
    echo ""
    echo "${GREEN}${BOLD}Installation complete!${NC}"
    echo ""
    echo "  Run ${CYAN}wysp${NC} to start."
    echo ""
    echo "  ${BOLD}Usage:${NC}"
    echo "    Hold ${CYAN}Ctrl+Shift+Space${NC} to record"
    echo "    Release to transcribe and type"
    echo "    Right-click tray icon for options"
    echo ""
}

main() {
    print_banner
    detect_platform
    check_dependencies
    download_binary
    download_model
    setup_path
    print_success
}

main
