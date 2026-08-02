#!/bin/bash
# Integration tests for the wsl-pty-bridge.
#
# Tests the bridge binary's ability to:
# 1. Launch a shell and execute commands
# 2. Return the child exit status
# 3. Forward terminal input without buffering escape bytes
# 4. Handle custom and default shells
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
OUTPUT_FILE=$(mktemp)
trap 'rm -f "$OUTPUT_FILE"' EXIT

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1 - $2"; FAILED=$((FAILED + 1)); }

echo "=== wsl-pty-bridge integration tests ==="
echo ""

# Run the bridge and save its rendered output and process status.
run_bridge() {
    local input="$1"
    shift
    set +e
    { printf '%s' "$input"; sleep 0.5; } |
        timeout 5 "$BRIDGE" "$@" >"$OUTPUT_FILE" 2>/dev/null
    RUN_STATUS=${PIPESTATUS[1]}
    set -e
    RUN_OUTPUT=$(cat -v "$OUTPUT_FILE")
}

# Test 1: Bridge starts and returns the child exit status.
echo "Test 1: Bridge returns child exit code"
run_bridge $'exit 42\n' --shell /bin/sh --cols 80 --rows 24
if [ "$RUN_STATUS" -eq 42 ]; then
    pass "Exit code 42 returned correctly"
else
    fail "Exit code reporting" "Expected 42, got: $RUN_STATUS ($RUN_OUTPUT)"
fi

# Test 2: Normal terminal output is forwarded.
echo "Test 2: Bridge forwards terminal output"
run_bridge $'printf GHOSTWSL_RAW_OK\nexit 0\n' --shell /bin/sh --cols 80 --rows 24
if [ "$RUN_STATUS" -eq 0 ] && echo "$RUN_OUTPUT" | grep -q "GHOSTWSL_RAW_OK"; then
    pass "Terminal output forwarded"
else
    fail "Terminal output" "status=$RUN_STATUS output=$RUN_OUTPUT"
fi

# Test 3: A standalone ESC is delivered without waiting for another byte.
echo "Test 3: Standalone ESC is forwarded immediately"
set +e
{
    printf 'stty raw -echo; dd bs=1 count=1 2>/dev/null | od -An -t u1; exit\n'
    sleep 1
    printf '\033'
    sleep 0.25
} | timeout 5 "$BRIDGE" --shell /bin/sh --cols 80 --rows 24 >"$OUTPUT_FILE" 2>/dev/null
RUN_STATUS=${PIPESTATUS[1]}
set -e
RUN_OUTPUT=$(cat -v "$OUTPUT_FILE")
if [ "$RUN_STATUS" -eq 0 ] && echo "$RUN_OUTPUT" | grep -Eq '(^|[[:space:]])27([[:space:]]|$)'; then
    pass "Standalone ESC forwarded immediately"
else
    fail "Standalone ESC forwarding" "status=$RUN_STATUS output=$RUN_OUTPUT"
fi

# Test 4: Custom shell argument
echo "Test 4: Custom shell argument"
run_bridge $'exit 0\n' --shell /bin/bash --cols 80 --rows 24
if [ "$RUN_STATUS" -eq 0 ]; then
    pass "Custom shell (/bin/bash) works"
else
    fail "Custom shell" "Expected status 0, got: $RUN_STATUS ($RUN_OUTPUT)"
fi

# Test 5: Default shell (from $SHELL)
echo "Test 5: Default shell from \$SHELL"
run_bridge $'exit 0\n' --cols 80 --rows 24
if [ "$RUN_STATUS" -eq 0 ]; then
    pass "Default shell works"
else
    fail "Default shell" "Expected status 0, got: $RUN_STATUS ($RUN_OUTPUT)"
fi

# Test 6: Help flag
echo "Test 6: --help flag"
RUN_OUTPUT=$("$BRIDGE" --help 2>&1 || true)
if echo "$RUN_OUTPUT" | grep -q "wsl-pty-bridge"; then
    pass "--help shows program name"
else
    fail "--help" "Expected help text, got: $RUN_OUTPUT"
fi

echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
