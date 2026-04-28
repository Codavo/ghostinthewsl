#!/bin/bash
# GhostInTheWSL build script
#
# Builds both components:
# 1. wsl-pty-bridge (Rust, for Linux/WSL)
# 2. GhostInTheWSL (Zig, for Windows)
#
# Usage:
#   ./scripts/build.sh                    # Build both (debug, x64)
#   ./scripts/build.sh release            # Build both (release, x64)
#   ./scripts/build.sh all arm64 release  # Build both (release, arm64)
#   ./scripts/build.sh bridge arm64       # Build only the bridge
#   ./scripts/build.sh ghostty x64        # Build only GhostInTheWSL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

BUILD_MODE="${1:-all}"
BUILD_ARCH="${2:-x64}"
BUILD_PROFILE="${3:-debug}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

bridge_target() {
    case "${1:-x64}" in
        x64) echo "x86_64-unknown-linux-musl" ;;
        arm64) echo "aarch64-unknown-linux-musl" ;;
        *)
            error "Unsupported architecture: $1"
            exit 1
            ;;
    esac
}

windows_target() {
    case "${1:-x64}" in
        x64) echo "x86_64-windows-gnu" ;;
        arm64) echo "aarch64-windows-gnu" ;;
        *)
            error "Unsupported architecture: $1"
            exit 1
            ;;
    esac
}

build_bridge() {
    local target
    target="$(bridge_target "$BUILD_ARCH")"
    info "Building wsl-pty-bridge for $BUILD_ARCH ($target)..."
    cd "$PROJECT_DIR/wsl-pty-bridge"

    if [ "$BUILD_PROFILE" = "release" ]; then
        cargo build --target "$target" --release
        local binary="target/$target/release/wsl-pty-bridge"
        info "Bridge binary: $binary ($(du -h "$binary" | cut -f1))"
    else
        cargo build --target "$target"
        local binary="target/$target/debug/wsl-pty-bridge"
        info "Bridge binary: $binary"
    fi
}

embed_bridge() {
    local target
    target="$(bridge_target "$BUILD_ARCH")"
    local bridge_bin="$PROJECT_DIR/wsl-pty-bridge/target/$target/release/wsl-pty-bridge"
    local embed_dest="$PROJECT_DIR/src/apprt/win32/wsl-pty-bridge.bin"

    if [ ! -f "$bridge_bin" ]; then
        bridge_bin="$PROJECT_DIR/wsl-pty-bridge/target/$target/debug/wsl-pty-bridge"
    fi

    if [ ! -f "$bridge_bin" ]; then
        error "Bridge binary not found. Build the bridge first."
        return 1
    fi

    cp "$bridge_bin" "$embed_dest"
    info "Embedded bridge binary: $(du -h "$embed_dest" | cut -f1)"
}

build_ghostty() {
    local target
    target="$(windows_target "$BUILD_ARCH")"
    info "Building GhostInTheWSL for $BUILD_ARCH ($target)..."
    cd "$PROJECT_DIR"

    if ! command -v zig &>/dev/null; then
        error "Zig not found. Install Zig 0.15.2+ to build the Windows component."
        error "The Ghostty Win32 build must be done on Windows or via cross-compilation."
        return 1
    fi

    # Embed the bridge binary before building
    embed_bridge || return 1

    if [ "$BUILD_PROFILE" = "release" ]; then
        zig build -Dapp-runtime=win32 -Dtarget="$target" -Doptimize=ReleaseFast
    else
        zig build -Dapp-runtime=win32 -Dtarget="$target"
    fi

    info "Ghostty Win32 build complete."
}

run_bridge_tests() {
    info "Running wsl-pty-bridge tests..."
    cd "$PROJECT_DIR/wsl-pty-bridge"
    cargo test
    info "All bridge tests passed."
}

case "$BUILD_MODE" in
    all)
        build_bridge
        run_bridge_tests
        build_ghostty
        ;;
    bridge)
        build_bridge
        run_bridge_tests
        ;;
    ghostty)
        build_ghostty
        ;;
    release)
        BUILD_MODE="all"
        BUILD_PROFILE="release"
        build_bridge
        run_bridge_tests
        build_ghostty
        ;;
    test)
        run_bridge_tests
        ;;
    *)
        error "Unknown build mode: $BUILD_MODE"
        echo "Usage: $0 [all|bridge|ghostty|release|test] [x64|arm64] [debug|release]"
        exit 1
        ;;
esac

info "Build complete!"
