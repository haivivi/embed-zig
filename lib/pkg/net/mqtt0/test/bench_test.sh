#!/bin/bash
# mqtt0 Benchmark runner for Bazel
set -e

ZIG_BIN=$(which zig 2>/dev/null || true)
[ -z "$ZIG_BIN" ] && { echo "ERROR: Zig not found"; exit 1; }

WORKSPACE_ROOT=""
for path in "$BUILD_WORKSPACE_DIRECTORY" "$(dirname "$0")/../../../.."; do
    [ -n "$path" ] && [ -f "$path/MODULE.bazel" ] && WORKSPACE_ROOT="$(cd "$path" && pwd)" && break
done
if [ -z "$WORKSPACE_ROOT" ] && [ -n "$TEST_SRCDIR" ]; then
    candidate=$(echo "$TEST_SRCDIR" | sed 's|/bazel-out/.*||')
    [ -f "$candidate/MODULE.bazel" ] && WORKSPACE_ROOT="$candidate"
fi

ZIG_MQTT0="${WORKSPACE_ROOT:-$(dirname "$0")/..}/lib/pkg/mqtt0"
[ -d "$ZIG_MQTT0/src" ] || ZIG_MQTT0="$(dirname "$0")/.."

cd "$ZIG_MQTT0"
echo "Running mqtt0 benchmarks (ReleaseFast)..."
"$ZIG_BIN" build run-bench
