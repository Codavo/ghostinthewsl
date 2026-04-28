#!/bin/bash
# Deploy the wsl-pty-bridge binary to WSL.
#
# This script copies the built bridge binary to /opt/ghostwsl/
# inside the specified WSL distribution.
#
# Usage:
#   ./scripts/deploy-bridge.sh              # Deploy to default distro
#   ./scripts/deploy-bridge.sh Ubuntu-22.04 # Deploy to specific distro
#   ./scripts/deploy-bridge.sh Ubuntu x64   # Deploy a specific bridge architecture

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

DISTRO="${1:-}"
ARCH="${2:-x64}"
INSTALL_DIR="/opt/ghostwsl"

case "$ARCH" in
    x64) BRIDGE_TARGET="x86_64-unknown-linux-musl" ;;
    arm64) BRIDGE_TARGET="aarch64-unknown-linux-musl" ;;
    *)
        echo "Error: unsupported architecture '$ARCH' (use x64 or arm64)."
        exit 1
        ;;
esac

BRIDGE_BINARY="$PROJECT_DIR/wsl-pty-bridge/target/$BRIDGE_TARGET/release/wsl-pty-bridge"

if [ ! -f "$BRIDGE_BINARY" ]; then
    # Fall back to debug build
    BRIDGE_BINARY="$PROJECT_DIR/wsl-pty-bridge/target/debug/wsl-pty-bridge"
fi

if [ ! -f "$BRIDGE_BINARY" ]; then
    echo "Error: wsl-pty-bridge binary not found. Run './scripts/build.sh bridge' first."
    exit 1
fi

echo "Deploying wsl-pty-bridge to WSL..."
echo "  Binary: $BRIDGE_BINARY"
echo "  Target: $INSTALL_DIR/wsl-pty-bridge"

# Create the installation directory inside WSL
if [ -n "$DISTRO" ]; then
    echo "  Distro: $DISTRO"
    wsl.exe -d "$DISTRO" -- sudo mkdir -p "$INSTALL_DIR"
    # Copy the binary (we're already in WSL, so just copy directly)
    sudo mkdir -p "$INSTALL_DIR"
    sudo cp "$BRIDGE_BINARY" "$INSTALL_DIR/wsl-pty-bridge"
    sudo chmod +x "$INSTALL_DIR/wsl-pty-bridge"
else
    echo "  Distro: (default)"
    sudo mkdir -p "$INSTALL_DIR"
    sudo cp "$BRIDGE_BINARY" "$INSTALL_DIR/wsl-pty-bridge"
    sudo chmod +x "$INSTALL_DIR/wsl-pty-bridge"
fi

echo "Deployed successfully!"
echo ""
echo "Verify with: /opt/ghostwsl/wsl-pty-bridge --help"
