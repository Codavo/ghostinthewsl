#!/bin/bash
# Build raw Windows release assets for GhostInTheWSL.
#
# Produces:
# - dist/ghostinthewsl-<arch>.exe
# - dist/ghostinthewsl-<arch>-setup.exe (when Inno Setup is available)
#
# Usage:
#   ./scripts/package.sh release
#   ./scripts/package.sh release arm64

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_PROFILE="${1:-release}"
BUILD_ARCH="${2:-x64}"
APP_VERSION="${GHOSTINTHEWSL_APP_VERSION:-dev}"

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

artifact_stem() {
    case "${1:-x64}" in
        x64) echo "ghostinthewsl" ;;
        arm64) echo "ghostinthewsl-arm64" ;;
        *)
            error "Unsupported architecture: $1"
            exit 1
            ;;
    esac
}

inno_allowed_arch() {
    case "${1:-x64}" in
        x64) echo "x64os" ;;
        arm64) echo "arm64" ;;
        *)
            error "Unsupported architecture: $1"
            exit 1
            ;;
    esac
}

embed_bridge() {
    local embed_dest="$PROJECT_DIR/src/apprt/win32/wsl-pty-bridge.bin"

    if [ -n "${GHOSTWSL_BRIDGE_BIN:-}" ]; then
        cp "$GHOSTWSL_BRIDGE_BIN" "$embed_dest"
        info "Embedded prebuilt bridge binary from $GHOSTWSL_BRIDGE_BIN"
        return 0
    fi

    local target
    target="$(bridge_target "$BUILD_ARCH")"
    local bridge_bin="$PROJECT_DIR/wsl-pty-bridge/target/$target/release/wsl-pty-bridge"

    if [ ! -f "$bridge_bin" ]; then
        error "Bridge binary not found at $bridge_bin"
        error "Build it first or set GHOSTWSL_BRIDGE_BIN to a prebuilt bridge."
        exit 1
    fi

    cp "$bridge_bin" "$embed_dest"
    info "Embedded bridge binary: $(du -h "$embed_dest" | cut -f1)"
}

find_iscc() {
    local configured="${ISCC_BIN:-}"

    if [ -n "$configured" ]; then
        if [[ "$configured" =~ ^[A-Za-z]:\\ ]] && command -v cygpath >/dev/null 2>&1; then
            configured="$(cygpath -u "$configured")"
        fi
        if [ -f "$configured" ]; then
            printf '%s\n' "$configured"
            return 0
        fi
    fi

    if command -v ISCC.exe >/dev/null 2>&1; then
        command -v ISCC.exe
        return 0
    fi

    if [ -f "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" ]; then
        printf '%s\n' "/c/Program Files (x86)/Inno Setup 6/ISCC.exe"
        return 0
    fi

    return 1
}

ARTIFACT_STEM="$(artifact_stem "$BUILD_ARCH")"
PORTABLE_EXE="$PROJECT_DIR/dist/${ARTIFACT_STEM}.exe"
INSTALLER_EXE="$PROJECT_DIR/dist/${ARTIFACT_STEM}-setup.exe"

rm -f "$PORTABLE_EXE" "$INSTALLER_EXE"
mkdir -p "$PROJECT_DIR/dist"

info "Packaging GhostInTheWSL ($BUILD_PROFILE, $BUILD_ARCH)..."

if [ -z "${GHOSTWSL_BRIDGE_BIN:-}" ]; then
    info "Building wsl-pty-bridge..."
    cd "$PROJECT_DIR/wsl-pty-bridge"
    if [ "$BUILD_PROFILE" = "release" ]; then
        cargo build --target "$(bridge_target "$BUILD_ARCH")" --release 2>&1
    else
        cargo build --target "$(bridge_target "$BUILD_ARCH")" 2>&1
    fi
fi

embed_bridge

info "Building ghostinthewsl.exe..."
cd "$PROJECT_DIR"
if [ "$BUILD_PROFILE" = "release" ]; then
    zig build -Dapp-runtime=win32 -Dtarget="$(windows_target "$BUILD_ARCH")" -Doptimize=ReleaseFast 2>&1
else
    zig build -Dapp-runtime=win32 -Dtarget="$(windows_target "$BUILD_ARCH")" 2>&1
fi

GHOSTWSL_EXE="$PROJECT_DIR/zig-out/bin/ghostinthewsl.exe"
if [ ! -f "$GHOSTWSL_EXE" ]; then
    error "ghostinthewsl.exe not found at $GHOSTWSL_EXE"
    exit 1
fi

cp "$GHOSTWSL_EXE" "$PORTABLE_EXE"
info "Portable exe: $PORTABLE_EXE"

if ISCC_PATH="$(find_iscc)"; then
    info "Building Inno Setup installer..."
    MSYS2_ARG_CONV_EXCL='*' "$ISCC_PATH" \
        "/DMyAppVersion=$APP_VERSION" \
        "/DMyAppExeSource=$(cygpath -w "$PORTABLE_EXE")" \
        "/DMyAppExeName=ghostinthewsl.exe" \
        "/DMyOutputDir=$(cygpath -w "$PROJECT_DIR/dist")" \
        "/DMyOutputBaseFilename=${ARTIFACT_STEM}-setup" \
        "/DMyArchitecturesAllowed=$(inno_allowed_arch "$BUILD_ARCH")" \
        "/DMyArchitecturesInstallIn64BitMode=$(inno_allowed_arch "$BUILD_ARCH")" \
        "$(cygpath -w "$PROJECT_DIR/installer/windows.iss")"
    info "Installer exe: $INSTALLER_EXE"
else
    warn "Inno Setup compiler not found; skipping installer build."
fi
