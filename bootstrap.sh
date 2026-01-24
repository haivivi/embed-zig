#!/bin/sh

set -bue

# Get the script's directory (top level)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_usage() {
    echo "Usage: $0 <version> <target> <mcpu>"
    echo "       $0 clean <version> [--all]"
    echo ""
    echo "Examples:"
    echo "  $0 espressif-0.15.x aarch64-macos-none baseline"
    echo "  $0 clean espressif-0.15.x         # Clean build artifacts only"
    echo "  $0 clean espressif-0.15.x --all   # Clean all (including downloads)"
    echo ""
    echo "Available versions:"
    cd "$SCRIPT_DIR"
    ls -d */ 2>/dev/null | grep -E "^espressif-" | sed 's/\/$//' || echo "  No version folders found"
}

# Check if parameters provided
if [ $# -eq 0 ]; then
    show_usage
    exit 1
fi

# Handle clean command
if [ "$1" = "clean" ]; then
    if [ $# -lt 2 ]; then
        echo "Error: clean requires version directory"
        show_usage
        exit 1
    fi
    
    VERSION_DIR="$2"
    CLEAN_ALL=false
    if [ $# -ge 3 ] && [ "$3" = "--all" ]; then
        CLEAN_ALL=true
    fi
    
    if [ ! -d "$SCRIPT_DIR/$VERSION_DIR" ]; then
        echo "Error: Version directory '$VERSION_DIR' does not exist"
        exit 1
    fi
    
    cd "$SCRIPT_DIR/$VERSION_DIR"
    echo "Cleaning $VERSION_DIR..."
    
    # Clean build directories
    for dir in .build .build-* .out; do
        if [ -e "$dir" ]; then
            echo "  Removing $dir..."
            rm -rf "$dir"
        fi
    done
    
    # Clean .cache if exists
    if [ -d .cache ]; then
        echo "  Removing .cache..."
        rm -rf .cache
    fi
    
    if [ "$CLEAN_ALL" = true ]; then
        # Also clean downloads
        if [ -d .downloads ]; then
            echo "  Removing .downloads..."
            rm -rf .downloads
        fi
        # Legacy .wget cleanup
        if [ -d .wget ]; then
            echo "  Removing .wget (legacy)..."
            rm -rf .wget
        fi
    fi
    
    echo "Clean complete!"
    exit 0
fi

VERSION_DIR="$1"
TARGET="$2"
MCPU="$3"

# Check if the version directory exists
if [ ! -d "$SCRIPT_DIR/$VERSION_DIR" ]; then
    echo "Error: Version directory '$VERSION_DIR' does not exist"
    exit 1
fi

# Change to the version directory
cd "$SCRIPT_DIR/$VERSION_DIR"

echo "Working in: $SCRIPT_DIR/$VERSION_DIR"
echo ""

echo "=== Step 1: Downloading and Extracting ==="
mkdir -p .downloads
pushd .downloads

# Download llvm-project (always tar.gz)
if [ ! -d llvm-project ]; then
    echo "Downloading llvm-project..."
    wget -i ../llvm-project -c -O llvm-project.tar.gz
    mkdir -p llvm-project
    tar -xf llvm-project.tar.gz --strip-components=1 -C llvm-project
else
    echo "Using cached llvm-project"
fi

# Download zig-bootstrap (supports both tar.gz URL and git URL)
if [ ! -d zig-bootstrap ]; then
    ZIG_BOOTSTRAP_LINE1=$(sed -n '1p' ../zig-bootstrap)
    ZIG_BOOTSTRAP_LINE2=$(sed -n '2p' ../zig-bootstrap)
    
    if echo "$ZIG_BOOTSTRAP_LINE1" | grep -q '\.tar\.gz$'; then
        # tar.gz URL format
        echo "Downloading zig-bootstrap via wget..."
        wget "$ZIG_BOOTSTRAP_LINE1" -c -O zig-bootstrap.tar.gz
        mkdir -p zig-bootstrap
        tar -xf zig-bootstrap.tar.gz --strip-components=1 -C zig-bootstrap
    else
        # git URL format (line1=repo, line2=tag)
        echo "Cloning zig-bootstrap (shallow) from $ZIG_BOOTSTRAP_LINE1 tag: $ZIG_BOOTSTRAP_LINE2..."
        git clone --depth 1 --branch "$ZIG_BOOTSTRAP_LINE2" "$ZIG_BOOTSTRAP_LINE1" zig-bootstrap
    fi
else
    echo "Using cached zig-bootstrap"
fi

popd


echo ""
echo "=== Step 2: Creating build folder ==="
BUILD_DIR=".build-${TARGET}-${MCPU}"
rm -rf "$BUILD_DIR" || true
mkdir -p "$BUILD_DIR"

pushd "$BUILD_DIR"

cp -R ../.downloads/zig-bootstrap/zig zig
cp -R ../.downloads/zig-bootstrap/zlib zlib
cp -R ../.downloads/zig-bootstrap/zstd zstd
cp -R ../.downloads/zig-bootstrap/build build
cp -R ../.downloads/llvm-project/llvm llvm
cp -R ../.downloads/llvm-project/clang clang
cp -R ../.downloads/llvm-project/lld lld
cp -R ../.downloads/llvm-project/cmake cmake

echo ""
echo "=== Step 3: Applying patch to $BUILD_DIR ==="
patch -p1 < ../espressif.patch
echo "patch applied successfully"

echo ""
echo "=== Step 4: Building Zig ==="
./build $TARGET $MCPU

popd

echo ""
echo "=== Copying output to .out/ ==="
mkdir -p .out
cp -R "$BUILD_DIR/out/zig-${TARGET}-${MCPU}" .out/

echo ""
echo "=== Build Complete ==="
echo "Output: .out/zig-${TARGET}-${MCPU}/"
ls -la ".out/zig-${TARGET}-${MCPU}/"
