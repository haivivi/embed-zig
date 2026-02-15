#!/bin/bash
# Common functions for BK7258 Bazel build scripts

# Setup Armino SDK environment
# Requires ARMINO_PATH (set via .bazelrc.user: build --//bazel:armino_path=/path/to/bk_avdk_smp)
setup_armino_env() {
    if [ -z "$ARMINO_PATH" ]; then
        echo "[bk] Error: ARMINO_PATH not set"
        echo "[bk] Add to .bazelrc.user:"
        echo "[bk]   build --//bazel:armino_path=/path/to/bk_avdk_smp"
        exit 1
    fi

    if [ ! -d "$ARMINO_PATH" ]; then
        echo "[bk] Error: ARMINO_PATH=$ARMINO_PATH does not exist"
        exit 1
    fi

    # Activate Python venv if available
    if [ -f "$ARMINO_PATH/venv/bin/activate" ]; then
        source "$ARMINO_PATH/venv/bin/activate"
    fi

    echo "[bk] Armino SDK: $ARMINO_PATH"
}

# Find bk_loader CLI tool
# Requires BK_LOADER_PATH (set via .bazelrc.user: build --action_env=BK_LOADER_PATH)
find_bk_loader() {
    if [ -n "$BK_LOADER_PATH" ] && [ -x "$BK_LOADER_PATH" ]; then
        export BK_LOADER="$BK_LOADER_PATH"
    else
        echo "[bk] Error: BK_LOADER_PATH not set or not executable"
        echo "[bk] Add to .bazelrc.user:"
        echo "[bk]   build --action_env=BK_LOADER_PATH=/path/to/bk_loader"
        exit 1
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
