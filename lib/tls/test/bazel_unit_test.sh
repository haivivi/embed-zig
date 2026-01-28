#!/bin/bash
# TLS Unit Test for Bazel
#
# Runs Zig unit tests without the server.

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              TLS Unit Test (Bazel)                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Find Zig binary
ZIG_BIN=""

# Check Bazel runfiles
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

# Fallback to system zig
if [ -z "$ZIG_BIN" ]; then
    ZIG_BIN=$(which zig 2>/dev/null || true)
fi

if [ -z "$ZIG_BIN" ]; then
    echo "ERROR: Zig compiler not found"
    exit 1
fi

echo "Using Zig: $ZIG_BIN"
echo ""

# Find lib/tls source directory
TLS_DIR=""
for path in \
    "$TEST_SRCDIR/$TEST_WORKSPACE/lib/tls" \
    "$BUILD_WORKSPACE_DIRECTORY/lib/tls" \
    "$(dirname "$0")/.."
do
    if [ -d "$path/src" ]; then
        TLS_DIR="$path"
        break
    fi
done

if [ -z "$TLS_DIR" ]; then
    echo "ERROR: Could not find lib/tls directory"
    exit 1
fi

echo "TLS directory: $TLS_DIR"
echo ""

# Create temp directory and copy sources
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

echo "Setting up test environment..."

# Copy lib/tls
cp -r "$TLS_DIR" "$WORK_DIR/tls"

# Copy lib/crypto
CRYPTO_DIR=""
for path in \
    "$TEST_SRCDIR/$TEST_WORKSPACE/lib/crypto" \
    "$BUILD_WORKSPACE_DIRECTORY/lib/crypto" \
    "$(dirname "$0")/../../crypto"
do
    if [ -d "$path/src" ]; then
        CRYPTO_DIR="$path"
        break
    fi
done

if [ -n "$CRYPTO_DIR" ]; then
    cp -r "$CRYPTO_DIR" "$WORK_DIR/crypto"
fi

# Copy lib/trait  
TRAIT_DIR=""
for path in \
    "$TEST_SRCDIR/$TEST_WORKSPACE/lib/trait" \
    "$BUILD_WORKSPACE_DIRECTORY/lib/trait" \
    "$(dirname "$0")/../../trait"
do
    if [ -d "$path/src" ]; then
        TRAIT_DIR="$path"
        break
    fi
done

if [ -n "$TRAIT_DIR" ]; then
    cp -r "$TRAIT_DIR" "$WORK_DIR/trait"
fi

# Fix paths in build.zig.zon
cd "$WORK_DIR/tls"
if [ -f build.zig.zon ]; then
    sed -i.bak 's|"../trait"|"../trait"|g' build.zig.zon
    sed -i.bak 's|"../crypto"|"../crypto"|g' build.zig.zon
fi

echo "Running Zig tests..."
echo ""

"$ZIG_BIN" build test --summary all

echo ""
echo "Unit tests passed!"
