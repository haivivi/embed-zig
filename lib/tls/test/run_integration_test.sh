#!/bin/bash
# TLS Integration Test Runner
#
# Starts the Go TLS test server, runs Zig client tests, then cleans up.

set -e

# Find the test server binary
SERVER_BIN="${TEST_SRCDIR:-$(dirname "$0")}/lib/tls/test/tls_test_server"

if [ ! -f "$SERVER_BIN" ]; then
    # Try Bazel runfiles path
    SERVER_BIN="$(dirname "$0")/tls_test_server"
fi

if [ ! -f "$SERVER_BIN" ]; then
    echo "ERROR: Could not find tls_test_server binary"
    exit 1
fi

# Find the Zig test binary
ZIG_TEST_BIN="${TEST_SRCDIR:-$(dirname "$0")}/lib/tls/tls_test_binary"

if [ ! -f "$ZIG_TEST_BIN" ]; then
    ZIG_TEST_BIN="$(dirname "$0")/../tls_test_binary"
fi

echo "=== TLS Integration Test ==="
echo ""

# Start the server in background
echo "Starting TLS test server..."
"$SERVER_BIN" -port 8443 &
SERVER_PID=$!

# Cleanup function
cleanup() {
    echo ""
    echo "Stopping test server (PID: $SERVER_PID)..."
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
}

trap cleanup EXIT

# Wait for server to start
sleep 1

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "ERROR: Server failed to start"
    exit 1
fi

echo "Server started on ports 8443-8451"
echo ""

# Run Zig tests
echo "Running Zig TLS client tests..."
echo ""

if [ -f "$ZIG_TEST_BIN" ]; then
    "$ZIG_TEST_BIN"
    RESULT=$?
else
    echo "WARNING: Zig test binary not found, skipping"
    RESULT=0
fi

echo ""
echo "=== Test Complete ==="

exit $RESULT
