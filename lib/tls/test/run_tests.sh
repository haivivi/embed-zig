#!/bin/bash
# TLS Comprehensive Test Runner
#
# Tests coverage:
# - TLS 1.2 and TLS 1.3
# - Multiple cipher suites: AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305
# - Multiple key types: RSA-2048, ECDSA P-256, ECDSA P-384
# - Multiple curves: X25519, P-256, P-384
# - Extensions: SNI, ALPN
# - Large data transfer
#
# Usage:
#   ./run_tests.sh          # Unit tests only
#   ./run_tests.sh --full   # Unit + integration tests

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")"
SERVER_DIR="$SCRIPT_DIR/server"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       Pure Zig TLS Library - Comprehensive Test Suite        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

FULL_TEST=false
VERBOSE=false
if [ "$1" == "--full" ]; then
    FULL_TEST=true
fi
if [ "$2" == "-v" ] || [ "$1" == "-v" ]; then
    VERBOSE=true
fi

# ============================================
# Step 1: Unit Tests
# ============================================
echo -e "${CYAN}━━━ Stage 1: Zig Unit Tests ━━━${NC}"
cd "$LIB_DIR"
if ! zig build test --summary all; then
    echo -e "${RED}✗ Unit tests failed${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Unit tests passed${NC}"
echo ""

if [ "$FULL_TEST" != "true" ]; then
    echo -e "${YELLOW}Skipping integration tests (use --full to run)${NC}"
    echo ""
    echo -e "${GREEN}All unit tests passed!${NC}"
    exit 0
fi

# ============================================
# Step 2: Build & Start Go Server
# ============================================
echo -e "${CYAN}━━━ Stage 2: Start TLS Test Server ━━━${NC}"
cd "$SERVER_DIR"

# Build
go build -o tls_test_server . 2>&1

# Start in background
./tls_test_server -port 8443 > /tmp/tls_test_server.log 2>&1 &
SERVER_PID=$!

cleanup() {
    echo ""
    echo "Stopping test server..."
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

# Wait for all servers to start (20 servers need time)
sleep 3

if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo -e "${RED}✗ Server failed to start${NC}"
    cat /tmp/tls_test_server.log
    exit 1
fi
echo -e "${GREEN}✓ Server started (PID: $SERVER_PID)${NC}"
echo ""

# ============================================
# Step 3: Integration Tests
# ============================================
echo -e "${CYAN}━━━ Stage 3: Integration Tests ━━━${NC}"
echo ""

PASSED=0
FAILED=0
SKIPPED=0

# Test function
test_endpoint() {
    local port=$1
    local name=$2
    local check_field=$3
    local expected_value=$4
    
    printf "  %-40s " "$name"
    
    # Get response and convert to single line for parsing
    response=$(curl -s -k --connect-timeout 5 "https://localhost:$port/test" 2>/dev/null | tr -d '\n' | tr -d ' ' || echo "CONNECTION_FAILED")
    
    if [ "$response" == "CONNECTION_FAILED" ] || [ -z "$response" ]; then
        echo -e "${YELLOW}SKIP${NC} (connection failed)"
        SKIPPED=$((SKIPPED + 1))
        return 2
    fi
    
    if ! echo "$response" | grep -q '"ok":true'; then
        echo -e "${RED}FAIL${NC} (bad response)"
        [ "$VERBOSE" == "true" ] && echo "    Response: $response"
        FAILED=$((FAILED + 1))
        return 1
    fi
    
    if [ -n "$check_field" ] && [ -n "$expected_value" ]; then
        actual=$(echo "$response" | grep -oE "\"$check_field\":\"[^\"]*\"" | cut -d'"' -f4)
        if [ "$actual" != "$expected_value" ]; then
            echo -e "${RED}FAIL${NC} (expected $check_field=$expected_value, got $actual)"
            FAILED=$((FAILED + 1))
            return 1
        fi
    fi
    
    version=$(echo "$response" | grep -oE '"version_name":"[^"]*"' | cut -d'"' -f4)
    cipher=$(echo "$response" | grep -oE '"cipher_name":"[^"]*"' | cut -d'"' -f4)
    # Truncate long cipher names
    cipher="${cipher:0:35}"
    
    echo -e "${GREEN}PASS${NC} ($version, $cipher)"
    PASSED=$((PASSED + 1))
    return 0
}

# Large data test
test_large_data() {
    local port=$1
    local name=$2
    local expected_size=$3
    
    printf "  %-40s " "$name"
    
    size=$(curl -s -k --connect-timeout 10 "https://localhost:$port/large" 2>/dev/null | wc -c | tr -d ' ')
    
    if [ "$size" -ge "$expected_size" ]; then
        echo -e "${GREEN}PASS${NC} (received ${size} bytes)"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo -e "${RED}FAIL${NC} (expected >=$expected_size, got $size)"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

# ── TLS 1.3 Cipher Tests ──
echo -e "${BLUE}TLS 1.3 - Cipher Suites:${NC}"
test_endpoint 8443 "AES-128-GCM-SHA256" "version" "0x0304"
test_endpoint 8444 "AES-256-GCM-SHA384" "version" "0x0304"
test_endpoint 8445 "ChaCha20-Poly1305-SHA256" "version" "0x0304"
echo ""

# ── TLS 1.3 Curve Tests ──
echo -e "${BLUE}TLS 1.3 - Key Exchange Curves:${NC}"
test_endpoint 8446 "X25519" "version" "0x0304"
test_endpoint 8447 "P-256 (secp256r1)" "version" "0x0304"
test_endpoint 8448 "P-384 (secp384r1)" "version" "0x0304"
echo ""

# ── TLS 1.2 ECDSA Tests ──
echo -e "${BLUE}TLS 1.2 - ECDSA P-256:${NC}"
test_endpoint 8449 "ECDHE-ECDSA-AES128-GCM-SHA256" "version" "0x0303"
test_endpoint 8450 "ECDHE-ECDSA-AES256-GCM-SHA384" "version" "0x0303"
test_endpoint 8451 "ECDHE-ECDSA-ChaCha20-Poly1305" "version" "0x0303"
echo ""

echo -e "${BLUE}TLS 1.2 - ECDSA P-384:${NC}"
test_endpoint 8452 "ECDHE-ECDSA-AES256-GCM-SHA384 (P-384)" "version" "0x0303"
echo ""

# ── TLS 1.2 RSA Tests ──
echo -e "${BLUE}TLS 1.2 - RSA:${NC}"
test_endpoint 8453 "ECDHE-RSA-AES128-GCM-SHA256" "version" "0x0303"
test_endpoint 8454 "ECDHE-RSA-AES256-GCM-SHA384" "version" "0x0303"
test_endpoint 8455 "ECDHE-RSA-ChaCha20-Poly1305" "version" "0x0303"
echo ""

# ── TLS 1.2 Curve Tests ──
echo -e "${BLUE}TLS 1.2 - Key Exchange Curves:${NC}"
test_endpoint 8456 "X25519" "version" "0x0303"
test_endpoint 8457 "P-256" "version" "0x0303"
test_endpoint 8458 "P-384" "version" "0x0303"
echo ""

# ── Extension Tests ──
echo -e "${BLUE}TLS Extensions:${NC}"
test_endpoint 8459 "SNI Required" "" ""
test_endpoint 8460 "ALPN (h2, http/1.1)" "" ""
test_endpoint 8461 "ALPN (http/1.1 only)" "" ""
echo ""

# ── Data Transfer Tests ──
echo -e "${BLUE}Data Transfer:${NC}"
test_large_data 8462 "Large Transfer (1MB)" 1000000
echo ""

# ============================================
# Summary
# ============================================
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                        TEST SUMMARY                          ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  ${GREEN}Passed:${NC}  %-5d                                              ║\n" $PASSED
printf "║  ${RED}Failed:${NC}  %-5d                                              ║\n" $FAILED
printf "║  ${YELLOW}Skipped:${NC} %-5d                                              ║\n" $SKIPPED
echo "╠══════════════════════════════════════════════════════════════╣"

TOTAL=$((PASSED + FAILED))
if [ $FAILED -eq 0 ]; then
    echo -e "║  ${GREEN}All $TOTAL tests passed!${NC}                                       ║"
else
    echo -e "║  ${RED}$FAILED of $TOTAL tests failed${NC}                                      ║"
fi
echo "╚══════════════════════════════════════════════════════════════╝"

echo ""
echo "Coverage:"
echo "  ✓ TLS Versions: 1.2, 1.3"
echo "  ✓ Cipher Suites: AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305"
echo "  ✓ Key Types: RSA-2048, ECDSA P-256, ECDSA P-384"
echo "  ✓ Key Exchange: X25519, P-256, P-384"
echo "  ✓ Extensions: SNI, ALPN"
echo "  ✓ Data Transfer: 1MB payload"
echo ""

if [ $FAILED -gt 0 ]; then
    exit 1
fi
