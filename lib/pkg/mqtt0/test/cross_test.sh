#!/bin/bash
# mqtt0 Cross-Language Integration Tests
#
# Tests:
# 1. Zig client ↔ Zig broker (loopback, v4 + v5)
# 2. Zig client → Go broker (v4 + v5)
# 3. Go client → Zig broker (v4)
#
# Usage:
#   ./cross_test.sh           # Run all tests
#   ./cross_test.sh zig-zig   # Run only zig-zig

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MQTT0_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$(cd "$MQTT0_DIR/../../../tools" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

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

# ============================================================================
# Test 1: Zig client ↔ Zig broker (v4 + v5)
# ============================================================================
test_zig_zig() {
    info "Test 1: Zig client ↔ Zig broker (v4 + v5)"
    cd "$MQTT0_DIR"
    output=$(zig build run-test 2>&1)
    if echo "$output" | grep -q "All integration tests passed"; then
        pass "Zig client ↔ Zig broker (MQTT 3.1.1 + 5.0)"
    else
        echo "$output"
        fail "Zig self-test failed"
    fi
}

# ============================================================================
# Test 2: Zig client → Go broker (v4 + v5)
# ============================================================================
test_zig_client_go_broker() {
    info "Test 2: Zig client → Go broker"

    local PORT=$(find_free_port)

    # Start Go broker
    "$TOOLS_DIR/mqtt_server/mqtt_server" -addr ":$PORT" &
    BROKER_PID=$!
    sleep 1

    if ! kill -0 "$BROKER_PID" 2>/dev/null; then
        fail "Go broker failed to start"
    fi

    # v4 test
    cd "$MQTT0_DIR"
    output=$(zig build run-client -- --port "$PORT" 2>&1)
    if echo "$output" | grep -q "PASS"; then
        pass "Zig client → Go broker (MQTT 3.1.1)"
    else
        echo "$output"
        fail "Zig client v4 failed against Go broker"
    fi

    # v5 test
    output=$(zig build run-client -- --port "$PORT" --v5 2>&1)
    if echo "$output" | grep -q "PASS"; then
        pass "Zig client → Go broker (MQTT 5.0)"
    else
        echo "$output"
        fail "Zig client v5 failed against Go broker"
    fi

    kill "$BROKER_PID" 2>/dev/null || true
    wait "$BROKER_PID" 2>/dev/null || true
    BROKER_PID=""
}

# ============================================================================
# Test 3: Go client → Zig broker (v4)
# ============================================================================
test_go_client_zig_broker() {
    info "Test 3: Go client → Zig broker"

    local PORT=$(find_free_port)

    # Start Zig broker (accept 1 client)
    cd "$MQTT0_DIR"
    zig build run-broker -- --port "$PORT" --clients 1 2>&1 &
    BROKER_PID=$!
    sleep 2

    if ! kill -0 "$BROKER_PID" 2>/dev/null; then
        fail "Zig broker failed to start"
    fi

    # Go client v4
    output=$("$TOOLS_DIR/mqtt_client/mqtt_client" -addr "127.0.0.1:$PORT" -id "go-cross-v4" -pub "test/from-go" -msg "hello-v4" 2>&1)
    if echo "$output" | grep -q "Published"; then
        pass "Go client → Zig broker (MQTT 3.1.1)"
    else
        echo "$output"
        fail "Go client v4 failed against Zig broker"
    fi

    wait "$BROKER_PID" 2>/dev/null || true
    BROKER_PID=""
}

# ============================================================================
# Main
# ============================================================================

echo "========================================="
echo "  mqtt0 Cross-Language Integration Tests"
echo "========================================="
echo ""

# Pre-build everything
info "Pre-building..."
cd "$MQTT0_DIR" && zig build 2>&1 >/dev/null

if command -v go &>/dev/null; then
    cd "$TOOLS_DIR/mqtt_server" && GOPROXY=https://goproxy.cn,direct go build -o mqtt_server . 2>&1 >/dev/null
    cd "$TOOLS_DIR/mqtt_client" && GOPROXY=https://goproxy.cn,direct go build -o mqtt_client . 2>&1 >/dev/null
fi
echo ""

TEST_NAME="${1:-all}"

case "$TEST_NAME" in
    zig-zig)
        test_zig_zig
        ;;
    zig-go)
        test_zig_client_go_broker
        ;;
    go-zig)
        test_go_client_zig_broker
        ;;
    all)
        test_zig_zig
        if command -v go &>/dev/null; then
            test_zig_client_go_broker
            test_go_client_zig_broker
        else
            info "Go not found, skipping cross-language tests"
        fi
        ;;
    *)
        echo "Usage: $0 [zig-zig|zig-go|go-zig|all]"
        exit 1
        ;;
esac

echo ""
echo "========================================="
echo "  All tests passed!"
echo "========================================="
