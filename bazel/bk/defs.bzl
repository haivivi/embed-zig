"""Beken BK7258 build rules for Bazel.

Usage:
    load("//bazel/bk:defs.bzl", "bk_modules", "bk_zig_app", "bk_flash", "bk_monitor")

    bk_modules()

    bk_zig_app(
        name = "app",
        app = ":srcs",
        deps = [":bk", "//lib/hal", "//lib/trait"],
    )

    bk_flash(
        name = "flash",
        app = ":app",
    )

Build:
    bazel build //examples/apps/led_strip_flash/bk:app
    bazel run //examples/apps/led_strip_flash/bk:flash
    bazel run //examples/apps/led_strip_flash/bk:monitor
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//bazel/zig:defs.bzl", "ZigModuleInfo", "zig_module")

# =============================================================================
# bk_modules — Create standard BK platform zig_module targets
# =============================================================================

def bk_modules():
    """Create the BK platform zig_module declaration.

    Creates 1 target: :bk (single flat module, uses relative @import internally)

    BK platform uses a single module because Zig's -M multi-module system
    doesn't handle lazy cross-module imports well. All armino/impl/boards
    files are part of one module tree rooted at bk.zig.

    Usage:
        load("//bazel/bk:defs.bzl", "bk_modules", "bk_zig_app")
        bk_modules()
        bk_zig_app(name = "app", deps = [":bk"], ...)
    """
    zig_module(
        name = "bk",
        main = Label("//lib/platform/bk:bk.zig"),
        srcs = [Label("//lib/platform/bk:all_zig_srcs")],
    )

# =============================================================================
# bk_zig_app — Build BK7258 project with Zig
# =============================================================================

def _find_zig_file(files, names):
    """Find .zig file matching names in priority order."""
    for name in names:
        for f in files:
            if f.basename == name:
                return f
    for f in files:
        if f.path.endswith(".zig"):
            return f
    return None

def _bk_zig_app_impl(ctx):
    """Build a BK7258 project with Zig — dual target (AP + CP).

    1. Compile AP Zig → libbk_zig_ap.a
    2. Compile CP Zig → libbk_zig_cp.a
    3. Generate Armino project skeleton (CP boots AP, both link Zig)
    4. Run make bk7258 to produce all-app.bin
    """

    project_name = ctx.attr.project_name or ctx.label.name
    bin_file = ctx.actions.declare_file("{}.bin".format(project_name))
    ap_bin_file = ctx.actions.declare_file("{}_ap.bin".format(project_name))
    partition_file = ctx.actions.declare_file("{}_partitions.csv".format(project_name))

    # Get AP and CP source files
    ap_files = ctx.attr.ap.files.to_list()
    cp_files = ctx.attr.cp.files.to_list()

    # Get Zig toolchain
    zig_files = ctx.attr._zig_toolchain.files.to_list()
    zig_bin = None
    for f in zig_files:
        if f.basename == "zig" and f.is_source:
            zig_bin = f
            break

    # Get Go builder binary
    builder_files = ctx.attr._builder.files.to_list()
    builder_bin = builder_files[0]

    # Get C helper files
    c_helper_files = []
    for src in ctx.attr.c_helpers:
        c_helper_files.extend(src.files.to_list())

    # Collect ZigModuleInfo from deps
    dep_infos = []
    all_dep_files = []
    for dep in ctx.attr.deps:
        if ZigModuleInfo in dep:
            info = dep[ZigModuleInfo]
            dep_infos.append(info)
            all_dep_files.extend(info.transitive_srcs.to_list())
            all_dep_files.extend(info.transitive_c_inputs.to_list())

    # Find app.zig — always generate main.zig bridge (like ESP)
    app_zig = None
    for f in ap_files:
        if f.basename == "app.zig":
            app_zig = f
            break
    if not app_zig:
        fail("No app.zig found in ap sources")

    cp_zig = _find_zig_file(cp_files, ["base.zig", "cp.zig", "entry.zig"])
    if not cp_zig:
        fail("No .zig file found in cp sources")

    # Find bk.zig root from deps + collect all module info
    bk_zig = None
    module_entries = []  # "name:root_path:inc_dirs" triples for builder
    for info in dep_infos:
        if info.module_name == "bk":
            bk_zig = info.root_source
        inc_dirs = ",".join(info.own_c_include_dirs) if info.own_c_include_dirs else ""
        module_entries.append("{}:{}:{}".format(info.module_name, info.root_source.path, inc_dirs))
    if not bk_zig:
        fail("No 'bk' module found in deps. Did you call bk_modules()?")

    # Collect static .a libraries
    static_lib_files = []
    for src in ctx.attr.static_libs:
        static_lib_files.extend(src.files.to_list())

    # C helper paths (space-separated for builder)
    c_helper_paths = " ".join([f.path for f in c_helper_files])

    # Create wrapper script that sets env vars and calls Go builder
    wrapper = ctx.actions.declare_file("{}_build.sh".format(ctx.label.name))

    script_content = """#!/bin/bash
set -e
export E="$(pwd)"
export ZIG_BIN="$E/{zig_bin}"
export BK_PROJECT_NAME="{project_name}"
export BK_BIN_OUT="$E/{bin_out}"
export BK_AP_BIN_OUT="$E/{ap_bin_out}"
export BK_PARTITIONS_OUT="$E/{partitions_out}"
export BK_C_HELPERS="{c_helpers}"
export BK_AP_ZIG="{ap_zig}"
export BK_CP_ZIG="{cp_zig}"
export BK_BK_ZIG="{bk_zig}"
export BK_AP_REQUIRES="{requires}"
export BK_FORCE_LINK="{force_link}"
export BK_BASE_PROJECT="{base_project}"
export BK_KCONFIG_AP="{kconfig_ap}"
export BK_KCONFIG_CP="{kconfig_cp}"
export BK_MODULES="{modules}"
export BK_APP_ZIG="{app_zig}"
export BK_ENV_FILE="{env_file}"
export ARMINO_PATH="{armino_path}"
export BK_PARTITION_CSV="{partition_csv}"
export BK_AP_STACK_SIZE="{ap_stack_size}"
export BK_RUN_IN_PSRAM="{run_in_psram}"
export BK_PRELINK_LIBS="{prelink_libs}"
export BK_STATIC_LIBS="{static_libs}"
exec "$E/{builder}"
""".format(
        project_name = project_name,
        bin_out = bin_file.path,
        ap_bin_out = ap_bin_file.path,
        partitions_out = partition_file.path,
        zig_bin = zig_bin.path if zig_bin else "zig",
        c_helpers = c_helper_paths,
        ap_zig = app_zig.path,
        cp_zig = cp_zig.path,
        bk_zig = bk_zig.path,
        requires = " ".join(ctx.attr.requires),
        force_link = " ".join(["-Wl,--undefined=" + s for s in ctx.attr.force_link]),
        base_project = ctx.attr.base_project,
        kconfig_ap = ctx.file.kconfig_ap.path if ctx.file.kconfig_ap else "",
        kconfig_cp = ctx.file.kconfig_cp.path if ctx.file.kconfig_cp else "",
        modules = " ".join(module_entries),
        app_zig = app_zig.path if app_zig else "",
        env_file = ctx.file.env.path if ctx.file.env else "",
        armino_path = ctx.attr._armino_path[BuildSettingInfo].value if ctx.attr._armino_path and BuildSettingInfo in ctx.attr._armino_path else "",
        partition_csv = ctx.file.partition_table.path if ctx.file.partition_table else "",
        ap_stack_size = str(ctx.attr.ap_stack_size),
        run_in_psram = str(ctx.attr.run_in_psram),
        prelink_libs = " ".join(ctx.attr.prelink_libs),
        static_libs = " ".join([f.path for f in static_lib_files]),
        builder = builder_bin.path,
    )

    # Add env file to inputs
    env_files = [ctx.file.env] if ctx.file.env else []

    ctx.actions.write(
        output = wrapper,
        content = script_content,
        is_executable = True,
    )

    # Collect kconfig files
    kconfig_files = []
    if ctx.file.kconfig_ap:
        kconfig_files.append(ctx.file.kconfig_ap)
    if ctx.file.kconfig_cp:
        kconfig_files.append(ctx.file.kconfig_cp)

    # All inputs
    partition_files = [ctx.file.partition_table] if ctx.file.partition_table else []
    inputs = ap_files + cp_files + zig_files + all_dep_files + c_helper_files + kconfig_files + env_files + partition_files + static_lib_files + builder_files + [wrapper]

    ctx.actions.run_shell(
        command = wrapper.path,
        inputs = inputs,
        outputs = [bin_file, ap_bin_file, partition_file],
        execution_requirements = {
            "local": "1",
            "requires-network": "1",
        },
        mnemonic = "BkZigBuild",
        progress_message = "Building BK7258 Zig app %s (AP + CP)" % ctx.label,
        use_default_shell_env = True,
    )

    return [
        DefaultInfo(
            files = depset([bin_file, ap_bin_file, partition_file]),
            runfiles = ctx.runfiles(files = [bin_file, ap_bin_file, partition_file]),
        ),
    ]

bk_zig_app = rule(
    implementation = _bk_zig_app_impl,
    attrs = {
        "ap": attr.label(
            mandatory = True,
            allow_files = True,
            doc = "AP Zig sources (user app code — runs on AP core)",
        ),
        "cp": attr.label(
            mandatory = True,
            allow_files = True,
            doc = "CP Zig sources (e.g. //lib/platform/bk/cp:base)",
        ),
        "project_name": attr.string(
            doc = "Project name (defaults to target name)",
        ),
        "deps": attr.label_list(
            providers = [ZigModuleInfo],
            doc = "Zig module dependencies (e.g., :bk, //lib/hal)",
        ),
        "c_helpers": attr.label_list(
            allow_files = [".c", ".h"],
            doc = "C helper files compiled by Armino's GCC (linked to AP side).",
        ),
        "requires": attr.string_list(
            default = [],
            doc = "Additional Armino component requirements for AP CMakeLists (e.g., bk_audio). driver and lwip are always included.",
        ),
        "force_link": attr.string_list(
            default = [],
            doc = "Symbols to force-link (prevents linker from stripping them). E.g., ['bk_pwm_init']",
        ),
        "base_project": attr.string(
            default = "app",
            doc = "Armino base project to copy config from (e.g., 'app', 'audio_player_example'). Located at $ARMINO_PATH/projects/<name>/.",
        ),
        "kconfig_ap": attr.label(
            allow_single_file = True,
            doc = "AP Kconfig target (from bk_config rule). Appended to base project config.",
        ),
        "kconfig_cp": attr.label(
            allow_single_file = True,
            doc = "CP Kconfig target (from bk_config rule). Appended to base project config.",
        ),
        "env": attr.label(
            allow_single_file = True,
            doc = "Environment file with KEY=VALUE pairs (WIFI_SSID, WIFI_PASSWORD, etc.)",
        ),
        "partition_table": attr.label(
            allow_single_file = True,
            doc = "Partition table CSV (from bk_partition_table). If set, replaces auto_partitions.csv.",
        ),
        "ap_stack_size": attr.int(
            default = 16384,
            doc = "AP task stack size in bytes. Default 16KB. Only used when run_in_psram=0.",
        ),
        "run_in_psram": attr.int(
            default = 0,
            doc = """PSRAM task stack size (bytes). 0=use SRAM (ap_stack_size).
            >0: allocate stack from PSRAM via psram_malloc. BK7258 has 8MB PSRAM.
            Recommended: 32768 (32KB) normal apps, 131072 (128KB) TLS/crypto apps.""",
        ),
        "prelink_libs": attr.string_list(
            default = [],
            doc = "SDK .a libs to link BEFORE bk_libs (resolves symbol priority). Paths relative to $ARMINO_PATH. E.g., ['components/bk_libs/bk7258_ap/libs/libaec_v3.a']",
        ),
        "static_libs": attr.label_list(
            allow_files = [".a"],
            doc = "Pre-compiled .a libraries to link with the AP Zig code (e.g., opus cross-compiled for ARM).",
        ),
        "_zig_toolchain": attr.label(
            default = "@zig_toolchain//:zig_files",
        ),
        "_builder": attr.label(
            default = Label("//bazel/bk/tools/builder"),
            executable = True,
            cfg = "exec",
            doc = "Go binary that runs the BK7258 build",
        ),
        "_armino_path": attr.label(
            default = Label("//bazel:armino_path"),
        ),
    },
    doc = "Build a BK7258 Zig app — dual target: AP (user code) + CP (boot/BLE)",
)

# =============================================================================
# bk_flash — Flash all-app.bin to BK7258
# =============================================================================

def _bk_flash_impl(ctx):
    """Flash BK7258 binary via bk_loader. Supports --app-only for AP-only flash."""

    app_files = ctx.attr.app.files.to_list()
    bin_file = None
    ap_bin_file = None
    partition_file = None
    for f in app_files:
        if f.basename.endswith("_ap.bin"):
            ap_bin_file = f
        elif f.basename.endswith("_partitions.csv"):
            partition_file = f
        elif f.path.endswith(".bin") and not bin_file:
            bin_file = f
    if not bin_file:
        fail("No .bin file found in app target")

    port = ctx.attr._port[BuildSettingInfo].value if ctx.attr._port and BuildSettingInfo in ctx.attr._port else ""
    baud = ctx.attr._baud[BuildSettingInfo].value if ctx.attr._baud and BuildSettingInfo in ctx.attr._baud else "115200"
    bk_loader = ctx.attr._bk_loader_path[BuildSettingInfo].value if ctx.attr._bk_loader_path and BuildSettingInfo in ctx.attr._bk_loader_path else ""

    # Get the flasher Go binary
    flasher_files = ctx.attr._flasher.files.to_list()
    flasher_bin = flasher_files[0]

    flash_script = ctx.actions.declare_file("{}_flash.sh".format(ctx.label.name))

    script_content = """#!/bin/bash
set -e

# Resolve runfiles directory
RUNFILES="${{BASH_SOURCE[0]}}.runfiles/_main"
if [ ! -d "$RUNFILES" ]; then
    RUNFILES="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
fi

export BK_PORT_CONFIG="{port}"
export BK_BAUD="{baud}"
export BK_LOADER="{bk_loader}"
export BK_BIN="$RUNFILES/{bin}"
export BK_AP_BIN="$RUNFILES/{ap_bin}"
export BK_PARTITIONS="$RUNFILES/{partitions}"

exec "$RUNFILES/{flasher}" "$@"
""".format(
        port = port,
        baud = baud,
        bk_loader = bk_loader,
        bin = bin_file.short_path,
        ap_bin = ap_bin_file.short_path if ap_bin_file else "",
        partitions = partition_file.short_path if partition_file else "",
        flasher = flasher_bin.short_path,
    )

    ctx.actions.write(
        output = flash_script,
        content = script_content,
        is_executable = True,
    )

    all_files = [bin_file] + flasher_files
    if ap_bin_file:
        all_files.append(ap_bin_file)
    if partition_file:
        all_files.append(partition_file)

    return [
        DefaultInfo(
            executable = flash_script,
            runfiles = ctx.runfiles(files = all_files),
        ),
    ]

bk_flash = rule(
    implementation = _bk_flash_impl,
    executable = True,
    attrs = {
        "app": attr.label(
            mandatory = True,
            doc = "BK app target to flash",
        ),
        "_port": attr.label(
            default = Label("//bazel:port"),
        ),
        "_baud": attr.label(
            default = Label("//bazel:baud"),
        ),
        "_bk_loader_path": attr.label(
            default = Label("//bazel:bk_loader_path"),
        ),
        "_flasher": attr.label(
            default = Label("//bazel/bk/tools/flasher"),
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Flash all-app.bin to BK7258 via bk_loader",
)

# =============================================================================
# bk_monitor — Serial monitor for BK7258
# =============================================================================

def _bk_monitor_impl(ctx):
    """Monitor serial output from BK7258."""

    port = ctx.attr._port[BuildSettingInfo].value if ctx.attr._port and BuildSettingInfo in ctx.attr._port else ""

    # Get the monitor Go binary
    monitor_files = ctx.attr._monitor.files.to_list()
    monitor_bin = monitor_files[0]

    monitor_script = ctx.actions.declare_file("{}_monitor.sh".format(ctx.label.name))

    script_content = """#!/bin/bash
set -e

export BK_PORT_CONFIG="{port}"

# Resolve runfiles directory
RUNFILES="${{BASH_SOURCE[0]}}.runfiles/_main"
if [ ! -d "$RUNFILES" ]; then
    RUNFILES="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
fi

exec "$RUNFILES/{monitor}" "$@"
""".format(
        port = port,
        monitor = monitor_bin.short_path,
    )

    ctx.actions.write(
        output = monitor_script,
        content = script_content,
        is_executable = True,
    )

    return [
        DefaultInfo(
            executable = monitor_script,
            runfiles = ctx.runfiles(files = monitor_files),
        ),
    ]

bk_monitor = rule(
    implementation = _bk_monitor_impl,
    executable = True,
    attrs = {
        "_port": attr.label(
            default = Label("//bazel:port"),
        ),
        "_monitor": attr.label(
            default = Label("//bazel/bk/tools/monitor"),
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Monitor serial output from BK7258",
)
