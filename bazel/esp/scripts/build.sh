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
#   ESP_WORK_DIR     - Work directory with copied files (preserves repo structure)
#   ESP_PROJECT_PATH - Project path relative to workspace (e.g., examples/esp/gpio_button/zig)
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
: "${ESP_PROJECT_PATH:?ESP_PROJECT_PATH not set}"
: "${ESP_EXECROOT:?ESP_EXECROOT not set}"

WORK="$ESP_WORK_DIR"
PROJECT_DIR="$WORK/$ESP_PROJECT_PATH"

# =============================================================================
# Main Build
# =============================================================================

main() {
    echo "[esp_build] Work directory: $WORK"
    echo "[esp_build] Project path: $ESP_PROJECT_PATH"
    echo "[esp_build] Board: $ESP_BOARD, Chip: $ESP_CHIP"

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

    # Build - use PROJECT_DIR which preserves the original repo structure
    cd "$PROJECT_DIR"
    idf.py set-target "$ESP_CHIP"
    
    # Build CMake arguments using array (safe for spaces/special chars in values)
    CMAKE_ARGS=()
    CMAKE_ARGS+=("-DZIG_BOARD=$ESP_BOARD")
    
    # Add WiFi settings if specified
    if [ -n "$ESP_WIFI_SSID" ]; then
        CMAKE_ARGS+=("-DCONFIG_WIFI_SSID=$ESP_WIFI_SSID")
        echo "[esp_build] WiFi SSID: $ESP_WIFI_SSID"
    fi
    if [ -n "$ESP_WIFI_PASSWORD" ]; then
        CMAKE_ARGS+=("-DCONFIG_WIFI_PASSWORD=$ESP_WIFI_PASSWORD")
    fi
    if [ -n "$ESP_TEST_SERVER_IP" ]; then
        CMAKE_ARGS+=("-DCONFIG_TEST_SERVER_IP=$ESP_TEST_SERVER_IP")
        echo "[esp_build] Test server IP: $ESP_TEST_SERVER_IP"
    fi
    
    idf.py "${CMAKE_ARGS[@]}" build

    # Copy outputs back to Bazel execroot
    cp "$PROJECT_DIR/build/$ESP_PROJECT_NAME.bin" "$ESP_EXECROOT/$ESP_BIN_OUT"
    cp "$PROJECT_DIR/build/$ESP_PROJECT_NAME.elf" "$ESP_EXECROOT/$ESP_ELF_OUT"

    echo "[esp_build] Build complete!"
}

main "$@"
