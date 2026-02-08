#!/bin/bash
# mqtt0 Cross-Language Integration Tests (Bazel)
#
# Tests:
# 1. Zig client ↔ Zig broker (v4 + v5)
# 2. Zig client → Go broker (v4 + v5)
# 3. Go client → Zig broker (v4)

set -e

echo "╔══════════════════════════════════════════╗"
echo "║    mqtt0 Cross-Language Tests (Bazel)    ║"
echo "╚══════════════════════════════════════════╝"
echo ""

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }

BROKER_PID=""
cleanup() {
    if [ -n "$BROKER_PID" ]; then
        kill "$BROKER_PID" 2>/dev/null || true
        wait "$BROKER_PID" 2>/dev/null || true
        BROKER_PID=""
    fi
}
trap cleanup EXIT

find_free_port() {
    python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()"
}

# Find Zig
ZIG_BIN=""
if [ -n "$TEST_SRCDIR" ]; then
    for p in "$TEST_SRCDIR/zig_toolchain/zig" "$TEST_SRCDIR/_main/external/zig_toolchain/zig"; do
        [ -f "$p" ] && ZIG_BIN="$p" && break
    done
fi
[ -z "$ZIG_BIN" ] && ZIG_BIN=$(which zig 2>/dev/null || true)
[ -z "$ZIG_BIN" ] && { echo "ERROR: Zig not found"; exit 1; }

# Find source dirs
find_dir() {
    for path in "$TEST_SRCDIR/_main/$1" "$BUILD_WORKSPACE_DIRECTORY/$1" "$(dirname "$0")/../../../../$1"; do
        [ -d "$path" ] && echo "$path" && return
    done
}

MQTT0_SRC=$(find_dir "lib/pkg/mqtt0")
TRAIT_SRC=$(find_dir "lib/trait")
STD_SAL_SRC=$(find_dir "lib/platform/std")
# Find workspace root (for pre-built Go binaries)
WORKSPACE_ROOT=""
for path in "$BUILD_WORKSPACE_DIRECTORY" "$(dirname "$0")/../../../.."; do
    [ -n "$path" ] && [ -f "$path/MODULE.bazel" ] && WORKSPACE_ROOT="$(cd "$path" && pwd)" && break
done

# In Bazel local test mode, try to find workspace from TEST_SRCDIR
if [ -z "$WORKSPACE_ROOT" ] && [ -n "$TEST_SRCDIR" ]; then
    # runfiles path looks like .../execroot/_main/bazel-out/.../runfiles/_main/...
    # workspace is at execroot/_main
    candidate=$(echo "$TEST_SRCDIR" | sed 's|/bazel-out/.*||')
    [ -f "$candidate/MODULE.bazel" ] && WORKSPACE_ROOT="$candidate"
fi

TOOLS_DIR=""
[ -n "$WORKSPACE_ROOT" ] && TOOLS_DIR="$WORKSPACE_ROOT/tools"
info "WORKSPACE_ROOT=${WORKSPACE_ROOT:-not found}"

# Use workspace mqtt0 directory directly (avoid copy + rebuild overhead)
# Prefer BUILD_WORKSPACE_DIRECTORY for cached builds
if [ -n "$WORKSPACE_ROOT" ] && [ -d "$WORKSPACE_ROOT/lib/pkg/mqtt0/src" ]; then
    ZIG_MQTT0="$WORKSPACE_ROOT/lib/pkg/mqtt0"
else
    ZIG_MQTT0="$MQTT0_SRC"
fi
WORK=$(mktemp -d)
trap "rm -rf $WORK; cleanup" EXIT

# Pre-build Zig binaries
info "Pre-building Zig..."
cd "$ZIG_MQTT0" && "$ZIG_BIN" build 2>&1 | tail -1

# ============================================================================
# Test 1: Zig client ↔ Zig broker (v4 + v5)
# ============================================================================
info "Test 1: Zig client ↔ Zig broker (v4 + v5)"
cd "$ZIG_MQTT0"
output=$("$ZIG_BIN" build run-test 2>&1)
if echo "$output" | grep -q "All integration tests passed"; then
    pass "Zig client ↔ Zig broker (MQTT 3.1.1 + 5.0)"
else
    echo "$output"
    fail "Zig self-test failed"
fi

# ============================================================================
# Test 2: Zig client → Go broker (v4 + v5)
# ============================================================================
if [ -n "$TOOLS_DIR" ]; then
    info "Test 2: Zig client → Go broker"
    info "TOOLS_DIR=$TOOLS_DIR"

    # Find Go broker binary (pre-built)
    GO_BROKER="$TOOLS_DIR/mqtt_server/mqtt_server"
    if [ ! -x "$GO_BROKER" ]; then
        info "Go broker binary not found at $GO_BROKER, trying to build..."
        if command -v go &>/dev/null; then
            GO_BROKER="$WORK/mqtt_server_bin"
            cd "$TOOLS_DIR/mqtt_server"
            GOPROXY=https://goproxy.cn,direct go build -o "$GO_BROKER" . 2>&1 || { fail "Go broker build failed"; }
        else
            info "Go not available, skipping Test 2"
            GO_BROKER=""
        fi
    fi

    if [ -n "$GO_BROKER" ] && [ -x "$GO_BROKER" ]; then
        PORT=$(find_free_port)
        info "Starting Go broker on port $PORT..."
        "$GO_BROKER" -addr ":$PORT" >"$WORK/broker.log" 2>&1 &
        BROKER_PID=$!
        sleep 1

        if ! kill -0 "$BROKER_PID" 2>/dev/null; then
            info "Broker log:"; cat "$WORK/broker.log" 2>/dev/null
            fail "Go broker failed to start"
        fi
        info "Go broker started (PID $BROKER_PID)"

    # v4
    cd "$ZIG_MQTT0"
    output=$("$ZIG_BIN" build run-client -- --port "$PORT" 2>&1)
    if echo "$output" | grep -q "PASS"; then
        pass "Zig client → Go broker (MQTT 3.1.1)"
    else
        echo "$output"; fail "Zig client v4 → Go broker failed"
    fi

    # v5
    output=$("$ZIG_BIN" build run-client -- --port "$PORT" --v5 2>&1)
    if echo "$output" | grep -q "PASS"; then
        pass "Zig client → Go broker (MQTT 5.0)"
    else
        echo "$output"; fail "Zig client v5 → Go broker failed"
    fi

        kill "$BROKER_PID" 2>/dev/null; wait "$BROKER_PID" 2>/dev/null; BROKER_PID=""
    fi
else
    info "Skipping Test 2 (tools dir not found)"
fi

# ============================================================================
# Test 3: Go client → Zig broker (v4)
# ============================================================================
if [ -n "$TOOLS_DIR" ]; then
    info "Test 3: Go client → Zig broker"

    # Find Go client binary (pre-built)
    GO_CLIENT="$TOOLS_DIR/mqtt_client/mqtt_client"
    if [ ! -x "$GO_CLIENT" ]; then
        info "Go client binary not found at $GO_CLIENT, trying to build..."
        if command -v go &>/dev/null; then
            GO_CLIENT="$WORK/mqtt_client_bin"
            cd "$TOOLS_DIR/mqtt_client"
            GOPROXY=https://goproxy.cn,direct go build -o "$GO_CLIENT" . 2>&1 || { fail "Go client build failed"; }
        else
            info "Go not available, skipping Test 3"
            GO_CLIENT=""
        fi
    fi

    if [ -n "$GO_CLIENT" ] && [ -x "$GO_CLIENT" ]; then
        PORT=$(find_free_port)
        cd "$ZIG_MQTT0"
        "$ZIG_BIN" build run-broker -- --port "$PORT" --clients 1 >/dev/null 2>&1 &
        BROKER_PID=$!
        sleep 2

        if ! kill -0 "$BROKER_PID" 2>/dev/null; then
            fail "Zig broker failed to start"
        fi

        output=$("$GO_CLIENT" -addr "127.0.0.1:$PORT" -id "go-bazel" -pub "test/bazel" -msg "hello" 2>&1)
        if echo "$output" | grep -q "Published"; then
            pass "Go client → Zig broker (MQTT 3.1.1)"
        else
            echo "$output"; fail "Go client → Zig broker failed"
        fi

        wait "$BROKER_PID" 2>/dev/null; BROKER_PID=""
    fi
else
    info "Skipping Test 3 (tools dir not found)"
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║          All tests passed!               ║"
echo "╚══════════════════════════════════════════╝"
