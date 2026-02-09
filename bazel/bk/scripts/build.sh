#!/bin/bash
# BK7258 build script — invoked by bk_zig_app Bazel rule
#
# Environment variables (set by Bazel rule):
#   ARMINO_PATH         — Armino SDK root
#   BK_PROJECT_NAME     — Project name
#   BK_ZIG_OBJ          — Path to Zig .o file
#   BK_C_HELPERS         — Space-separated C helper file paths
#   BK_BIN_OUT          — Output all-app.bin path
#   BK_WORK_DIR         — Temporary work directory
#   BK_BOARD            — Board name (bk7258)

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"
setup_armino_env

PROJECT="$BK_PROJECT_NAME"
WORK="$BK_WORK_DIR"

echo "[bk_build] Project: $PROJECT"
echo "[bk_build] Zig .o: $BK_ZIG_OBJ"
echo "[bk_build] Work dir: $WORK"

# Create Armino project skeleton
PROJECT_DIR="$WORK/projects/$PROJECT"
mkdir -p "$PROJECT_DIR/ap" "$PROJECT_DIR/cp" "$PROJECT_DIR/partitions/bk7258"

# Copy partition and RAM config from audio_player_example (has audio support)
cp "$ARMINO_PATH/projects/audio_player_example/partitions/bk7258/auto_partitions.csv" "$PROJECT_DIR/partitions/bk7258/"
cp "$ARMINO_PATH/projects/audio_player_example/partitions/bk7258/ram_regions.csv" "$PROJECT_DIR/partitions/bk7258/"

# Copy AP and CP config from audio_player_example
mkdir -p "$PROJECT_DIR/ap/config/bk7258_ap" "$PROJECT_DIR/cp/config/bk7258"
cp "$ARMINO_PATH/projects/audio_player_example/ap/config/bk7258_ap/config" "$PROJECT_DIR/ap/config/bk7258_ap/"
cp "$ARMINO_PATH/projects/audio_player_example/cp/config/bk7258/config" "$PROJECT_DIR/cp/config/bk7258/"
# Copy usr_gpio_cfg.h if exists
cp "$ARMINO_PATH/projects/audio_player_example/ap/config/bk7258_ap/usr_gpio_cfg.h" "$PROJECT_DIR/ap/config/bk7258_ap/" 2>/dev/null || true
cp "$ARMINO_PATH/projects/audio_player_example/cp/config/bk7258/usr_gpio_cfg.h" "$PROJECT_DIR/cp/config/bk7258/" 2>/dev/null || true

# Top-level Makefile
cat > "$PROJECT_DIR/Makefile" << 'EOF'
SDK_DIR ?= $(abspath ../..)
PROJECT_MAKE_FILE := $(SDK_DIR)/tools/build_tools/build_files/project_main.mk
ifeq ($(wildcard $(PROJECT_MAKE_FILE)),)
    $(error "$(PROJECT_MAKE_FILE) not exist, please check sdk directory.")
endif
include $(PROJECT_MAKE_FILE)
EOF

# Top-level CMakeLists.txt
cat > "$PROJECT_DIR/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.5)
include($ENV{ARMINO_TOOLS_PATH}/build_tools/cmake/project.cmake)
project(app)
EOF

# CP main — boots AP + runs Zig
cat > "$PROJECT_DIR/cp/cp_main.c" << 'CPEOF'
#include "bk_private/bk_init.h"
#include <components/system.h>
#include <os/os.h>
#include <modules/pm.h>
#include <driver/pwr_clk.h>

extern void rtos_set_user_app_entry(beken_thread_function_t entry);
extern void zig_main(void);

static void zig_task(void *arg) {
    zig_main();
}

void user_app_main(void) {
    beken_thread_t t;
    bk_pm_module_vote_boot_cp1_ctrl(PM_BOOT_CP1_MODULE_NAME_APP, PM_POWER_MODULE_STATE_ON);
    rtos_create_thread(&t, 4, "zig_cp", (beken_thread_function_t)zig_task, 8192, 0);
}

int main(void) {
    rtos_set_user_app_entry((beken_thread_function_t)user_app_main);
    bk_init();
    return 0;
}
CPEOF

# AP main — simple init (audio runs on AP via separate Zig task if needed)
cat > "$PROJECT_DIR/ap/ap_main.c" << 'APEOF'
#include "bk_private/bk_init.h"
#include <components/system.h>
#include <os/os.h>

int main(void) {
    bk_init();
    return 0;
}
APEOF

# CP CMakeLists.txt — link Zig .o + C helpers
C_HELPER_SRCS=""
for helper in $BK_C_HELPERS; do
    basename=$(basename "$helper")
    cp "$helper" "$PROJECT_DIR/cp/$basename"
    C_HELPER_SRCS="$C_HELPER_SRCS $basename"
done

# Copy Zig .o
cp "$BK_ZIG_OBJ" "$PROJECT_DIR/cp/bk_zig.o"

cat > "$PROJECT_DIR/cp/CMakeLists.txt" << CPCMAKEOF
set(incs .)
set(srcs cp_main.c $C_HELPER_SRCS)
armino_component_register(SRCS "\${srcs}" INCLUDE_DIRS "\${incs}")
target_link_libraries(\${COMPONENT_LIB} INTERFACE \${CMAKE_CURRENT_SOURCE_DIR}/bk_zig.o)
CPCMAKEOF

# AP CMakeLists.txt
cat > "$PROJECT_DIR/ap/CMakeLists.txt" << 'APCMAKEOF'
set(incs .)
set(srcs ap_main.c)
armino_component_register(SRCS "${srcs}" INCLUDE_DIRS "${incs}")
APCMAKEOF

# pj_config.mk (empty)
touch "$PROJECT_DIR/pj_config.mk"

# Build with Armino
echo "[bk_build] Running: make bk7258 PROJECT=$PROJECT"
cd "$ARMINO_PATH"
rm -rf "build/bk7258/$PROJECT"
make bk7258 PROJECT="$PROJECT" PROJECT_DIR="$PROJECT_DIR" BUILD_DIR="$WORK/build" 2>&1

# Copy output
ALL_APP="$WORK/build/bk7258/$PROJECT/package/all-app.bin"
if [ ! -f "$ALL_APP" ]; then
    echo "[bk_build] Error: all-app.bin not found at $ALL_APP"
    ls -la "$WORK/build/bk7258/$PROJECT/package/" 2>/dev/null || true
    exit 1
fi

cp "$ALL_APP" "$BK_BIN_OUT"
echo "[bk_build] Output: $BK_BIN_OUT ($(wc -c < "$BK_BIN_OUT") bytes)"
echo "[bk_build] Done!"
