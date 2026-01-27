#!/bin/bash
# ESP-IDF Build Script
# This script should be run via Bazel: bazel build //<target>:app
#
# Required environment variables (set by wrapper):
#   ESP_BOARD        - Board name (e.g., esp32s3_devkit)
#   ESP_CHIP         - Chip type (e.g., esp32s3)
#   ESP_PROJECT_NAME - Project name for output files
#   ESP_BIN_OUT      - Output path for .bin file
#   ESP_ELF_OUT      - Output path for .elf file
#   ZIG_INSTALL      - Path to Zig installation
#   ESP_WORK_DIR     - Work directory with copied files
#   ESP_EXECROOT     - Bazel execroot for output
set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Check Bazel environment
check_bazel_env "build.sh" "//examples/esp/<project>/zig:app"

# Validate required variables
: "${ESP_BOARD:?ESP_BOARD not set}"
: "${ESP_CHIP:?ESP_CHIP not set}"
: "${ESP_PROJECT_NAME:?ESP_PROJECT_NAME not set}"
: "${ESP_BIN_OUT:?ESP_BIN_OUT not set}"
: "${ESP_ELF_OUT:?ESP_ELF_OUT not set}"
: "${ESP_WORK_DIR:?ESP_WORK_DIR not set}"
: "${ESP_EXECROOT:?ESP_EXECROOT not set}"

WORK="$ESP_WORK_DIR"

# =============================================================================
# Path Rewriting
# =============================================================================

rewrite_cmake_paths() {
    # Update CMakeLists.txt files to point to correct paths
    if [ -f "$WORK/project/CMakeLists.txt" ]; then
        sed -i.bak "s|\${CMAKE_CURRENT_SOURCE_DIR}/../../../../cmake/|$WORK/cmake/|g" "$WORK/project/CMakeLists.txt" 2>/dev/null || true
    fi

    # Update main/CMakeLists.txt to point to correct lib path
    if [ -f "$WORK/project/main/CMakeLists.txt" ]; then
        sed -i.bak "s|\${CMAKE_CURRENT_SOURCE_DIR}/../../../../../lib/|$WORK/lib/|g" "$WORK/project/main/CMakeLists.txt" 2>/dev/null || true
        sed -i.bak "s|\${CMAKE_CURRENT_SOURCE_DIR}/../../../../lib/|$WORK/lib/|g" "$WORK/project/main/CMakeLists.txt" 2>/dev/null || true
        sed -i.bak "s|\${CMAKE_CURRENT_SOURCE_DIR}/../../../lib/|$WORK/lib/|g" "$WORK/project/main/CMakeLists.txt" 2>/dev/null || true
        sed -i.bak "s|\${CMAKE_CURRENT_SOURCE_DIR}/../../lib/|$WORK/lib/|g" "$WORK/project/main/CMakeLists.txt" 2>/dev/null || true
    fi
}

rewrite_zig_paths() {
    # Update build.zig.zon to point to correct lib and apps paths
    if [ -f "$WORK/project/main/build.zig.zon" ]; then
        sed -i.bak 's|"../../../../../lib/|"../../lib/|g' "$WORK/project/main/build.zig.zon" 2>/dev/null || true
        sed -i.bak 's|"../../../../lib/|"../../lib/|g' "$WORK/project/main/build.zig.zon" 2>/dev/null || true
        sed -i.bak 's|"../../../lib/|"../../lib/|g' "$WORK/project/main/build.zig.zon" 2>/dev/null || true
        sed -i.bak 's|"../../../../apps/|"../../apps/|g' "$WORK/project/main/build.zig.zon" 2>/dev/null || true
        sed -i.bak 's|"../../../apps/|"../../apps/|g' "$WORK/project/main/build.zig.zon" 2>/dev/null || true
    fi

    # Update apps build.zig.zon files
    for zon_file in "$WORK/apps/"*/build.zig.zon; do
        if [ -f "$zon_file" ]; then
            sed -i.bak 's|"../../../lib/|"../../lib/|g' "$zon_file" 2>/dev/null || true
            sed -i.bak 's|"../../../../lib/|"../../lib/|g' "$zon_file" 2>/dev/null || true
        fi
    done
}

# =============================================================================
# Main Build
# =============================================================================

main() {
    echo "[esp_build] Work directory: $WORK"
    echo "[esp_build] Board: $ESP_BOARD, Chip: $ESP_CHIP"

    # Rewrite paths
    rewrite_cmake_paths
    rewrite_zig_paths

    # Setup environment
    export ZIG_BOARD="$ESP_BOARD"
    setup_home

    echo "[esp_build] IDF_PATH: $IDF_PATH"
    echo "[esp_build] ZIG_INSTALL: $ZIG_INSTALL"
    echo "[esp_build] ZIG_BOARD: $ZIG_BOARD"

    # Setup ESP-IDF environment
    setup_idf_env

    # Verify idf.py is available
    if ! command -v idf.py &> /dev/null; then
        echo "[esp_build] Error: idf.py not found"
        echo "[esp_build] PATH: $PATH"
        exit 1
    fi

    # Build
    cd "$WORK/project"
    idf.py set-target "$ESP_CHIP"
    idf.py -DZIG_BOARD="$ESP_BOARD" build

    # Copy outputs back to Bazel execroot
    cp "$WORK/project/build/$ESP_PROJECT_NAME.bin" "$ESP_EXECROOT/$ESP_BIN_OUT"
    cp "$WORK/project/build/$ESP_PROJECT_NAME.elf" "$ESP_EXECROOT/$ESP_ELF_OUT"

    echo "[esp_build] Build complete!"
}

main "$@"
