#!/bin/bash
# Integration tests for the wsl-pty-bridge.
#
# Tests the bridge binary's ability to:
# 1. Launch a shell and execute commands
# 2. Parse and handle APC resize commands
# 3. Report exit status via APC
# 4. Handle stdin EOF gracefully
#
# Run from inside WSL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BRIDGE="$PROJECT_DIR/wsl-pty-bridge/target/debug/wsl-pty-bridge"

if [ ! -x "$BRIDGE" ]; then
    echo "Building bridge..."
    cd "$PROJECT_DIR/wsl-pty-bridge" && cargo build
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1 - $2"; FAILED=$((FAILED + 1)); }

echo "=== wsl-pty-bridge integration tests ==="
echo ""

# Helper: run bridge and capture output, ignoring the process exit code
# (the bridge exits with the shell's exit code)
run_bridge() {
    local input="$1"
    shift
    printf '%s' "$input" | timeout 5 "$BRIDGE" "$@" 2>/dev/null | cat -v || true
}

# Test 1: Bridge starts and reports exit status
echo "Test 1: Bridge starts and reports exit code"
OUTPUT=$(run_bridge $'exit 42\n' --shell /bin/sh --cols 80 --rows 24)
if echo "$OUTPUT" | grep -q "Gwsl;exit;42"; then
    pass "Exit code 42 reported correctly"
else
    fail "Exit code reporting" "Expected Gwsl;exit;42, got: $OUTPUT"
fi

# Test 2: Bridge reports exit code 0
echo "Test 2: Bridge reports exit code 0"
OUTPUT=$(run_bridge $'exit 0\n' --shell /bin/sh --cols 80 --rows 24)
if echo "$OUTPUT" | grep -q "Gwsl;exit;0"; then
    pass "Exit code 0 reported correctly"
else
    fail "Exit code 0 reporting" "Expected Gwsl;exit;0, got: $OUTPUT"
fi

# Test 3: APC resize command doesn't crash
echo "Test 3: APC resize command is handled"
OUTPUT=$(run_bridge $'\033_Gwsl;resize;120;40\033\\exit 0\n' --shell /bin/sh --cols 80 --rows 24)
if echo "$OUTPUT" | grep -q "Gwsl;exit;0"; then
    pass "Resize APC handled without crash"
else
    fail "Resize APC handling" "Bridge may have crashed: $OUTPUT"
fi

# Test 4: Custom shell argument
echo "Test 4: Custom shell argument"
OUTPUT=$(run_bridge $'exit 0\n' --shell /bin/bash --cols 80 --rows 24)
if echo "$OUTPUT" | grep -q "Gwsl;exit;0"; then
    pass "Custom shell (/bin/bash) works"
else
    fail "Custom shell" "Expected exit code, got: $OUTPUT"
fi

# Test 5: Default shell (from $SHELL)
echo "Test 5: Default shell from \$SHELL"
OUTPUT=$(run_bridge $'exit 0\n' --cols 80 --rows 24)
if echo "$OUTPUT" | grep -q "Gwsl;exit;0"; then
    pass "Default shell works"
else
    fail "Default shell" "Expected exit code, got: $OUTPUT"
fi

# Test 6: Help flag
echo "Test 6: --help flag"
OUTPUT=$("$BRIDGE" --help 2>&1 || true)
if echo "$OUTPUT" | grep -q "wsl-pty-bridge"; then
    pass "--help shows program name"
else
    fail "--help" "Expected help text, got: $OUTPUT"
fi

echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
