#!/bin/bash
# BK7258 build script — dual target (AP + CP)
#
# Environment (set by bk_zig_app rule):
#   BK_PROJECT_NAME  — Project name
#   BK_AP_ZIG        — Path to AP app.zig
#   BK_CP_ZIG        — Path to CP base.zig (or custom)
#   BK_BK_ZIG        — Path to bk.zig (platform root)
#   BK_C_HELPERS     — C helper file paths (for AP)
#   BK_BIN_OUT       — Output all-app.bin path
#   ZIG_BIN          — Zig compiler path
#   E                — Exec root (absolute path)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"
setup_armino_env

WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

PROJECT="$BK_PROJECT_NAME"
echo "[bk_build] Project: $PROJECT"
echo "[bk_build] AP: $BK_AP_ZIG"
echo "[bk_build] CP: $BK_CP_ZIG"

# =========================================================================
# Helper: compile Zig → ARM static library
# Args: $1=name $2=app_zig $3=bk_zig $4=output_dir
# =========================================================================
compile_zig_lib() {
    local NAME="$1"
    local APP_ZIG="$2"
    local BK_ZIG="$3"
    local OUT_DIR="$4"

    mkdir -p "$OUT_DIR"

    # Generate build.zig
    cat > "$OUT_DIR/build.zig" << 'BUILDZIGEOF'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },
        .os_tag = .freestanding,
        .abi = .eabihf,
    });
    const optimize: std.builtin.OptimizeMode = .ReleaseSmall;

    const bk_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "$BK_ZIG_PLACEHOLDER" },
        .target = target,
        .optimize = optimize,
    });

    const root_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "$APP_ZIG_PLACEHOLDER" },
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("bk", bk_mod);

    const lib = b.addLibrary(.{
        .name = "$LIB_NAME_PLACEHOLDER",
        .linkage = .static,
        .root_module = root_mod,
    });
    b.installArtifact(lib);
}
BUILDZIGEOF

    # Replace placeholders
    sed -i.bak "s|\$BK_ZIG_PLACEHOLDER|$E/$BK_ZIG|g" "$OUT_DIR/build.zig"
    sed -i.bak "s|\$APP_ZIG_PLACEHOLDER|$E/$APP_ZIG|g" "$OUT_DIR/build.zig"
    sed -i.bak "s|\$LIB_NAME_PLACEHOLDER|$NAME|g" "$OUT_DIR/build.zig"
    rm -f "$OUT_DIR/build.zig.bak"

    # Minimal build.zig.zon
    cat > "$OUT_DIR/build.zig.zon" << ZONEOF
.{
    .name = .$NAME,
    .version = "0.1.0",
    .paths = .{ "build.zig", "build.zig.zon" },
}
ZONEOF

    # Get fingerprint
    cd "$OUT_DIR"
    ZIG_FP=$("$ZIG_BIN" build --fetch --cache-dir "$WORK/.zig-cache-$NAME" --global-cache-dir "$WORK/.zig-global-$NAME" 2>&1 || true)
    FP=$(echo "$ZIG_FP" | grep -o "suggested value: 0x[0-9a-f]*" | grep -o "0x[0-9a-f]*" || echo "")
    if [ -n "$FP" ]; then
        awk -v fp="$FP" '/.version = "0.1.0",/ { print; print "    .fingerprint = " fp ","; next } { print }' \
            build.zig.zon > build.zig.zon.new && mv build.zig.zon.new build.zig.zon
    fi

    # Build
    echo "[bk_build] Compiling $NAME Zig → ARM static lib..."
    "$ZIG_BIN" build \
        --cache-dir "$WORK/.zig-cache-$NAME" \
        --global-cache-dir "$WORK/.zig-global-$NAME" 2>&1

    # Find output
    local LIB=$(find "$OUT_DIR/zig-out" -name "*.a" | head -1)
    if [ -z "$LIB" ]; then
        echo "[bk_build] Error: no .a produced for $NAME"
        exit 1
    fi
    echo "[bk_build] $NAME lib: $LIB ($(wc -c < "$LIB") bytes)"
    cd "$E"
}

# =========================================================================
# Step 1: Compile AP and CP Zig libraries
# =========================================================================

compile_zig_lib "bk_zig_ap" "$BK_AP_ZIG" "$BK_BK_ZIG" "$WORK/zig_ap"
AP_LIB=$(find "$WORK/zig_ap/zig-out" -name "*.a" | head -1)

compile_zig_lib "bk_zig_cp" "$BK_CP_ZIG" "$BK_BK_ZIG" "$WORK/zig_cp"
CP_LIB=$(find "$WORK/zig_cp/zig-out" -name "*.a" | head -1)

echo "[bk_build] AP lib: $AP_LIB"
echo "[bk_build] CP lib: $CP_LIB"

if [ -z "$AP_LIB" ] || [ -z "$CP_LIB" ]; then
    echo "[bk_build] Error: Zig compilation failed"
    exit 1
fi

# =========================================================================
# Step 2: Generate Armino project
# =========================================================================

PROJECT_DIR="$WORK/projects/$PROJECT"
mkdir -p "$PROJECT_DIR/ap" "$PROJECT_DIR/cp" "$PROJECT_DIR/partitions/bk7258"

# Copy configs from audio_player_example
cp "$ARMINO_PATH/projects/audio_player_example/partitions/bk7258/auto_partitions.csv" "$PROJECT_DIR/partitions/bk7258/"
cp "$ARMINO_PATH/projects/audio_player_example/partitions/bk7258/ram_regions.csv" "$PROJECT_DIR/partitions/bk7258/"
mkdir -p "$PROJECT_DIR/ap/config/bk7258_ap" "$PROJECT_DIR/cp/config/bk7258"
cp "$ARMINO_PATH/projects/audio_player_example/ap/config/bk7258_ap/config" "$PROJECT_DIR/ap/config/bk7258_ap/"
cp "$ARMINO_PATH/projects/audio_player_example/cp/config/bk7258/config" "$PROJECT_DIR/cp/config/bk7258/"
cp "$ARMINO_PATH/projects/audio_player_example/ap/config/bk7258_ap/usr_gpio_cfg.h" "$PROJECT_DIR/ap/config/bk7258_ap/" 2>/dev/null || true
cp "$ARMINO_PATH/projects/audio_player_example/cp/config/bk7258/usr_gpio_cfg.h" "$PROJECT_DIR/cp/config/bk7258/" 2>/dev/null || true

# Makefile + CMakeLists
cat > "$PROJECT_DIR/Makefile" << 'EOF'
SDK_DIR ?= $(abspath ../..)
PROJECT_MAKE_FILE := $(SDK_DIR)/tools/build_tools/build_files/project_main.mk
ifeq ($(wildcard $(PROJECT_MAKE_FILE)),)
    $(error "$(PROJECT_MAKE_FILE) not exist")
endif
include $(PROJECT_MAKE_FILE)
EOF

cat > "$PROJECT_DIR/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.5)
include($ENV{ARMINO_TOOLS_PATH}/build_tools/cmake/project.cmake)
project(app)
EOF

# =========================================================================
# CP: bk_init + boot AP + run zig_cp_main() in task
# =========================================================================

cp "$CP_LIB" "$PROJECT_DIR/cp/libbk_zig_cp.a"

# CP also needs the core C helper (for bk_zig_log etc.)
cp "$E/lib/platform/bk/armino/src/bk_zig_helper.c" "$PROJECT_DIR/cp/"

cat > "$PROJECT_DIR/cp/cp_main.c" << 'CPEOF'
#include "bk_private/bk_init.h"
#include <components/system.h>
#include <os/os.h>
#include <modules/pm.h>
#include <driver/pwr_clk.h>
extern void rtos_set_user_app_entry(beken_thread_function_t entry);
extern void zig_cp_main(void);
static void zig_cp_task(void *arg) { zig_cp_main(); }
void user_app_main(void) {
    bk_pm_module_vote_boot_cp1_ctrl(PM_BOOT_CP1_MODULE_NAME_APP, PM_POWER_MODULE_STATE_ON);
    beken_thread_t t;
    rtos_create_thread(&t, 4, "zig_cp", (beken_thread_function_t)zig_cp_task, 8192, 0);
}
int main(void) {
    rtos_set_user_app_entry((beken_thread_function_t)user_app_main);
    bk_init();
    return 0;
}
CPEOF

cat > "$PROJECT_DIR/cp/CMakeLists.txt" << 'CPCMAKEOF'
set(incs .)
set(srcs cp_main.c bk_zig_helper.c)
armino_component_register(SRCS "${srcs}" INCLUDE_DIRS "${incs}")
target_link_libraries(${COMPONENT_LIB} INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/libbk_zig_cp.a)
CPCMAKEOF

# =========================================================================
# AP: bk_init + run zig_main() in task + C helpers
# =========================================================================

C_HELPER_SRCS=""
for helper in $BK_C_HELPERS; do
    bn=$(basename "$helper")
    cp "$E/$helper" "$PROJECT_DIR/ap/$bn"
    C_HELPER_SRCS="$C_HELPER_SRCS $bn"
done

cp "$AP_LIB" "$PROJECT_DIR/ap/libbk_zig_ap.a"

cat > "$PROJECT_DIR/ap/ap_main.c" << 'APEOF'
#include "bk_private/bk_init.h"
#include <components/system.h>
#include <os/os.h>
extern void zig_main(void);
static void zig_task(void *arg) { zig_main(); }
int main(void) {
    bk_init();
    beken_thread_t t;
    rtos_create_thread(&t, 4, "zig_ap", (beken_thread_function_t)zig_task, 16384, 0);
    return 0;
}
APEOF

cat > "$PROJECT_DIR/ap/CMakeLists.txt" << APCMAKEOF
set(incs .)
set(srcs ap_main.c $C_HELPER_SRCS)
set(priv_req lwip_intf_v2_1)
armino_component_register(SRCS "\${srcs}" INCLUDE_DIRS "\${incs}" PRIV_REQUIRES "\${priv_req}")
target_link_libraries(\${COMPONENT_LIB} INTERFACE \${CMAKE_CURRENT_SOURCE_DIR}/libbk_zig_ap.a)
APCMAKEOF

touch "$PROJECT_DIR/pj_config.mk"

# =========================================================================
# Step 3: Build with Armino
# =========================================================================

echo "[bk_build] Running Armino make..."
cd "$ARMINO_PATH"
rm -rf "build/bk7258/$PROJECT"
make bk7258 PROJECT="$PROJECT" PROJECT_DIR="$PROJECT_DIR" BUILD_DIR="$WORK/build" 2>&1

ALL_APP="$WORK/build/bk7258/$PROJECT/package/all-app.bin"
if [ ! -f "$ALL_APP" ]; then
    echo "[bk_build] Error: all-app.bin not found"
    exit 1
fi

cp "$ALL_APP" "$BK_BIN_OUT"
echo "[bk_build] Output: $BK_BIN_OUT ($(wc -c < "$BK_BIN_OUT") bytes)"
echo "[bk_build] Done!"
