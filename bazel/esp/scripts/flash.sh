#!/bin/bash
# ESP-IDF Flash Script
# This script should be run via Bazel: bazel run //<target>:flash
set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Check Bazel environment
check_bazel_env "flash.sh" "//examples/apps/<project>:flash"

# Configuration from environment (set by Bazel)
: "${ESP_CHIP:=esp32s3}"
: "${ESP_BAUD:=460800}"
: "${ESP_BOARD:=esp32s3_devkit}"
: "${ESP_BIN:=}"
: "${ESP_PORT_CONFIG:=}"

# Validate binary path
if [ -z "$ESP_BIN" ] || [ ! -f "$ESP_BIN" ]; then
    echo "[esp_flash] Error: Binary file not found: $ESP_BIN"
    exit 1
fi

# Setup environment
setup_home
find_idf_python

# Detect serial port
if ! detect_serial_port "$ESP_PORT_CONFIG" "esp_flash"; then
    exit 1
fi

echo "[esp_flash] Board: $ESP_BOARD, Chip: $ESP_CHIP"
echo "[esp_flash] Flashing to $PORT at $ESP_BAUD baud..."
echo "[esp_flash] Binary: $ESP_BIN"

# Flash using esptool
"$IDF_PYTHON" -m esptool --chip "$ESP_CHIP" --port "$PORT" --baud "$ESP_BAUD" \
    --before default_reset --after hard_reset \
    write_flash -z 0x10000 "$ESP_BIN"

echo "[esp_flash] Flash complete!"
