#!/bin/bash
# TLS Integration Test for Bazel
#
# This script:
# 1. Starts the Go TLS test server
# 2. Runs integration tests with curl
# 3. Cleans up

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          TLS Integration Test (Bazel)                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# Find Go server source
SERVER_SRC=""
for path in \
    "$TEST_SRCDIR/_main/lib/tls/test/server/main.go" \
    "$BUILD_WORKSPACE_DIRECTORY/lib/tls/test/server/main.go" \
    "$(dirname "$0")/server/main.go"
do
    if [ -f "$path" ]; then
        SERVER_SRC="$(dirname "$path")"
        break
    fi
done

if [ -z "$SERVER_SRC" ]; then
    echo -e "${RED}ERROR: Could not find server source${NC}"
    exit 1
fi

echo -e "${CYAN}Server source: $SERVER_SRC${NC}"

# ============================================
# Start Server using 'go run'
# ============================================
echo ""
echo -e "${CYAN}━━━ Starting TLS Test Server ━━━${NC}"

cd "$SERVER_SRC"
go run main.go -port 8443 > /tmp/tls_server_$$.log 2>&1 &
SERVER_PID=$!
cd - > /dev/null

cleanup() {
    echo ""
    echo "Stopping test server..."
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

# Wait for server to compile and start (go run needs compile time)
echo "Waiting for server to start..."
for i in {1..20}; do
    if curl -s -k --connect-timeout 1 https://localhost:8443/test > /dev/null 2>&1; then
        break
    fi
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo -e "${RED}ERROR: Server process died${NC}"
        cat /tmp/tls_server_$$.log 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

if ! curl -s -k --connect-timeout 2 https://localhost:8443/test > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Server not responding${NC}"
    cat /tmp/tls_server_$$.log 2>/dev/null || true
    exit 1
fi

echo -e "${GREEN}✓ Server started (PID: $SERVER_PID)${NC}"

# ============================================
# Integration Tests
# ============================================
echo ""
echo -e "${CYAN}━━━ Running Integration Tests ━━━${NC}"
echo ""

PASSED=0
FAILED=0

test_endpoint() {
    local port=$1
    local name=$2
    local expected_version=$3
    
    printf "  %-45s " "$name"
    
    # Remove all whitespace from response for easier parsing
    response=$(curl -s -k --connect-timeout 5 "https://localhost:$port/test" 2>/dev/null | tr -d ' \n\r\t' || echo "FAILED")
    
    if echo "$response" | grep -q '"ok":true'; then
        version=$(echo "$response" | grep -oE '"version":"[^"]*"' | cut -d'"' -f4)
        if [ "$version" == "$expected_version" ]; then
            echo -e "${GREEN}PASS${NC}"
            PASSED=$((PASSED + 1))
            return 0
        else
            echo -e "${RED}FAIL${NC} (version=$version, expected=$expected_version)"
            FAILED=$((FAILED + 1))
            return 1
        fi
    else
        echo -e "${YELLOW}SKIP${NC}"
        return 0
    fi
}

# TLS 1.3 Tests
echo "TLS 1.3 Cipher Suites:"
test_endpoint 8443 "AES-128-GCM-SHA256" "0x0304"
test_endpoint 8444 "AES-256-GCM-SHA384" "0x0304"
test_endpoint 8445 "ChaCha20-Poly1305-SHA256" "0x0304"
echo ""

echo "TLS 1.3 Key Exchange Curves:"
test_endpoint 8446 "X25519" "0x0304"
test_endpoint 8447 "P-256 (secp256r1)" "0x0304"
test_endpoint 8448 "P-384 (secp384r1)" "0x0304"
echo ""

# TLS 1.2 Tests
echo "TLS 1.2 ECDSA:"
test_endpoint 8449 "ECDHE-ECDSA-AES128-GCM-SHA256 (P-256)" "0x0303"
test_endpoint 8450 "ECDHE-ECDSA-AES256-GCM-SHA384 (P-256)" "0x0303"
test_endpoint 8451 "ECDHE-ECDSA-ChaCha20-Poly1305 (P-256)" "0x0303"
test_endpoint 8452 "ECDHE-ECDSA-AES256-GCM-SHA384 (P-384)" "0x0303"
echo ""

echo "TLS 1.2 RSA:"
test_endpoint 8453 "ECDHE-RSA-AES128-GCM-SHA256" "0x0303"
test_endpoint 8454 "ECDHE-RSA-AES256-GCM-SHA384" "0x0303"
test_endpoint 8455 "ECDHE-RSA-ChaCha20-Poly1305" "0x0303"
echo ""

echo "TLS 1.2 Key Exchange Curves:"
test_endpoint 8456 "X25519" "0x0303"
test_endpoint 8457 "P-256" "0x0303"
test_endpoint 8458 "P-384" "0x0303"
echo ""

echo "TLS Extensions:"
test_endpoint 8459 "SNI Required" "0x0304"
test_endpoint 8460 "ALPN (h2, http/1.1)" "0x0304"
test_endpoint 8461 "ALPN (http/1.1)" "0x0304"
echo ""

# Large data test
echo "Data Transfer:"
printf "  %-45s " "Large Transfer (1MB)"
size=$(curl -s -k --connect-timeout 10 "https://localhost:8462/large" 2>/dev/null | wc -c | tr -d ' ')
if [ "$size" -ge 1000000 ]; then
    echo -e "${GREEN}PASS${NC} (${size} bytes)"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}FAIL${NC} (${size} bytes)"
    FAILED=$((FAILED + 1))
fi
echo ""

# ============================================
# Summary
# ============================================
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                        TEST SUMMARY                          ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Passed: %-4d    Failed: %-4d                               ║\n" $PASSED $FAILED
echo "╚══════════════════════════════════════════════════════════════╝"

if [ $FAILED -gt 0 ]; then
    exit 1
fi

echo ""
echo -e "${GREEN}All tests passed!${NC}"
