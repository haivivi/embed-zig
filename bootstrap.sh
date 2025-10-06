#!/bin/sh

set -bue

# Check if version parameter is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <version> <target> <mcpu>"
    echo "Example: $0 0.15.x native-macos-none baseline"
    echo ""
    echo "Available versions:"
    ls -d */ 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.x/$" | sed 's/\/$//' || echo "  No version folders found"
    exit 1
fi

VERSION_DIR="$1"
TARGET="$2"
MCPU="$3"

# Get the script's directory (top level)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
mkdir -p .wget
pushd .wget
wget -i ../llvm-project -c -O llvm-project.tar.gz
mkdir -p llvm-project
tar -xf llvm-project.tar.gz --strip-components=1 -C llvm-project

wget -i ../zig-bootstrap -c -O zig-bootstrap.tar.gz
mkdir -p zig-bootstrap
tar -xf zig-bootstrap.tar.gz --strip-components=1 -C zig-bootstrap
popd


echo ""
echo "=== Step 2: Creating .build folder ==="
rm -rf .build || true
mkdir -p .build
ln -sf .build/out .out

pushd .build

cp -R ../.wget/zig-bootstrap/zig zig
cp -R ../.wget/zig-bootstrap/zlib zlib
cp -R ../.wget/zig-bootstrap/zstd zstd
cp -R ../.wget/zig-bootstrap/build build
cp -R ../.wget/llvm-project/llvm llvm
cp -R ../.wget/llvm-project/clang clang
cp -R ../.wget/llvm-project/lld lld
cp -R ../.wget/llvm-project/cmake cmake

echo ""
echo "=== Step 3: Applying patch to .build folder ==="
git apply ../espressif.patch
echo "patch applied successfully"

echo ""
echo "=== Step 4: Building Zig ==="
./build.sh $TARGET $MCPU
echo "Zig built successfully"
