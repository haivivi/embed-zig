#!/bin/bash
# Run TLS test server via Bazel
#
# Usage: bazel run //lib/tls/test:run_server

set -e

# Find the server binary
SERVER_BIN=""
for path in \
    "$BUILD_WORKSPACE_DIRECTORY/bazel-bin/lib/tls/test/tls_test_server_/tls_test_server" \
    "./lib/tls/test/tls_test_server_/tls_test_server" \
    "$(dirname "$0")/tls_test_server_/tls_test_server"
do
    if [ -f "$path" ]; then
        SERVER_BIN="$path"
        break
    fi
done

if [ -z "$SERVER_BIN" ]; then
    echo "ERROR: Could not find tls_test_server"
    echo "Try running: bazel build //lib/tls/test:tls_test_server"
    exit 1
fi

echo "Starting TLS test server..."
echo "Server: $SERVER_BIN"
echo ""

exec "$SERVER_BIN" "$@"
