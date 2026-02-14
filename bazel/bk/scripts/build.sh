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

    # Always generate main.zig + env.zig for AP (like ESP pattern)
    local ROOT_ZIG="$E/$APP_ZIG"
    if [ "$NAME" = "bk_zig_ap" ]; then
        # Generate env.zig from env file
        {
            echo 'pub const Env = struct {'
            if [ -n "$BK_ENV_FILE" ] && [ -f "$E/$BK_ENV_FILE" ]; then
                while IFS='=' read -r key value || [ -n "$key" ]; do
                    key=$(echo "$key" | tr -d '"' | tr -d ' ')
                    value=$(echo "$value" | tr -d '"')
                    [ -z "$key" ] && continue
                    [[ "$key" == \#* ]] && continue
                    local field=$(echo "$key" | tr '[:upper:]' '[:lower:]')
                    echo "    ${field}: []const u8 = \"${value}\","
                done < "$E/$BK_ENV_FILE"
            fi
            echo '};'
            echo 'pub const env = Env{};'
        } > "$OUT_DIR/env.zig"

        # Generate main.zig bridge
        cat > "$OUT_DIR/main.zig" << 'MAINEOF'
const app = @import("app");
const env_module = @import("env");
const impl = @import("bk");
pub const std_options = @import("std").Options{ .logFn = impl.impl.stdLogFn };
export fn zig_main() callconv(.c) void {
    app.run(env_module.env);
}
MAINEOF
        ROOT_ZIG="$OUT_DIR/main.zig"
        echo "[bk_build] Generated main.zig + env.zig"
    fi

    # Generate build.zig dynamically with all dep modules
    {
        echo 'const std = @import("std");'
        echo 'pub fn build(b: *std.Build) void {'
        echo '    const target = b.resolveTargetQuery(.{'
        echo '        .cpu_arch = .thumb,'
        echo '        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },'
        echo '        .os_tag = .freestanding,'
        echo '        .abi = .eabihf,'
        echo '    });'
        echo '    const optimize: std.builtin.OptimizeMode = .ReleaseSmall;'
        echo ''

        # Declare each dep module
        local mod_idx=0
        for entry in $BK_MODULES; do
            local mod_name="${entry%%:*}"
            local mod_path="${entry#*:}"
            echo "    const mod_${mod_idx} = b.createModule(.{"
            echo "        .root_source_file = .{ .cwd_relative = \"$E/$mod_path\" },"
            echo '        .target = target,'
            echo '        .optimize = optimize,'
            echo '    });'
            mod_idx=$((mod_idx + 1))
        done

        # App module (always for AP — generated main.zig imports this)
        if [ "$NAME" = "bk_zig_ap" ]; then
            # Generate build_options module (provides .board enum)
            cat > "$OUT_DIR/build_options.zig" << 'OPTEOF'
pub const Board = enum {
    bk7258,
    // ESP boards (needed for platform.zig switch exhaustiveness)
    esp32s3_devkit,
    korvo2_v3,
    lichuang_szp,
    lichuang_gocool,
    sim_raylib,
};
pub const board: Board = .bk7258;
OPTEOF
            echo "    const build_options_mod = b.createModule(.{"
            echo "        .root_source_file = .{ .cwd_relative = \"$OUT_DIR/build_options.zig\" },"
            echo '        .target = target,'
            echo '        .optimize = optimize,'
            echo '    });'
            echo "    const app_mod = b.createModule(.{"
            echo "        .root_source_file = .{ .cwd_relative = \"$E/$BK_APP_ZIG\" },"
            echo '        .target = target,'
            echo '        .optimize = optimize,'
            echo '    });'
            echo '    app_mod.addImport("build_options", build_options_mod);'
            echo "    const env_mod = b.createModule(.{"
            echo "        .root_source_file = .{ .cwd_relative = \"$OUT_DIR/env.zig\" },"
            echo '        .target = target,'
            echo '        .optimize = optimize,'
            echo '    });'
        fi
        echo ''

        # Wire up inter-module dependencies (each module can import all others)
        mod_idx=0
        for entry in $BK_MODULES; do
            local mod_name="${entry%%:*}"
            local inner_idx=0
            for inner_entry in $BK_MODULES; do
                local inner_name="${inner_entry%%:*}"
                if [ "$mod_name" != "$inner_name" ]; then
                    echo "    mod_${mod_idx}.addImport(\"$inner_name\", mod_${inner_idx});"
                fi
                inner_idx=$((inner_idx + 1))
            done
            mod_idx=$((mod_idx + 1))
        done

        # App module imports all dep modules
        if [ "$NAME" = "bk_zig_ap" ]; then
            mod_idx=0
            for entry in $BK_MODULES; do
                local mod_name="${entry%%:*}"
                echo "    app_mod.addImport(\"$mod_name\", mod_${mod_idx});"
                mod_idx=$((mod_idx + 1))
            done
        fi
        echo ''

        # Root module
        echo '    const root_mod = b.createModule(.{'
        echo "        .root_source_file = .{ .cwd_relative = \"$ROOT_ZIG\" },"
        echo '        .target = target,'
        echo '        .optimize = optimize,'
        echo '    });'

        # Root module imports
        mod_idx=0
        for entry in $BK_MODULES; do
            local mod_name="${entry%%:*}"
            echo "    root_mod.addImport(\"$mod_name\", mod_${mod_idx});"
            mod_idx=$((mod_idx + 1))
        done
        if [ "$NAME" = "bk_zig_ap" ]; then
            echo '    root_mod.addImport("app", app_mod);'
            echo '    root_mod.addImport("env", env_mod);'
        fi
        echo ''

        echo '    const lib = b.addLibrary(.{'
        echo "        .name = \"$NAME\","
        echo '        .linkage = .static,'
        echo '        .root_module = root_mod,'
        echo '    });'
        echo '    b.installArtifact(lib);'
        echo '}'
    } > "$OUT_DIR/build.zig"

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

# Copy configs from base project
BASE="$ARMINO_PATH/projects/$BK_BASE_PROJECT"
if [ ! -d "$BASE" ]; then
    echo "[bk_build] Error: base project '$BK_BASE_PROJECT' not found at $BASE"
    exit 1
fi
echo "[bk_build] Base project: $BK_BASE_PROJECT"

# Use custom partition table if provided, otherwise copy from base project
if [ -n "$BK_PARTITION_CSV" ] && [ -f "$E/$BK_PARTITION_CSV" ]; then
    cp "$E/$BK_PARTITION_CSV" "$PROJECT_DIR/partitions/bk7258/auto_partitions.csv"
    echo "[bk_build] Custom partition table from Bazel"
else
    cp "$BASE/partitions/bk7258/auto_partitions.csv" "$PROJECT_DIR/partitions/bk7258/"
fi
cp "$BASE/partitions/bk7258/ram_regions.csv" "$PROJECT_DIR/partitions/bk7258/"
mkdir -p "$PROJECT_DIR/ap/config/bk7258_ap" "$PROJECT_DIR/cp/config/bk7258"
cp "$BASE/ap/config/bk7258_ap/config" "$PROJECT_DIR/ap/config/bk7258_ap/"
cp "$BASE/cp/config/bk7258/config" "$PROJECT_DIR/cp/config/bk7258/"
cp "$BASE/ap/config/bk7258_ap/usr_gpio_cfg.h" "$PROJECT_DIR/ap/config/bk7258_ap/" 2>/dev/null || true
cp "$BASE/cp/config/bk7258/usr_gpio_cfg.h" "$PROJECT_DIR/cp/config/bk7258/" 2>/dev/null || true

# Append Kconfig overrides from bk_config rule
if [ -n "$BK_KCONFIG_AP" ] && [ -f "$E/$BK_KCONFIG_AP" ]; then
    echo "" >> "$PROJECT_DIR/ap/config/bk7258_ap/config"
    cat "$E/$BK_KCONFIG_AP" >> "$PROJECT_DIR/ap/config/bk7258_ap/config"
    echo "[bk_build] AP Kconfig appended from $BK_KCONFIG_AP"
fi
# Enable CURVE25519 in mbedTLS config if crypto kconfig is present
if grep -q "CONFIG_FULL_MBEDTLS=y" "$PROJECT_DIR/ap/config/bk7258_ap/config" 2>/dev/null; then
    MBED_CFG="$ARMINO_PATH/ap/components/psa_mbedtls/mbedtls_port/configs/mbedtls_psa_crypto_config.h"
    if [ -f "$MBED_CFG" ] && grep -q "// #define MBEDTLS_ECP_DP_CURVE25519_ENABLED" "$MBED_CFG"; then
        # Uncomment CURVE25519 in the mbedTLS config (in-place)
        sed -i.bak 's|// #define MBEDTLS_ECP_DP_CURVE25519_ENABLED|#define MBEDTLS_ECP_DP_CURVE25519_ENABLED|' "$MBED_CFG"
        rm -f "$MBED_CFG.bak"
        echo "[bk_build] Enabled MBEDTLS_ECP_DP_CURVE25519_ENABLED in mbedTLS config"
    fi
fi

if [ -n "$BK_KCONFIG_CP" ] && [ -f "$E/$BK_KCONFIG_CP" ]; then
    echo "" >> "$PROJECT_DIR/cp/config/bk7258/config"
    cat "$E/$BK_KCONFIG_CP" >> "$PROJECT_DIR/cp/config/bk7258/config"
    echo "[bk_build] CP Kconfig appended from $BK_KCONFIG_CP"
fi

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

AP_STACK=${BK_AP_STACK_SIZE:-16384}
PSRAM_STACK=${BK_RUN_IN_PSRAM:-0}

if [ "$PSRAM_STACK" -gt 0 ] 2>/dev/null; then
    AP_ACTUAL_STACK=$PSRAM_STACK
    AP_STACK_MODE="PSRAM"
else
    AP_ACTUAL_STACK=$AP_STACK
    AP_STACK_MODE="SRAM"
fi

cat > "$PROJECT_DIR/ap/ap_main.c" << APEOF
/* AP task: stack=$AP_ACTUAL_STACK bytes ($AP_STACK_MODE) */
#include "bk_private/bk_init.h"
#include <components/system.h>
#include <os/os.h>
#include <os/mem.h>
#include <components/log.h>
#define TAG "bk_app"
extern void zig_main(void);
static void zig_task(void *arg) { (void)arg; zig_main(); }
int main(void) {
    bk_init();
    beken_thread_t t;
    int ret;
APEOF

if [ "$PSRAM_STACK" -gt 0 ] 2>/dev/null; then
    cat >> "$PROJECT_DIR/ap/ap_main.c" << APEOF
    BK_LOGI(TAG, "Starting zig_ap task (PSRAM, %d bytes)\\r\\n", $PSRAM_STACK);
    ret = rtos_create_psram_thread(&t, 4, "zig_ap",
        (beken_thread_function_t)zig_task, $PSRAM_STACK, 0);
    if (ret != 0) {
        BK_LOGE(TAG, "PSRAM thread fail (%d), falling back to SRAM\\r\\n", ret);
        ret = rtos_create_thread(&t, 4, "zig_ap",
            (beken_thread_function_t)zig_task, 32768, 0);
    }
APEOF
else
    cat >> "$PROJECT_DIR/ap/ap_main.c" << APEOF
    BK_LOGI(TAG, "Starting zig_ap task (SRAM, %d bytes)\\r\\n", $AP_STACK);
    ret = rtos_create_thread(&t, 4, "zig_ap",
        (beken_thread_function_t)zig_task, $AP_STACK, 0);
APEOF
fi

cat >> "$PROJECT_DIR/ap/ap_main.c" << APEOF
    if (ret != 0) {
        BK_LOGE(TAG, "Thread create FAILED: %d\\r\\n", ret);
    }
    return 0;
}
APEOF
echo "[bk_build] AP task stack: $AP_ACTUAL_STACK bytes ($AP_STACK_MODE)"

PRELINK_CMAKE=""
if [ -n "$BK_PRELINK_LIBS" ]; then
    # Link prelink libs normally (NOT whole-archive).
    # Combined with hiding conflicting v1 lib, linker picks v3 naturally.
    PRELINK_PATHS=""
    for lib in $BK_PRELINK_LIBS; do
        PRELINK_PATHS="${PRELINK_PATHS} \$ENV{ARMINO_PATH}/${lib}"
    done
    PRELINK_CMAKE="target_link_libraries(\${COMPONENT_LIB} INTERFACE ${PRELINK_PATHS})"
    echo "[bk_build] Prelink libs: $BK_PRELINK_LIBS"
fi

cat > "$PROJECT_DIR/ap/CMakeLists.txt" << APCMAKEOF
set(incs .)
set(srcs ap_main.c $C_HELPER_SRCS)
set(priv_req driver lwip_intf_v2_1 psa_mbedtls $BK_AP_REQUIRES)
armino_component_register(SRCS "\${srcs}" INCLUDE_DIRS "\${incs}" PRIV_REQUIRES "\${priv_req}")
$PRELINK_CMAKE
target_link_libraries(\${COMPONENT_LIB} INTERFACE -Wl,--whole-archive \${CMAKE_CURRENT_SOURCE_DIR}/libbk_zig_ap.a -Wl,--no-whole-archive)
target_link_options(\${COMPONENT_LIB} INTERFACE $BK_FORCE_LINK)
APCMAKEOF

touch "$PROJECT_DIR/pj_config.mk"

# =========================================================================
# Step 3: Build with Armino
# =========================================================================

# Debug: check if CONFIG_FULL_MBEDTLS is in the appended config
echo "[bk_build] AP config FULL_MBEDTLS check:"
grep "FULL_MBEDTLS" "$PROJECT_DIR/ap/config/bk7258_ap/config" 2>/dev/null && echo "[bk_build]   FOUND" || echo "[bk_build]   NOT FOUND"
echo "[bk_build] AP config last 5 lines:"
tail -5 "$PROJECT_DIR/ap/config/bk7258_ap/config" 2>/dev/null | while IFS= read -r line; do echo "[bk_build]   $line"; done

# Temporarily hide libaec.a (v1) to prevent symbol conflict with v3
LIBAEC_V1="$ARMINO_PATH/ap/components/bk_libs/bk7258_ap/libs/libaec.a"
LIBAEC_V1_BAK=""
if [ -f "$LIBAEC_V1" ] && echo "$BK_PRELINK_LIBS" | grep -q "libaec_v3"; then
    LIBAEC_V1_BAK="${LIBAEC_V1}.bak_zig"
    mv "$LIBAEC_V1" "$LIBAEC_V1_BAK"
    echo "[bk_build] Temporarily hid libaec.a (v1) to avoid conflict with v3"
fi

echo "[bk_build] Running Armino make..."
cd "$ARMINO_PATH"
rm -rf "build/bk7258/$PROJECT"
make bk7258 PROJECT="$PROJECT" PROJECT_DIR="$PROJECT_DIR" BUILD_DIR="$WORK/build" 2>&1

# Debug: check generated sdkconfig.h
SDKCONFIG_H="$WORK/build/bk7258/$PROJECT/bk7258_ap/config/sdkconfig.h"
if [ -f "$SDKCONFIG_H" ]; then
    echo "[bk_build] sdkconfig.h FULL_MBEDTLS:"
    grep "FULL_MBEDTLS" "$SDKCONFIG_H" 2>/dev/null | while read line; do echo "[bk_build]   $line"; done
    echo "[bk_build] sdkconfig.h CURVE25519:"
    grep "CURVE25519" "$SDKCONFIG_H" 2>/dev/null | while read line; do echo "[bk_build]   $line"; done
fi

PACKAGE_DIR="$WORK/build/bk7258/$PROJECT/package"
ALL_APP="$PACKAGE_DIR/all-app.bin"
if [ ! -f "$ALL_APP" ]; then
    echo "[bk_build] Error: all-app.bin not found"
    exit 1
fi

# Log package contents for debugging
echo "[bk_build] Package contents:"
ls -la "$PACKAGE_DIR/" 2>/dev/null | while read line; do echo "[bk_build]   $line"; done
# Find individual AP/CP binaries
AP_BIN=$(find "$WORK/build/bk7258/$PROJECT" -name "app.bin" -path "*bk7258_ap*" | head -1)
CP_BIN=$(find "$WORK/build/bk7258/$PROJECT" -name "app.bin" -path "*bk7258*" ! -path "*bk7258_ap*" | head -1)
echo "[bk_build] AP binary: $AP_BIN ($(wc -c < "$AP_BIN" 2>/dev/null || echo 0) bytes)"
echo "[bk_build] CP binary: $CP_BIN ($(wc -c < "$CP_BIN" 2>/dev/null || echo 0) bytes)"

# Log partition info if available
PARTITION_DIR="$WORK/build/bk7258/$PROJECT/partitions"
if [ -d "$PARTITION_DIR" ]; then
    echo "[bk_build] Partition info:"
    cat "$PARTITION_DIR/partitions.csv" 2>/dev/null | while read line; do echo "[bk_build]   $line"; done
fi

cp "$ALL_APP" "$BK_BIN_OUT"

# Copy AP-only binary + partition CSV for app-only flash
if [ -n "$AP_BIN" ] && [ -f "$AP_BIN" ]; then
    cp "$AP_BIN" "$BK_AP_BIN_OUT"
    echo "[bk_build] AP-only: $BK_AP_BIN_OUT ($(wc -c < "$BK_AP_BIN_OUT") bytes)"
else
    # Fallback: copy all-app.bin as AP bin
    cp "$ALL_APP" "$BK_AP_BIN_OUT"
fi
cp "$PARTITION_DIR/partitions.csv" "$BK_PARTITIONS_OUT" 2>/dev/null || echo "Name,Offset" > "$BK_PARTITIONS_OUT"

# Restore libaec.a if we hid it
if [ -n "$LIBAEC_V1_BAK" ] && [ -f "$LIBAEC_V1_BAK" ]; then
    mv "$LIBAEC_V1_BAK" "$LIBAEC_V1"
    echo "[bk_build] Restored libaec.a (v1)"
fi

echo "[bk_build] Output: $BK_BIN_OUT ($(wc -c < "$BK_BIN_OUT") bytes)"
echo "[bk_build] Done!"
