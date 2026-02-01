#!/bin/bash
# Run the TLS test server
#
# Usage: ./run_server.sh [OPTIONS]
#
# Options are passed directly to the Go server.

set -e

SCRIPT_DIR="$(dirname "$0")"
cd "$SCRIPT_DIR/server"

echo "Starting TLS test server..."
echo "Press Ctrl+C to stop."
echo ""

go run main.go "$@"
