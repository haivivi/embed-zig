#!/bin/bash
# ESP-IDF Serial Monitor Script
# This script should be run via Bazel: bazel run //<target>:monitor
set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Check Bazel environment
check_bazel_env "monitor.sh" "//bazel/esp:monitor"

# Configuration from environment (set by Bazel)
: "${ESP_BOARD:=esp32s3_devkit}"
: "${ESP_MONITOR_BAUD:=115200}"
: "${ESP_PORT_CONFIG:=}"

# Setup environment
setup_home
find_idf_python

# Detect serial port
if ! detect_serial_port "$ESP_PORT_CONFIG" "esp_monitor"; then
    exit 1
fi

echo "[esp_monitor] Board: $ESP_BOARD"
echo "[esp_monitor] Monitoring $PORT at $ESP_MONITOR_BAUD baud..."
echo "[esp_monitor] Press Ctrl+C to exit"

# Use Python serial monitor
"$IDF_PYTHON" -c "
import serial
import sys

try:
    ser = serial.Serial('$PORT', $ESP_MONITOR_BAUD, timeout=0.1)
    print('Connected to $PORT')
    while True:
        if ser.in_waiting:
            line = ser.readline().decode('utf-8', errors='replace')
            sys.stdout.write(line)
            sys.stdout.flush()
except KeyboardInterrupt:
    print('\nMonitor stopped.')
except Exception as e:
    print(f'Error: {e}')
    sys.exit(1)
"
