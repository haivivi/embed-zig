#!/bin/bash
# mqtt0 Unit + Integration Test for Bazel
#
# Runs:
#   1. Zig unit tests (packet, trie, mux)
#   2. Zig integration test (client ↔ broker, v4 + v5)

set -e

echo "╔══════════════════════════════════════════╗"
echo "║      mqtt0 Tests (Unit + Integration)    ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Find Zig binary
ZIG_BIN=""
if [ -n "$TEST_SRCDIR" ]; then
    for zig_path in \
        "$TEST_SRCDIR/zig_toolchain/zig" \
        "$TEST_SRCDIR/_main/external/zig_toolchain/zig"
    do
        if [ -f "$zig_path" ]; then
            ZIG_BIN="$zig_path"
            break
        fi
    done
fi
if [ -z "$ZIG_BIN" ]; then
    ZIG_BIN=$(which zig 2>/dev/null || true)
fi
if [ -z "$ZIG_BIN" ]; then
    echo "ERROR: Zig compiler not found"
    exit 1
fi
echo "Using Zig: $ZIG_BIN"

# Find source directories
find_dir() {
    local name=$1
    for path in \
        "$TEST_SRCDIR/_main/$name" \
        "$BUILD_WORKSPACE_DIRECTORY/$name" \
        "$(dirname "$0")/../../../../$name"
    do
        if [ -d "$path/src" ] || [ -d "$path" ]; then
            echo "$path"
            return
        fi
    done
}

MQTT0_SRC=$(find_dir "lib/pkg/mqtt0")
TRAIT_SRC=$(find_dir "lib/trait")
STD_SAL_SRC=$(find_dir "lib/platform/std")

if [ -z "$MQTT0_SRC" ]; then
    echo "ERROR: Could not find lib/pkg/mqtt0"
    exit 1
fi
echo "mqtt0 dir: $MQTT0_SRC"

# Create work directory with proper structure
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

mkdir -p "$WORK/lib/pkg/mqtt0" "$WORK/lib/trait" "$WORK/lib/platform/std"

cp -r "$MQTT0_SRC"/* "$WORK/lib/pkg/mqtt0/"
[ -n "$TRAIT_SRC" ] && cp -r "$TRAIT_SRC"/* "$WORK/lib/trait/"
[ -n "$STD_SAL_SRC" ] && cp -r "$STD_SAL_SRC"/* "$WORK/lib/platform/std/"

cd "$WORK/lib/pkg/mqtt0"

echo ""
echo "━━━ Unit Tests ━━━"
"$ZIG_BIN" build test --summary all
echo ""

echo "━━━ Integration Test (Zig client ↔ Zig broker) ━━━"
"$ZIG_BIN" build run-test
echo ""

echo "All mqtt0 tests passed!"
