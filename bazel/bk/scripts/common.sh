#!/bin/bash
# Common functions for BK7258 Bazel build scripts

# Setup Armino SDK environment
setup_armino_env() {
    # Find Armino SDK
    if [ -z "$ARMINO_PATH" ]; then
        if [ -d "$HOME/armino/bk_avdk_smp" ]; then
            export ARMINO_PATH="$HOME/armino/bk_avdk_smp"
        else
            echo "[bk] Error: ARMINO_PATH not set and ~/armino/bk_avdk_smp not found"
            exit 1
        fi
    fi

    # Activate Python venv if available
    if [ -f "$ARMINO_PATH/venv/bin/activate" ]; then
        source "$ARMINO_PATH/venv/bin/activate"
    fi

    echo "[bk] Armino SDK: $ARMINO_PATH"
}

# Find bk_loader CLI tool
find_bk_loader() {
    if [ -z "$BK_LOADER" ]; then
        if [ -x "$HOME/armino/bk_loader/bk_loader" ]; then
            export BK_LOADER="$HOME/armino/bk_loader/bk_loader"
        else
            echo "[bk] Error: bk_loader not found at ~/armino/bk_loader/bk_loader"
            exit 1
        fi
    fi
    echo "[bk] bk_loader: $BK_LOADER"
}

# Detect serial port for BK7258 — port MUST be explicitly set
detect_bk_port() {
    local port_config="$1"
    local context="$2"

    if [ -n "$port_config" ]; then
        export PORT="$port_config"
    else
        echo "[$context] Error: port not specified"
        echo "[$context] Usage: bazel run //xxx:flash --//bazel:port=/dev/cu.usbserial-XXX"
        return 1
    fi
    echo "[$context] Port: $PORT"
}
