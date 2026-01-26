#!/bin/bash
set -e

# Build script for GitHub Pages
# Can be run locally for testing: ./_site/build.sh
# Output goes to _site/docs and _site/api

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Building embed-zig documentation ==="
echo "Root: $ROOT_DIR"
echo "Output: $SCRIPT_DIR"

# Clean generated directories only
rm -rf "$SCRIPT_DIR/docs" "$SCRIPT_DIR/api"

# 1. Build mdBook (docs/ is already an mdBook project)
echo ">>> Building mdBook..."
if command -v mdbook &> /dev/null; then
    cd "$ROOT_DIR/docs"
    mdbook build -d "$SCRIPT_DIR/docs"
    cd "$ROOT_DIR"
else
    echo "Warning: mdbook not found, skipping mdBook build"
    mkdir -p "$SCRIPT_DIR/docs"
    echo "<h1>mdBook not installed</h1>" > "$SCRIPT_DIR/docs/index.html"
fi

# 2. Build Zig documentation
echo ">>> Building Zig documentation..."
if command -v zig &> /dev/null; then
    cd "$ROOT_DIR/lib"
    zig build-lib -femit-docs="$SCRIPT_DIR/api" docs.zig 2>/dev/null || {
        echo "Warning: Zig doc build failed, creating placeholder"
        mkdir -p "$SCRIPT_DIR/api"
        echo "<h1>API docs build failed</h1>" > "$SCRIPT_DIR/api/index.html"
    }
    cd "$ROOT_DIR"
else
    echo "Warning: zig not found, skipping Zig doc build"
    mkdir -p "$SCRIPT_DIR/api"
    echo "<h1>Zig not installed</h1>" > "$SCRIPT_DIR/api/index.html"
fi

echo "=== Build complete ==="
echo "Output: $SCRIPT_DIR"
ls -la "$SCRIPT_DIR"
