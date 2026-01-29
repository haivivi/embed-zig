#!/bin/bash
# Common functions for ESP-IDF Bazel rules
# This file should be sourced by other scripts

# =============================================================================
# Bazel Environment Check
# =============================================================================

# Check if running under Bazel
# Bazel sets BUILD_WORKSPACE_DIRECTORY when running executables
check_bazel_env() {
    local script_name="$1"
    local bazel_target="$2"
    
    if [ -z "$ESP_BAZEL_RUN" ]; then
        echo "Error: This script should be run via Bazel, not directly."
        echo ""
        echo "Usage:"
        echo "    bazel run $bazel_target"
        echo ""
        echo "Examples:"
        echo "    bazel run //examples/apps/led_strip_flash:flash"
        echo "    bazel run //bazel/esp:monitor"
        echo ""
        exit 1
    fi
}

# =============================================================================
# HOME Environment
# =============================================================================

setup_home() {
    if [ -z "$HOME" ]; then
        if [ -n "$IDF_PATH" ] && [[ "$IDF_PATH" =~ ^(/[^/]+/[^/]+)/ ]]; then
            export HOME="${BASH_REMATCH[1]}"
        else
            export HOME="/tmp"
        fi
    fi
}

# =============================================================================
# ESP-IDF Python Environment
# =============================================================================

# Find ESP-IDF Python interpreter
# Sets IDF_PYTHON variable
find_idf_python() {
    IDF_PYTHON=""
    if [ -d "$HOME/.espressif/python_env" ]; then
        for env_dir in "$HOME/.espressif/python_env"/idf*_env; do
            if [ -f "$env_dir/bin/python" ]; then
                IDF_PYTHON="$env_dir/bin/python"
            fi
        done
    fi
    
    if [ -z "$IDF_PYTHON" ]; then
        echo "[esp] Warning: ESP-IDF Python env not found, using system python3"
        IDF_PYTHON="python3"
    fi
    
    export IDF_PYTHON
}

# Setup full ESP-IDF environment (PATH with tools)
# Requires IDF_PATH to be set
setup_idf_env() {
    setup_home
    
    IDF_PYTHON_ENV=""
    if [ -d "$HOME/.espressif/python_env" ]; then
        for env_dir in "$HOME/.espressif/python_env"/idf*_env; do
            if [ -f "$env_dir/bin/python" ]; then
                IDF_PYTHON_ENV="$env_dir"
            fi
        done
    fi
    
    if [ -n "$IDF_PYTHON_ENV" ] && [ -f "$IDF_PYTHON_ENV/bin/python" ]; then
        echo "[esp] Using Python env: $IDF_PYTHON_ENV"
        
        # Build PATH with all ESP-IDF tools
        ESPRESSIF_TOOLS="$HOME/.espressif/tools"
        IDF_TOOLS_PATH=""
        if [ -d "$ESPRESSIF_TOOLS" ]; then
            while IFS= read -r bin_dir; do
                IDF_TOOLS_PATH="${bin_dir}:$IDF_TOOLS_PATH"
            done < <(find "$ESPRESSIF_TOOLS" -maxdepth 4 -type d -name "bin" 2>/dev/null)
        fi
        
        export PATH="$IDF_PYTHON_ENV/bin:$IDF_TOOLS_PATH$IDF_PATH/tools:$PATH"
        export IDF_PYTHON="$IDF_PYTHON_ENV/bin/python"
    else
        echo "[esp] Warning: Could not find ESP-IDF Python env, trying export.sh..."
        if [ -f "$IDF_PATH/export.sh" ]; then
            set +e
            source "$IDF_PATH/export.sh" > /dev/null 2>&1
            set -e
        fi
        export IDF_PYTHON="python3"
    fi
}

# =============================================================================
# Serial Port Detection
# =============================================================================

# Auto-detect serial port
# Sets PORT variable
# Args: $1 = configured_port (optional), $2 = command_name (for error messages)
detect_serial_port() {
    local configured_port="$1"
    local cmd_name="${2:-esp}"
    
    # Priority: configured > ESP_PORT env > auto-detect
    if [ -n "$configured_port" ]; then
        PORT="$configured_port"
        return 0
    fi
    
    if [ -n "$ESP_PORT" ]; then
        PORT="$ESP_PORT"
        return 0
    fi
    
    # Auto-detect (cross-platform)
    echo "[$cmd_name] Auto-detecting serial port..."
    
    # macOS: /dev/cu.usb*
    # Linux: /dev/ttyUSB* or /dev/ttyACM*
    PORTS=()
    for pattern in /dev/cu.usb* /dev/ttyUSB* /dev/ttyACM*; do
        for p in $pattern; do
            [ -e "$p" ] && PORTS+=("$p")
        done
    done
    
    if [ ${#PORTS[@]} -eq 0 ]; then
        echo "[$cmd_name] Error: No USB serial ports found"
        echo "[$cmd_name] Please connect your ESP32 board or specify port:"
        echo ""
        echo "    bazel run <target> --//bazel/esp:port=/dev/xxx"
        echo ""
        echo "  Or set environment variable:"
        echo "    export ESP_PORT=/dev/xxx"
        return 1
    elif [ ${#PORTS[@]} -eq 1 ]; then
        PORT="${PORTS[0]}"
        echo "[$cmd_name] Auto-detected: $PORT"
        return 0
    else
        echo "[$cmd_name] Multiple serial ports found:"
        for i in "${!PORTS[@]}"; do
            echo "  [$i] ${PORTS[$i]}"
        done
        echo ""
        echo "[$cmd_name] Please specify port:"
        echo "    bazel run <target> --//bazel/esp:port=${PORTS[0]}"
        return 1
    fi
}
