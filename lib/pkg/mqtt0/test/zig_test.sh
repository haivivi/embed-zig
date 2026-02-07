#!/bin/bash
# mqtt0 Zig self-test — broker + client loopback for v4 and v5.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MQTT0_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$MQTT0_DIR"

echo "Running mqtt0 unit tests..."
zig build test

echo ""
echo "Running mqtt0 integration test (zig broker + zig client)..."
zig build run-test

echo ""
echo "All mqtt0 Zig tests passed!"
