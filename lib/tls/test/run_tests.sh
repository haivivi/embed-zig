#!/bin/bash
# TLS Integration Test Runner
#
# This script:
# 1. Builds and starts the Go TLS test server
# 2. Runs the Zig TLS library tests
# 3. Optionally runs integration tests against the Go server
# 4. Cleans up
#
# Usage:
#   ./run_tests.sh          # Run unit tests only
#   ./run_tests.sh --full   # Run unit + integration tests

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")"
SERVER_DIR="$SCRIPT_DIR/server"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================"
echo "  Pure Zig TLS Library - Test Suite"
echo "========================================"
echo ""

# Check for --full flag
FULL_TEST=false
if [ "$1" == "--full" ]; then
    FULL_TEST=true
fi

# Step 1: Run Zig unit tests
echo -e "${YELLOW}[1/3] Running Zig unit tests...${NC}"
cd "$LIB_DIR"
if zig build test --summary all; then
    echo -e "${GREEN}✓ Unit tests passed${NC}"
else
    echo -e "${RED}✗ Unit tests failed${NC}"
    exit 1
fi
echo ""

if [ "$FULL_TEST" == "true" ]; then
    # Step 2: Build and start Go server
    echo -e "${YELLOW}[2/3] Starting Go TLS test server...${NC}"
    cd "$SERVER_DIR"
    
    # Build the server
    go build -o tls_test_server . 2>&1
    
    # Start server in background
    ./tls_test_server -port 8443 > /tmp/tls_test_server.log 2>&1 &
    SERVER_PID=$!
    
    # Cleanup function
    cleanup() {
        echo ""
        echo "Stopping test server..."
        kill $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
    }
    trap cleanup EXIT
    
    # Wait for server to start
    sleep 2
    
    # Verify server is running
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo -e "${RED}✗ Server failed to start${NC}"
        cat /tmp/tls_test_server.log
        exit 1
    fi
    
    echo -e "${GREEN}✓ Server started (PID: $SERVER_PID)${NC}"
    echo ""
    
    # Step 3: Run integration tests with curl
    echo -e "${YELLOW}[3/3] Running integration tests...${NC}"
    echo ""
    
    TESTS_PASSED=0
    TESTS_FAILED=0
    
    # Test each endpoint
    test_endpoint() {
        local name=$1
        local port=$2
        local expected_version=$3
        
        printf "  Testing %-35s " "$name..."
        
        response=$(curl -s -k "https://localhost:$port/test" 2>/dev/null)
        
        if echo "$response" | grep -q '"ok":true'; then
            actual_version=$(echo "$response" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
            if [ "$actual_version" == "$expected_version" ]; then
                echo -e "${GREEN}PASS${NC} (version=$actual_version)"
                TESTS_PASSED=$((TESTS_PASSED + 1))
                return 0
            else
                echo -e "${RED}FAIL${NC} (expected $expected_version, got $actual_version)"
                TESTS_FAILED=$((TESTS_FAILED + 1))
                return 1
            fi
        else
            echo -e "${RED}FAIL${NC} (bad response)"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            return 1
        fi
    }
    
    # TLS 1.3 tests
    echo "  TLS 1.3:"
    test_endpoint "tls13_aes128gcm" 8443 "0x0304"
    test_endpoint "tls13_aes256gcm" 8444 "0x0304"
    test_endpoint "tls13_chacha20" 8445 "0x0304"
    
    # TLS 1.2 ECDSA tests
    echo ""
    echo "  TLS 1.2 (ECDSA):"
    test_endpoint "tls12_ecdhe_ecdsa_aes128" 8446 "0x0303"
    test_endpoint "tls12_ecdhe_ecdsa_aes256" 8447 "0x0303"
    test_endpoint "tls12_ecdhe_ecdsa_chacha20" 8448 "0x0303"
    
    # TLS 1.2 RSA tests
    echo ""
    echo "  TLS 1.2 (RSA):"
    test_endpoint "tls12_ecdhe_rsa_aes128" 8449 "0x0303"
    test_endpoint "tls12_ecdhe_rsa_aes256" 8450 "0x0303"
    test_endpoint "tls12_ecdhe_rsa_chacha20" 8451 "0x0303"
    
    echo ""
    echo "========================================"
    echo "  Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
    echo "========================================"
    
    if [ $TESTS_FAILED -gt 0 ]; then
        exit 1
    fi
else
    echo -e "${YELLOW}[2/3] Skipped (use --full for integration tests)${NC}"
    echo -e "${YELLOW}[3/3] Skipped (use --full for integration tests)${NC}"
    echo ""
    echo "========================================"
    echo -e "  ${GREEN}All unit tests passed!${NC}"
    echo "========================================"
fi

echo ""
echo "Done."
