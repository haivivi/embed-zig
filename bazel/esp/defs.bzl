"""ESP-IDF build rules for Bazel.

Usage:
    load("//bazel/esp:defs.bzl", "esp_idf_app", "esp_flash", "esp_monitor")

    esp_idf_app(
        name = "app",
        srcs = glob(["**/*"]),
    )

    esp_flash(
        name = "flash",
        app = ":app",
    )

    esp_monitor(
        name = "monitor",
    )

Build:
    # Default board (esp32s3_devkit)
    bazel build //examples/apps/led_strip_flash:esp
    
    # Specify board
    bazel build //examples/apps/led_strip_flash:esp --//bazel:board=korvo2_v3
    
    # Flash (auto-detect port)
    bazel run //examples/apps/led_strip_flash:flash
    
    # Flash to specific port
    bazel run //examples/apps/led_strip_flash:flash --//bazel:port=/dev/ttyUSB0
    
    # Monitor
    bazel run //bazel/esp:monitor --//bazel:port=/dev/ttyUSB0
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//bazel/esp:settings.bzl", "DEFAULT_BOARD", "DEFAULT_CHIP")
load("//bazel/esp/partition:table.bzl", "EspPartitionTableInfo")
load("//bazel/zig:defs.bzl", "ZigModuleInfo", "build_module_args", "collect_deps", "encode_module", "decode_module")

# sdkconfig modules (each corresponds to ESP-IDF components)
# All modules are independent rules that generate .sdkconfig fragments
load("//bazel/esp/sdkconfig:core.bzl", "esp_core")
load("//bazel/esp/sdkconfig:psram.bzl", "esp_psram")
load("//bazel/esp/sdkconfig:freertos.bzl", "esp_freertos")
load("//bazel/esp/sdkconfig:log.bzl", "esp_log")
load("//bazel/esp/sdkconfig:wifi.bzl", "esp_wifi")
load("//bazel/esp/sdkconfig:lwip.bzl", "esp_lwip")
load("//bazel/esp/sdkconfig:spiffs.bzl", "esp_spiffs")
load("//bazel/esp/sdkconfig:littlefs.bzl", "esp_littlefs")
load("//bazel/esp/sdkconfig:crypto.bzl", "esp_crypto")
load("//bazel/esp/sdkconfig:newlib.bzl", "esp_newlib")
# Non-IDF configs
load("//bazel/esp/sdkconfig:app.bzl", "esp_app")
load("//bazel/esp/sdkconfig:validate.bzl", "esp_validate")
load("//bazel:env.bzl", "make_env_file")

# Labels relative to this repository (works when used from external repos)
_LIBS_LABEL = Label("//:all_libs")
_CMAKE_MODULES_LABEL = Label("//cmake:cmake_modules")
_SCRIPTS_LABEL = Label("//bazel/esp:scripts")
_APPS_LABEL = Label("//examples/apps:all_apps")

# =============================================================================
# esp_idf_app - Build ESP-IDF project with Zig
# =============================================================================

def _esp_idf_app_impl(ctx):
    """Build an ESP-IDF project with Zig."""
    
    # Output files
    project_name = ctx.attr.project_name or ctx.label.name
    bin_file = ctx.actions.declare_file("{}.bin".format(project_name))
    elf_file = ctx.actions.declare_file("{}.elf".format(project_name))
    bootloader_file = ctx.actions.declare_file("bootloader.bin")
    partition_file = ctx.actions.declare_file("partition-table.bin")
    
    # Collect source files
    src_files = []
    for src in ctx.attr.srcs:
        src_files.extend(src.files.to_list())
    
    # Collect cmake module files
    cmake_files = []
    for cmake in ctx.attr.cmake_modules:
        cmake_files.extend(cmake.files.to_list())
    
    # Get Zig toolchain path
    zig_files = ctx.attr._zig_toolchain.files.to_list()
    zig_bin = None
    for f in zig_files:
        if f.basename == "zig" and f.is_source:
            zig_bin = f
            break
    
    # Get lib and apps files
    lib_files = ctx.attr._libs.files.to_list()
    apps_files = ctx.attr._apps.files.to_list() if ctx.attr._apps else []
    
    # Build settings
    board = ctx.attr._board[BuildSettingInfo].value if ctx.attr._board and BuildSettingInfo in ctx.attr._board else DEFAULT_BOARD
    
    # Get script files
    script_files = ctx.attr._scripts.files.to_list()
    build_sh = None
    for f in script_files:
        if f.basename == "build.sh":
            build_sh = f
            break
    
    # Generate copy commands - preserve original directory structure
    src_copy_commands = _generate_copy_commands_preserve_structure(src_files)
    cmake_copy_commands = _generate_copy_commands_preserve_structure(cmake_files)
    lib_copy_commands = _generate_copy_commands_preserve_structure(lib_files)
    apps_copy_commands = _generate_copy_commands_preserve_structure(apps_files)
    
    # Create wrapper script that copies files and calls build.sh
    build_script = ctx.actions.declare_file("{}_build.sh".format(ctx.label.name))
    
    # Wrapper script: sets up environment, copies files, calls build.sh
    # Files are copied preserving their original paths, so relative references work
    script_content = """#!/bin/bash
set -e
export ESP_BAZEL_RUN=1 ESP_BOARD="{board}"
export ESP_PROJECT_NAME="{project_name}" ESP_BIN_OUT="{bin_out}" ESP_ELF_OUT="{elf_out}"
export ESP_BOOTLOADER_OUT="{bootloader_out}" ESP_PARTITION_OUT="{partition_out}"
export ZIG_INSTALL="$(pwd)/{zig_dir}" ESP_EXECROOT="$(pwd)"
export ESP_PROJECT_PATH="{project_path}"
WORK=$(mktemp -d) && export ESP_WORK_DIR="$WORK" && trap "rm -rf $WORK" EXIT
{src_copy_commands}
{cmake_copy_commands}
{lib_copy_commands}
{apps_copy_commands}
exec bash "{build_sh}"
""".format(
        board = board,
        project_name = project_name,
        bin_out = bin_file.path,
        elf_out = elf_file.path,
        bootloader_out = bootloader_file.path,
        partition_out = partition_file.path,
        zig_dir = zig_bin.dirname if zig_bin else "",
        build_sh = build_sh.path if build_sh else "",
        project_path = ctx.label.package,  # e.g., "examples/apps/gpio_button"
        src_copy_commands = "\n".join(src_copy_commands),
        cmake_copy_commands = "\n".join(cmake_copy_commands),
        lib_copy_commands = "\n".join(lib_copy_commands),
        apps_copy_commands = "\n".join(apps_copy_commands),
    )
    
    ctx.actions.write(
        output = build_script,
        content = script_content,
        is_executable = True,
    )
    
    # Collect all inputs
    inputs = src_files + cmake_files + zig_files + lib_files + apps_files + script_files + [build_script]
    
    # Run build
    ctx.actions.run_shell(
        command = build_script.path,
        inputs = inputs,
        outputs = [bin_file, elf_file, bootloader_file, partition_file],
        execution_requirements = {
            "local": "1",
            "requires-network": "1",
        },
        mnemonic = "EspIdfBuild",
        progress_message = "Building ESP-IDF project %s (board=%s)" % (ctx.label, board),
        use_default_shell_env = True,
    )
    
    return [
        DefaultInfo(
            files = depset([bin_file, elf_file, bootloader_file, partition_file]),
            runfiles = ctx.runfiles(files = [bin_file, elf_file, bootloader_file, partition_file]),
        ),
        OutputGroupInfo(
            bin = depset([bin_file]),
            elf = depset([elf_file]),
            bootloader = depset([bootloader_file]),
            partition = depset([partition_file]),
        ),
    ]

# Helper function for generating copy commands - preserves original directory structure
def _generate_copy_commands_preserve_structure(files):
    """Generate copy commands that preserve the original directory structure.
    
    This allows relative paths in build.zig.zon to work without rewriting.
    """
    commands = []
    for f in files:
        # Use short_path which is the path relative to the workspace root
        rel_path = f.short_path
        commands.append('mkdir -p "$WORK/$(dirname {})" && cp "{}" "$WORK/{}"'.format(
            rel_path, f.path, rel_path
        ))
    return commands

esp_idf_app = rule(
    implementation = _esp_idf_app_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Source files for the ESP-IDF project",
        ),
        "cmake_modules": attr.label_list(
            allow_files = True,
            default = [_CMAKE_MODULES_LABEL],
            doc = "CMake module files (e.g., zig_install.cmake)",
        ),
        "project_name": attr.string(
            doc = "Project name (defaults to target name)",
        ),
        "_zig_toolchain": attr.label(
            default = "@zig_toolchain//:zig_files",
            doc = "Zig compiler with Xtensa support",
        ),
        "_libs": attr.label(
            default = _LIBS_LABEL,
            doc = "Library files from embed-zig",
        ),
        "_apps": attr.label(
            default = _APPS_LABEL,
            doc = "App files from embed-zig examples",
        ),
        "_board": attr.label(
            default = "//bazel:board",
        ),
        "_scripts": attr.label(
            default = _SCRIPTS_LABEL,
            doc = "Build scripts",
        ),
    },
    doc = "Build an ESP-IDF project with Zig support",
)

# =============================================================================
# esp_configure - Run CMake configure to generate sdkconfig.h + extract include dirs
# =============================================================================

def _esp_configure_impl(ctx):
    """Run ESP-IDF CMake configure to generate sdkconfig.h.
    
    Creates a minimal ESP-IDF project, runs idf.py set-target + reconfigure,
    and outputs the generated config directory (containing sdkconfig.h).
    
    This is a per-app target — different apps with different sdkconfig get
    different configure outputs. The output is cached by Bazel.
    """
    
    # Output: directory containing sdkconfig.h
    config_dir = ctx.actions.declare_directory(ctx.label.name + "_config")
    # Output: file listing all IDF include directories (one per line)
    include_dirs_file = ctx.actions.declare_file(ctx.label.name + "_include_dirs.txt")
    
    # Get sdkconfig file
    sdkconfig_file = ctx.file.sdkconfig
    
    # Get chip from sdkconfig content (parsed at execution time)
    # IDF component manager dependencies
    idf_deps_yml = ""
    for dep in ctx.attr.idf_deps:
        parts = dep.split(":")
        if len(parts) == 2:
            idf_deps_yml += '  {}: "{}"\n'.format(parts[0], parts[1])
        else:
            idf_deps_yml += '  {}: "*"\n'.format(dep)
    
    # ESP-IDF requires
    requires = " ".join(ctx.attr.requires) if ctx.attr.requires else "freertos"
    
    # Script files for common.sh
    script_files = ctx.attr._scripts.files.to_list()
    
    # Build the configure script
    configure_script = ctx.actions.declare_file(ctx.label.name + "_configure.sh")
    
    script_content = """#!/bin/bash
set -e
export ESP_BAZEL_RUN=1

# Setup
WORK=$(mktemp -d) && trap "rm -rf $WORK" EXIT
mkdir -p "$WORK/project/main"

# Generate minimal CMakeLists.txt
cat > "$WORK/project/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.16)
include($ENV{{IDF_PATH}}/tools/cmake/project.cmake)
project(esp_configure)
EOF

# Generate main component
cat > "$WORK/project/main/CMakeLists.txt" << 'EOF'
idf_component_register(
    SRCS "main.c"
    REQUIRES {requires}
)
EOF

cat > "$WORK/project/main/main.c" << 'EOF'
void app_main(void) {{}}
EOF

# Generate idf_component.yml if needed
{idf_component_yml}

# Copy sdkconfig
cp "{sdkconfig_path}" "$WORK/project/sdkconfig.defaults"

# Source common functions and setup IDF
source "{common_sh}"
setup_home
setup_idf_env

if ! command -v idf.py &> /dev/null; then
    echo "[esp_configure] Error: idf.py not found"
    exit 1
fi

# Extract chip type from sdkconfig
cd "$WORK/project"
ESP_CHIP=$(grep -E '^CONFIG_IDF_TARGET=' sdkconfig.defaults | sed 's/CONFIG_IDF_TARGET="\\(.*\\)"/\\1/' | head -1)
if [ -z "$ESP_CHIP" ]; then
    echo "[esp_configure] Error: CONFIG_IDF_TARGET not found"
    exit 1
fi
echo "[esp_configure] Chip: $ESP_CHIP"

# Run configure only (no build)
idf.py set-target "$ESP_CHIP"
idf.py reconfigure

# Copy generated config directory (contains sdkconfig.h)
cp -r "$WORK/project/build/config/." "{config_dir}"

# Extract include directories from CMake
# Parse compile_commands.json or use cmake --build to get includes
# Simpler: list the standard IDF component include paths
echo "[esp_configure] Extracting include directories..."
cat > "{include_dirs_file}" << 'IDEOF'
IDEOF

# Get include dirs from the CMake cache
cmake -L "$WORK/project/build" 2>/dev/null | grep -E '_INCLUDE_DIRS|_DIR' | while IFS='=' read -r key value; do
    echo "$value" >> "{include_dirs_file}"
done

# Also add the standard paths that are always needed
echo "{config_dir}" >> "{include_dirs_file}"
echo "$IDF_PATH/components/esp_common/include" >> "{include_dirs_file}"
echo "$IDF_PATH/components/esp_system/include" >> "{include_dirs_file}"

echo "[esp_configure] Done. Config at {config_dir}"
""".format(
        requires = requires,
        sdkconfig_path = sdkconfig_file.path,
        config_dir = config_dir.path,
        include_dirs_file = include_dirs_file.path,
        common_sh = [f for f in script_files if f.basename == "common.sh"][0].path,
        idf_component_yml = """
cat > "$WORK/project/main/idf_component.yml" << 'COMPEOF'
dependencies:
{deps}COMPEOF
""".format(deps = idf_deps_yml) if idf_deps_yml else "",
    )
    
    ctx.actions.write(
        output = configure_script,
        content = script_content,
        is_executable = True,
    )
    
    ctx.actions.run_shell(
        command = configure_script.path,
        inputs = [sdkconfig_file, configure_script] + script_files,
        outputs = [config_dir, include_dirs_file],
        execution_requirements = {
            "local": "1",
            "requires-network": "1",
        },
        mnemonic = "EspConfigure",
        progress_message = "ESP-IDF configure %s" % ctx.label,
        use_default_shell_env = True,
    )
    
    return [DefaultInfo(files = depset([config_dir, include_dirs_file]))]

esp_configure = rule(
    implementation = _esp_configure_impl,
    attrs = {
        "sdkconfig": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "sdkconfig target (from esp_sdkconfig rule)",
        ),
        "requires": attr.string_list(
            default = ["freertos"],
            doc = "ESP-IDF component requirements for configure",
        ),
        "idf_deps": attr.string_list(
            default = [],
            doc = "IDF component manager dependencies",
        ),
        "_scripts": attr.label(
            default = _SCRIPTS_LABEL,
        ),
    },
    doc = """Run ESP-IDF CMake configure to generate sdkconfig.h.
    
    Per-app target. Output is a directory containing sdkconfig.h and
    a file listing IDF include directories. Used by zig_library for
    lib/platform/esp/idf compilation.
    """,
)

# =============================================================================
# esp_zig_app - Build ESP-IDF project from app (generates shell automatically)
# =============================================================================

def _esp_zig_app_impl(ctx):
    """Build an ESP-IDF project with Zig — Bazel-native module resolution.
    
    Uses zig build-lib directly with -M flags from ZigModuleInfo.
    No build.zig generation. No Zig source copying. CMake only for
    ESP-IDF framework compilation and linking.
    """
    
    # Output files
    project_name = ctx.attr.project_name or ctx.label.name
    bin_file = ctx.actions.declare_file("{}.bin".format(project_name))
    elf_file = ctx.actions.declare_file("{}.elf".format(project_name))
    bootloader_file = ctx.actions.declare_file("bootloader.bin")
    partition_file = ctx.actions.declare_file("partition-table.bin")
    
    # Get app files (app.zig, platform.zig, board files)
    app_files = ctx.attr.app.files.to_list()
    app_name = ctx.attr.app.label.package.split("/")[-1]
    
    # Find app.zig root source
    app_zig = None
    for f in app_files:
        if f.basename == "app.zig":
            app_zig = f
            break
    if not app_zig:
        fail("No app.zig found in app sources")
    
    # Collect cmake module files
    cmake_files = []
    for cmake in ctx.attr.cmake_modules:
        cmake_files.extend(cmake.files.to_list())
    
    # Get Zig toolchain path
    zig_files = ctx.attr._zig_toolchain.files.to_list()
    zig_bin = None
    for f in zig_files:
        if f.basename == "zig" and f.is_source:
            zig_bin = f
            break
    
    # Get lib files (C helpers, cmake modules — for CMake side only)
    lib_files = ctx.attr._libs.files.to_list()
    
    # Detect cmake prefix (handles external repo)
    cmake_prefix = "cmake"
    lib_prefix = "lib"
    if lib_files:
        first_lib = lib_files[0].short_path
        parts = first_lib.split("/lib/", 1)
        if len(parts) == 2:
            lib_prefix = parts[0] + "/lib"
            cmake_prefix = parts[0] + "/cmake"
    
    # Build settings
    board_flag = ctx.attr._board[BuildSettingInfo].value if ctx.attr._board and BuildSettingInfo in ctx.attr._board else ""
    board = board_flag if board_flag else (ctx.attr.boards[0] if ctx.attr.boards else DEFAULT_BOARD)
    boards_list = ctx.attr.boards if ctx.attr.boards else ["esp32s3_devkit"]
    
    # Get env, sdkconfig, partition, app_config files
    env_file = None
    if ctx.attr.env:
        env_files_list = ctx.attr.env.files.to_list()
        if env_files_list:
            env_file = env_files_list[0]
    
    script_files = ctx.attr._scripts.files.to_list()
    build_sh = None
    for f in script_files:
        if f.basename == "build.sh":
            build_sh = f
            break
    
    sdkconfig_file = None
    sdkconfig_files = []
    if ctx.attr.sdkconfig:
        sdkconfig_files = ctx.attr.sdkconfig.files.to_list()
        if sdkconfig_files:
            sdkconfig_file = sdkconfig_files[0]
    
    partition_csv_file = None
    partition_sdkconfig_file = None
    partition_files = []
    if ctx.attr.partition_table:
        if EspPartitionTableInfo in ctx.attr.partition_table:
            pt = ctx.attr.partition_table[EspPartitionTableInfo]
            partition_csv_file = pt.csv_file
            partition_sdkconfig_file = pt.sdkconfig_file
            partition_files = [partition_csv_file, partition_sdkconfig_file]
    
    app_config_file = None
    app_config_files = []
    if ctx.attr.app_config:
        app_config_files = ctx.attr.app_config.files.to_list()
        if app_config_files:
            app_config_file = app_config_files[0]
    
    # Copy commands for CMake / C helper files only (NOT Zig sources)
    cmake_copy_commands = _generate_copy_commands_preserve_structure(cmake_files)
    lib_copy_commands = _generate_copy_commands_preserve_structure(lib_files)
    
    # ESP-IDF configuration
    requires = " ".join(ctx.attr.requires) if ctx.attr.requires else "driver"
    force_link = "\n        ".join(ctx.attr.force_link) if ctx.attr.force_link else ""
    extra_cmake = "\n".join(ctx.attr.extra_cmake) if ctx.attr.extra_cmake else ""
    extra_c_sources = " ".join(["${" + s + "}" for s in ctx.attr.extra_c_sources]) if ctx.attr.extra_c_sources else ""
    
    idf_deps_yml = ""
    for dep in ctx.attr.idf_deps:
        parts = dep.split(":")
        if len(parts) == 2:
            idf_deps_yml += '  {}: "{}"\n'.format(parts[0], parts[1])
        else:
            idf_deps_yml += '  {}: "*"\n'.format(dep)
    
    # =========================================================================
    # Build Zig module args from ZigModuleInfo (Bazel-native, no build.zig)
    # =========================================================================
    
    # Collect all deps
    dep_infos = []
    all_dep_files = []  # All files needed as Bazel action inputs
    for dep in ctx.attr.deps:
        if ZigModuleInfo in dep:
            info = dep[ZigModuleInfo]
            dep_infos.append(info)
            all_dep_files.extend(info.transitive_srcs.to_list())
            all_dep_files.extend(info.transitive_c_inputs.to_list())
            if info.transitive_lib_as:
                all_dep_files.extend(info.transitive_lib_as.to_list())
    
    # Build "app" module: the user's app.zig
    # App's direct deps = all user-specified deps by module name
    app_dep_names = [info.module_name for info in dep_infos]
    
    # Encode app module + collect transitive module strings
    app_module_str = encode_module("app", app_zig.path, app_dep_names)
    
    all_module_strings = depset(
        [app_module_str] + [
            encode_module(
                info.module_name, info.root_source.path, info.direct_dep_names,
                c_include_dirs = info.own_c_include_dirs, link_libc = info.own_link_libc,
            )
            for info in dep_infos
        ],
        transitive = [info.transitive_module_strings for info in dep_infos],
    )
    
    # Build -M args for all dep modules (same logic as zig_binary)
    # The "main" module is main.zig (generated at runtime in WORK)
    # main.zig imports: app, idf (for log, sdkconfig)
    main_dep_names = ["app"]
    # Check if "idf" is in deps (for the main.zig @cImport)
    for info in dep_infos:
        if info.module_name == "idf" and "idf" not in main_dep_names:
            main_dep_names.append("idf")
    
    # Generate the module args as lines (paths use $E/ placeholder for exec-root)
    zig_mod_lines = []
    needs_libc = False
    seen = {"main": True}
    
    for encoded in all_module_strings.to_list():
        mod = decode_module(encoded)
        if mod.name in seen:
            continue
        seen[mod.name] = True
        
        for d in mod.dep_names:
            zig_mod_lines.append("--dep " + d)
        zig_mod_lines.append("-M{name}=$E/{path}".format(name = mod.name, path = mod.root_path))
        
        for inc in mod.c_include_dirs:
            zig_mod_lines.append("-I $E/" + inc)
        
        if mod.link_libc:
            needs_libc = True
    
    # Dep .a libraries for linking
    dep_lib_a_lines = []
    for info in dep_infos:
        if info.transitive_lib_as:
            for a in info.transitive_lib_as.to_list():
                dep_lib_a_lines.append("$E/" + a.path)
    
    # Main module args (main.zig is generated in WORK, path set at runtime)
    main_mod_args = ""
    for d in main_dep_names:
        main_mod_args += "--dep {} ".format(d)
    main_mod_args += "-Mmain=$WORK/esp_project/main/src/main.zig"
    
    zig_module_args_str = "\n".join(zig_mod_lines)
    zig_lib_a_str = "\n".join(dep_lib_a_lines)
    needs_libc_str = "-lc" if needs_libc else ""
    
    # (Old build.zig.zon generation removed — replaced by zig_module_args above)
    
    # Create wrapper script — Bazel-native, no build.zig
    build_script = ctx.actions.declare_file("{}_build.sh".format(ctx.label.name))
    
    script_content = """#!/bin/bash
set -e
export ESP_BAZEL_RUN=1 ESP_BOARD="{board}"
export ESP_PROJECT_NAME="{project_name}" ESP_BIN_OUT="{bin_out}" ESP_ELF_OUT="{elf_out}"
export ESP_BOOTLOADER_OUT="{bootloader_out}" ESP_PARTITION_OUT="{partition_out}"
export ZIG_INSTALL="$(pwd)/{zig_dir}" ESP_EXECROOT="$(pwd)"
export ESP_APP_NAME="{app_name}"
E="$ESP_EXECROOT"
{env_file_export}

# Load app config if provided (for run_in_psram)
{app_config_source}

WORK=$(mktemp -d) && export ESP_WORK_DIR="$WORK" && trap "rm -rf $WORK" EXIT

# Copy CMake/C helper files only (Zig sources use exec-root paths)
{cmake_copy_commands}
{lib_copy_commands}

# Generate ESP-IDF project
export ESP_PROJECT_PATH="esp_project"
mkdir -p "$WORK/$ESP_PROJECT_PATH/main/src"

# top-level CMakeLists.txt
cat > "$WORK/$ESP_PROJECT_PATH/CMakeLists.txt" << 'CMAKEOF'
cmake_minimum_required(VERSION 3.16)
include(${{CMAKE_CURRENT_SOURCE_DIR}}/../{cmake_prefix}/zig_install.cmake)
include($ENV{{IDF_PATH}}/tools/cmake/project.cmake)
project({project_name})
CMAKEOF

# main/CMakeLists.txt
cat > "$WORK/$ESP_PROJECT_PATH/main/CMakeLists.txt" << 'MAINCMAKEOF'
get_filename_component(_ESP_LIB "${{CMAKE_CURRENT_SOURCE_DIR}}/../../{lib_prefix}" ABSOLUTE)
{extra_cmake}
idf_component_register(
    SRCS "src/main.c" {extra_c_sources}
    INCLUDE_DIRS "."
    REQUIRES {requires}
)
if(COMMAND event_setup_includes)
    event_setup_includes()
endif()
if(COMMAND mbed_tls_setup_includes)
    mbed_tls_setup_includes()
endif()
if(COMMAND net_setup_includes)
    net_setup_includes()
endif()
esp_zig_build(
    FORCE_LINK
        {force_link}
)
MAINCMAKEOF

# Write zig module args (Bazel-computed -M flags, $E/ = exec-root)
cat > "$WORK/$ESP_PROJECT_PATH/main/zig_module_args.txt" << 'ZIGARGSEOF'
{zig_module_args}
ZIGARGSEOF

# Write .a library args
cat > "$WORK/$ESP_PROJECT_PATH/main/zig_lib_a_args.txt" << 'ZIGLAEOF'
{zig_lib_a_args}
ZIGLAEOF

# Expand $E/ placeholder to actual exec-root path
sed -i.bak "s|\\$E/|$E/|g" "$WORK/$ESP_PROJECT_PATH/main/zig_module_args.txt"
sed -i.bak "s|\\$E/|$E/|g" "$WORK/$ESP_PROJECT_PATH/main/zig_lib_a_args.txt"
rm -f "$WORK/$ESP_PROJECT_PATH/main/"*.bak

# Write main module args (main.zig path is in WORK, set at runtime)
echo '{main_mod_args}' | sed "s|\\$WORK|$WORK|g" > "$WORK/$ESP_PROJECT_PATH/main/zig_main_args.txt"

# Generate zig_build.sh (called by CMake esp_zig_build)
ZIG_BUILD_SH="$WORK/$ESP_PROJECT_PATH/main/zig_build.sh"
cat > "$ZIG_BUILD_SH" << 'ZIGBUILDEOF'
#!/bin/bash
set -e
ESP_INC_DIRS="$1"; ZIG_TARGET="$2"; CPU_MODEL="$3"
BUILD_TYPE="$4"; OUTPUT_A="$5"; ZIG_BIN="$6"

ESP_I=""
IFS=';' read -ra DIRS <<< "$ESP_INC_DIRS"
for d in "${{DIRS[@]}}"; do [ -n "$d" ] && ESP_I="$ESP_I -I $d"; done

MAIN_ARGS=$(cat zig_main_args.txt 2>/dev/null || echo "")
MOD_ARGS=$(cat zig_module_args.txt 2>/dev/null | tr '\n' ' ')
LIB_ARGS=$(cat zig_lib_a_args.txt 2>/dev/null | tr '\n' ' ')

echo "[zig] build-lib target=$ZIG_TARGET cpu=$CPU_MODEL"
$ZIG_BIN build-lib \
    -lc $ESP_I $MAIN_ARGS $MOD_ARGS $LIB_ARGS \
    -target $ZIG_TARGET -Dcpu=$CPU_MODEL -O$BUILD_TYPE \
    -freference-trace \
    --cache-dir $(dirname $OUTPUT_A)/../../.zig-cache \
    --global-cache-dir $(dirname $OUTPUT_A)/../../.zig-global-cache \
    -femit-bin=$OUTPUT_A
ZIGBUILDEOF
chmod +x "$WORK/$ESP_PROJECT_PATH/main/zig_build.sh"

# main.c
cat > "$WORK/$ESP_PROJECT_PATH/main/src/main.c" << 'MAINCEOF'
extern void app_main(void);
MAINCEOF

# env.zig
ENV_STRUCT_FIELDS=""
ENV_STRUCT_VALUES=""
if [ -n "$ESP_ENV_FILE" ] && [ -f "$ESP_ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in '#'*|"") continue ;; esac
        line="${{line#export }}"
        key="${{line%%=*}}"
        value="${{line#*=}}"
        value="${{value#'"'}}"
        value="${{value%'"'}}"
        field=$(echo "$key" | tr '[:upper:]' '[:lower:]')
        if [ -n "$ENV_STRUCT_FIELDS" ]; then
            ENV_STRUCT_FIELDS="$ENV_STRUCT_FIELDS
    $field: [:0]const u8,"
            ENV_STRUCT_VALUES="$ENV_STRUCT_VALUES
    .$field = \\"$value\\","
        else
            ENV_STRUCT_FIELDS="    $field: [:0]const u8,"
            ENV_STRUCT_VALUES="    .$field = \\"$value\\","
        fi
    done < "$ESP_ENV_FILE"
fi
cat > "$WORK/$ESP_PROJECT_PATH/main/src/env.zig" << ENVZIGEOF
pub const Env = struct {{
$ENV_STRUCT_FIELDS
}};
pub const env: Env = .{{
$ENV_STRUCT_VALUES
}};
ENVZIGEOF

# main.zig
if [ "$RUN_APP_IN_PSRAM" = "y" ]; then
    cat > "$WORK/$ESP_PROJECT_PATH/main/src/build_options.zig" << BOOF
pub const psram_stack_size: usize = $PSRAM_STACK_SIZE;
BOOF
    cat > "$WORK/$ESP_PROJECT_PATH/main/src/main.zig" << 'MAINZIGEOF'
const std = @import("std");
const idf = @import("idf");
const app = @import("app");
const build_options = @import("build_options.zig");
pub const env_module = @import("env.zig");
const c = @cImport({{ @cInclude("sdkconfig.h"); @cInclude("freertos/FreeRTOS.h"); @cInclude("freertos/task.h"); @cInclude("esp_heap_caps.h"); }});
const log_level: std.log.Level = if (c.CONFIG_LOG_DEFAULT_LEVEL >= 4) .debug else if (c.CONFIG_LOG_DEFAULT_LEVEL >= 3) .info else if (c.CONFIG_LOG_DEFAULT_LEVEL >= 2) .warn else .err;
pub const std_options = std.Options{{ .log_level = log_level, .logFn = idf.log.stdLogFn }};
const PSRAM_TASK_STACK_SIZE = build_options.psram_stack_size;
const PSRAM_TASK_STACK_WORDS = PSRAM_TASK_STACK_SIZE / @sizeOf(c.StackType_t);
var task_tcb: c.StaticTask_t = undefined;
var psram_stack: ?[*]c.StackType_t = null;
fn appTaskFn(_: ?*anyopaque) callconv(.c) void {{ app.run(env_module.env); while (true) {{ c.vTaskDelay(c.portMAX_DELAY); }} }}
export fn app_main() void {{
    std.log.info("Starting app in PSRAM task (stack: {{d}}KB)", .{{PSRAM_TASK_STACK_SIZE / 1024}});
    psram_stack = @ptrCast(@alignCast(c.heap_caps_malloc(PSRAM_TASK_STACK_SIZE, c.MALLOC_CAP_SPIRAM)));
    if (psram_stack == null) {{ std.log.err("PSRAM alloc failed", .{{}}); app.run(env_module.env); return; }}
    const task_handle = c.xTaskCreateStatic(appTaskFn, "app", PSRAM_TASK_STACK_WORDS, null, 5, psram_stack.?, &task_tcb);
    if (task_handle == null) {{ std.log.err("Task create failed", .{{}}); c.heap_caps_free(psram_stack); app.run(env_module.env); return; }}
}}
MAINZIGEOF
else
    cat > "$WORK/$ESP_PROJECT_PATH/main/src/main.zig" << 'MAINZIGEOF'
const std = @import("std");
const idf = @import("idf");
const app = @import("app");
pub const env_module = @import("env.zig");
const c = @cImport({{ @cInclude("sdkconfig.h"); }});
const log_level: std.log.Level = if (c.CONFIG_LOG_DEFAULT_LEVEL >= 4) .debug else if (c.CONFIG_LOG_DEFAULT_LEVEL >= 3) .info else if (c.CONFIG_LOG_DEFAULT_LEVEL >= 2) .warn else .err;
pub const std_options = std.Options{{ .log_level = log_level, .logFn = idf.log.stdLogFn }};
export fn app_main() void {{ app.run(env_module.env); }}
MAINZIGEOF
fi

# sdkconfig
cat > "$WORK/$ESP_PROJECT_PATH/sdkconfig.defaults" << SDKCONFIGEOF
CONFIG_ESPTOOLPY_FLASHSIZE_4MB=y
SDKCONFIGEOF
{partition_sdkconfig_append}
if ! grep -q "CONFIG_PARTITION_TABLE" "$WORK/$ESP_PROJECT_PATH/sdkconfig.defaults"; then
    echo "CONFIG_PARTITION_TABLE_SINGLE_APP_LARGE=y" >> "$WORK/$ESP_PROJECT_PATH/sdkconfig.defaults"
fi
{partition_csv_copy}
{sdkconfig_append}

if [ -n "{idf_deps_yml}" ]; then
cat > "$WORK/$ESP_PROJECT_PATH/main/idf_component.yml" << 'IDFCOMPEOF'
dependencies:
{idf_deps_yml}IDFCOMPEOF
fi

exec bash "{build_sh}"
""".format(
        board = board,
        env_file_export = 'export ESP_ENV_FILE="$(pwd)/{}"'.format(env_file.path) if env_file else "",
        app_config_source = 'source "{}"'.format(app_config_file.path) if app_config_file else "",
        project_name = project_name,
        bin_out = bin_file.path,
        elf_out = elf_file.path,
        bootloader_out = bootloader_file.path,
        partition_out = partition_file.path,
        zig_dir = zig_bin.dirname if zig_bin else "",
        build_sh = build_sh.path if build_sh else "",
        app_name = app_name,
        cmake_copy_commands = "\n".join(cmake_copy_commands),
        lib_copy_commands = "\n".join(lib_copy_commands),
        cmake_prefix = cmake_prefix,
        lib_prefix = lib_prefix,
        requires = requires,
        force_link = force_link,
        extra_cmake = extra_cmake,
        extra_c_sources = extra_c_sources,
        zig_module_args = zig_module_args_str,
        zig_lib_a_args = zig_lib_a_str,
        main_mod_args = main_mod_args,
        idf_deps_yml = idf_deps_yml,
        partition_sdkconfig_append = 'cat "{}" >> "$WORK/$ESP_PROJECT_PATH/sdkconfig.defaults"'.format(partition_sdkconfig_file.path) if partition_sdkconfig_file else "",
        partition_csv_copy = 'cp "{}" "$WORK/$ESP_PROJECT_PATH/"'.format(partition_csv_file.path) if partition_csv_file else "",
        sdkconfig_append = 'cat "{}" >> "$WORK/$ESP_PROJECT_PATH/sdkconfig.defaults"'.format(sdkconfig_file.path) if sdkconfig_file else "",
    )
    
    ctx.actions.write(
        output = build_script,
        content = script_content,
        is_executable = True,
    )
    
    # Collect all inputs — Zig sources via exec-root paths (no copying needed)
    env_files = [env_file] if env_file else []
    app_cfg_files = [app_config_file] if app_config_file else []
    inputs = app_files + cmake_files + zig_files + lib_files + all_dep_files + script_files + sdkconfig_files + env_files + app_cfg_files + partition_files + [build_script]
    
    ctx.actions.run_shell(
        command = build_script.path,
        inputs = inputs,
        outputs = [bin_file, elf_file, bootloader_file, partition_file],
        execution_requirements = {
            "local": "1",
            "requires-network": "1",
        },
        mnemonic = "EspZigBuild",
        progress_message = "Building ESP Zig app %s (board=%s)" % (ctx.label, board),
        use_default_shell_env = True,
    )
    
    return [
        DefaultInfo(
            files = depset([bin_file, elf_file, bootloader_file, partition_file]),
            runfiles = ctx.runfiles(files = [bin_file, elf_file, bootloader_file, partition_file]),
        ),
        OutputGroupInfo(
            bin = depset([bin_file]),
            elf = depset([elf_file]),
            bootloader = depset([bootloader_file]),
            partition = depset([partition_file]),
        ),
    ]


esp_zig_app = rule(
    implementation = _esp_zig_app_impl,
    attrs = {
        "app": attr.label(
            mandatory = True,
            allow_files = True,
            doc = "App target from examples/apps/",
        ),
        "project_name": attr.string(
            doc = "Project name (defaults to target name)",
        ),
        "boards": attr.string_list(
            default = ["esp32s3_devkit"],
            doc = "Supported board types for this app (first one is default)",
        ),
        "requires": attr.string_list(
            default = ["driver"],
            doc = "ESP-IDF component dependencies (REQUIRES in CMakeLists.txt)",
        ),
        "force_link": attr.string_list(
            default = [],
            doc = "Symbols to force link (FORCE_LINK in esp_zig_build)",
        ),
        "extra_cmake": attr.string_list(
            default = [],
            doc = "Extra CMake commands (e.g., include statements)",
        ),
        "extra_c_sources": attr.string_list(
            default = [],
            doc = "Extra C source variables (e.g., I2C_C_SOURCES)",
        ),
        "deps": attr.label_list(
            providers = [ZigModuleInfo],
            doc = "Zig library dependencies (e.g., //lib/hal, //lib/pkg/drivers)",
        ),
        "idf_deps": attr.string_list(
            default = [],
            doc = "IDF component manager dependencies (e.g., espressif/led_strip:^3.0.0)",
        ),
        "sdkconfig": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "sdkconfig target from esp_sdkconfig rule (e.g., //examples/esp:esp32s3)",
        ),
        "partition_table": attr.label(
            providers = [EspPartitionTableInfo],
            doc = "Partition table from esp_partition_table rule. If not set, uses default single_app_large.",
        ),
        "app_config": attr.label(
            allow_single_file = True,
            doc = "App runtime config from esp_app rule (e.g., //examples/esp:app)",
        ),
        "env": attr.label(
            allow_single_file = True,
            doc = """Environment file with KEY=VALUE pairs (one per line).
            Variables: WIFI_SSID, WIFI_PASSWORD, TEST_SERVER_IP, TEST_SERVER_PORT.
            Example file:
                WIFI_SSID=MyWiFi
                WIFI_PASSWORD=secret""",
        ),
        "cmake_modules": attr.label_list(
            allow_files = True,
            default = [_CMAKE_MODULES_LABEL],
            doc = "CMake module files",
        ),
        "_zig_toolchain": attr.label(
            default = "@zig_toolchain//:zig_files",
        ),
        "_libs": attr.label(
            default = _LIBS_LABEL,
        ),
        "_board": attr.label(
            default = "//bazel:board",
        ),
        "_scripts": attr.label(
            default = _SCRIPTS_LABEL,
        ),
    },
    doc = "Build an ESP-IDF Zig app, generating the ESP shell automatically",
)

# =============================================================================
# esp_flash - Flash binary to device
# =============================================================================

def _esp_flash_impl(ctx):
    """Flash an ESP-IDF binary to a device."""
    
    # Get the binary files to flash
    app_files = ctx.attr.app.files.to_list()
    bin_file = None
    bootloader_file = None
    partition_file = None
    for f in app_files:
        if f.basename == "bootloader.bin":
            bootloader_file = f
        elif f.basename == "partition-table.bin":
            partition_file = f
        elif f.path.endswith(".bin") and not bin_file:
            bin_file = f
    
    if not bin_file:
        fail("No .bin file found in app target")
    
    # Get configuration
    board = ctx.attr._board[BuildSettingInfo].value if ctx.attr._board and BuildSettingInfo in ctx.attr._board else DEFAULT_BOARD
    port = ctx.attr._port[BuildSettingInfo].value if ctx.attr._port and BuildSettingInfo in ctx.attr._port else ""
    baud = ctx.attr._baud[BuildSettingInfo].value if ctx.attr._baud and BuildSettingInfo in ctx.attr._baud else "460800"
    
    # Get script files
    script_files = ctx.attr._scripts.files.to_list()
    
    # Collect data partition bins and NVS info if partition_table is provided
    data_flash_args = ""
    data_files = []
    nvs_offset = ""
    nvs_size = ""
    if ctx.attr.partition_table and EspPartitionTableInfo in ctx.attr.partition_table:
        pt_info = ctx.attr.partition_table[EspPartitionTableInfo]
        for name, info in pt_info.data_bins.items():
            data_flash_args += " 0x%X %s" % (info["offset"], info["bin"].short_path)
            data_files.append(info["bin"])
        # Find NVS partition for --erase-nvs feature
        for name, pinfo in pt_info.partition_info.items():
            if pinfo["subtype"] == "nvs":
                nvs_offset = "0x%X" % pinfo["offset"]
                nvs_size = "0x%X" % pinfo["size"]
                break
    
    # Create wrapper script
    flash_script = ctx.actions.declare_file("{}_flash.sh".format(ctx.label.name))
    
    # Determine if we have full flash files
    has_full_flash = bootloader_file and partition_file
    
    script_content = """#!/bin/bash
set -e

# Mark as Bazel-invoked
export ESP_BAZEL_RUN=1

# Configuration
export ESP_BOARD="{board}"
export ESP_BAUD="{baud}"
export ESP_BIN="{bin_path}"
export ESP_BOOTLOADER="{bootloader_path}"
export ESP_PARTITION="{partition_path}"
export ESP_PORT_CONFIG="{port}"
export ESP_FULL_FLASH="{full_flash}"
export ESP_DATA_FLASH_ARGS="{data_flash_args}"
export ESP_NVS_OFFSET="{nvs_offset}"
export ESP_NVS_SIZE="{nvs_size}"

# Parse command line arguments
APP_ONLY=0
ERASE_NVS=0
for arg in "$@"; do
    case $arg in
        --app-only)
            APP_ONLY=1
            ;;
        --erase-nvs)
            ERASE_NVS=1
            ;;
    esac
done

# Source common functions
source "{common_sh}"

# Run flash
setup_home
find_idf_python

if ! detect_serial_port "$ESP_PORT_CONFIG" "esp_flash"; then
    exit 1
fi

# Kill any process using the port
if lsof "$PORT" >/dev/null 2>&1; then
    echo "[esp_flash] Killing process using $PORT..."
    lsof -t "$PORT" | xargs kill 2>/dev/null || true
    sleep 0.5
fi

echo "[esp_flash] Board: $ESP_BOARD"
echo "[esp_flash] Flashing to $PORT at $ESP_BAUD baud..."
echo "[esp_flash] Binary: $ESP_BIN"

# Detect reset mode based on port type
# USB-JTAG ports (usbmodem) need usb_reset for entering bootloader
# USB-JTAG DTR/RTS are CDC virtual signals - use watchdog reset instead
if [[ "$PORT" == *"usbmodem"* ]]; then
    BEFORE_RESET="usb_reset"
    AFTER_RESET="no_reset"
    USB_JTAG_MODE=1
    echo "[esp_flash] Using USB-JTAG mode (watchdog reset after flash)"
else
    BEFORE_RESET="default_reset"
    AFTER_RESET="hard_reset"
    USB_JTAG_MODE=0
fi

# Erase NVS if requested
if [[ "$ERASE_NVS" == "1" ]]; then
    if [[ -n "$ESP_NVS_OFFSET" && -n "$ESP_NVS_SIZE" ]]; then
        echo "[esp_flash] Erasing NVS partition at $ESP_NVS_OFFSET (size: $ESP_NVS_SIZE)..."
        "$IDF_PYTHON" -m esptool --port "$PORT" --baud "$ESP_BAUD" \\
            --before "$BEFORE_RESET" --after "no_reset" \\
            erase_region $ESP_NVS_OFFSET $ESP_NVS_SIZE
    else
        # Fallback to default offset for backward compatibility
        echo "[esp_flash] Warning: NVS partition info not available, using default (0x9000, 0x6000)"
        "$IDF_PYTHON" -m esptool --port "$PORT" --baud "$ESP_BAUD" \\
            --before "$BEFORE_RESET" --after "no_reset" \\
            erase_region 0x9000 0x6000
    fi
fi

# Build flash arguments
FLASH_ARGS=""

if [[ "$APP_ONLY" == "1" ]]; then
    echo "[esp_flash] App-only mode"
    FLASH_ARGS="0x10000 $ESP_BIN"
elif [[ "$ESP_FULL_FLASH" == "1" ]]; then
    echo "[esp_flash] Full flash mode (bootloader + partition + app)"
    FLASH_ARGS="0x0 $ESP_BOOTLOADER 0x8000 $ESP_PARTITION 0x10000 $ESP_BIN"
    # Add data partitions if any
    if [[ -n "$ESP_DATA_FLASH_ARGS" ]]; then
        FLASH_ARGS="$FLASH_ARGS$ESP_DATA_FLASH_ARGS"
        echo "[esp_flash] Including data partitions"
    fi
else
    FLASH_ARGS="0x10000 $ESP_BIN"
fi

# esptool auto-detects chip type
"$IDF_PYTHON" -m esptool --port "$PORT" --baud "$ESP_BAUD" \\
    --before "$BEFORE_RESET" --after "$AFTER_RESET" \\
    write_flash -z $FLASH_ARGS

# For USB-JTAG, use watchdog reset (DTR/RTS don't work)
if [[ "$USB_JTAG_MODE" == "1" ]]; then
    echo "[esp_flash] Executing watchdog reset..."
    "$IDF_PYTHON" -c "
import esptool
esp = esptool.detect_chip('$PORT', 115200, 'usb_reset', False, 3)
esp = esp.run_stub()
esp.watchdog_reset()
" 2>/dev/null || echo "[esp_flash] Watchdog reset failed, manual RST may be needed"
fi

echo "[esp_flash] Flash complete!"
""".format(
        board = board,
        baud = baud,
        port = port,
        bin_path = bin_file.short_path,
        bootloader_path = bootloader_file.short_path if bootloader_file else "",
        partition_path = partition_file.short_path if partition_file else "",
        full_flash = "1" if has_full_flash else "0",
        data_flash_args = data_flash_args,
        nvs_offset = nvs_offset,
        nvs_size = nvs_size,
        common_sh = [f for f in script_files if f.basename == "common.sh"][0].path,
    )
    
    ctx.actions.write(
        output = flash_script,
        content = script_content,
        is_executable = True,
    )
    
    # Collect all flash files
    flash_files = [bin_file] + data_files
    if bootloader_file:
        flash_files.append(bootloader_file)
    if partition_file:
        flash_files.append(partition_file)
    
    return [
        DefaultInfo(
            executable = flash_script,
            runfiles = ctx.runfiles(files = flash_files + script_files),
        ),
    ]

esp_flash = rule(
    implementation = _esp_flash_impl,
    executable = True,
    attrs = {
        "app": attr.label(
            mandatory = True,
            doc = "ESP-IDF app target to flash",
        ),
        "partition_table": attr.label(
            providers = [EspPartitionTableInfo],
            doc = "Partition table with data bins to flash. Optional.",
        ),
        "_board": attr.label(
            default = "//bazel:board",
        ),
        "_port": attr.label(
            default = "//bazel:port",
        ),
        "_baud": attr.label(
            default = "//bazel:baud",
        ),
        "_scripts": attr.label(
            default = _SCRIPTS_LABEL,
        ),
    },
    doc = "Flash an ESP-IDF binary to a device",
)

# =============================================================================
# esp_monitor - Monitor serial output
# =============================================================================

def _esp_monitor_impl(ctx):
    """Monitor serial output from an ESP32 device."""
    
    # Get configuration
    board = ctx.attr._board[BuildSettingInfo].value if ctx.attr._board and BuildSettingInfo in ctx.attr._board else DEFAULT_BOARD
    port = ctx.attr._port[BuildSettingInfo].value if ctx.attr._port and BuildSettingInfo in ctx.attr._port else ""
    
    # Get script files
    script_files = ctx.attr._scripts.files.to_list()
    
    # Create wrapper script
    monitor_script = ctx.actions.declare_file("{}_monitor.sh".format(ctx.label.name))
    
    script_content = """#!/bin/bash
set -e

# Mark as Bazel-invoked
export ESP_BAZEL_RUN=1

# Configuration
export ESP_BOARD="{board}"
export ESP_MONITOR_BAUD="115200"
export ESP_PORT_CONFIG="{port}"

# Source common functions
source "{common_sh}"

# Run monitor
setup_home
find_idf_python

if ! detect_serial_port "$ESP_PORT_CONFIG" "esp_monitor"; then
    exit 1
fi

# Kill any process using the port
if lsof "$PORT" >/dev/null 2>&1; then
    echo "[esp_monitor] Killing process using $PORT..."
    lsof -t "$PORT" | xargs kill 2>/dev/null || true
    sleep 0.5
fi

echo "[esp_monitor] Board: $ESP_BOARD"
echo "[esp_monitor] Monitoring $PORT at $ESP_MONITOR_BAUD baud..."
echo "[esp_monitor] Press Ctrl+C to exit"

"$IDF_PYTHON" -c "
import serial
import sys

try:
    ser = serial.Serial('$PORT', $ESP_MONITOR_BAUD, timeout=0.5)
    ser.setDTR(False)  # Don't trigger reset
    ser.setRTS(False)
    print('Connected to $PORT at $ESP_MONITOR_BAUD baud')
    print('Waiting for data... (press RST on device if needed)')
    print('---')
    while True:
        data = ser.read(ser.in_waiting or 1)
        if data:
            text = data.decode('utf-8', errors='replace')
            sys.stdout.write(text)
            sys.stdout.flush()
except KeyboardInterrupt:
    print('\\n--- Monitor stopped ---')
except Exception as e:
    print(f'Error: {{e}}')
    sys.exit(1)
"
""".format(
        board = board,
        port = port,
        common_sh = [f for f in script_files if f.basename == "common.sh"][0].path,
    )
    
    ctx.actions.write(
        output = monitor_script,
        content = script_content,
        is_executable = True,
    )
    
    return [
        DefaultInfo(
            executable = monitor_script,
            runfiles = ctx.runfiles(files = script_files),
        ),
    ]

esp_monitor = rule(
    implementation = _esp_monitor_impl,
    executable = True,
    attrs = {
        "_board": attr.label(
            default = "//bazel:board",
        ),
        "_port": attr.label(
            default = "//bazel:port",
        ),
        "_scripts": attr.label(
            default = _SCRIPTS_LABEL,
        ),
    },
    doc = "Monitor serial output from an ESP32 device",
)

# =============================================================================
# esp_sdkconfig - Concatenate sdkconfig fragments from modules
# =============================================================================

def _esp_sdkconfig_impl(ctx):
    """Concatenate sdkconfig fragments from module rules."""
    out = ctx.actions.declare_file(ctx.attr.name + ".defaults")
    
    # Collect all module fragments (in order)
    module_files = []
    
    # Required modules
    module_files.append(ctx.file.core)
    module_files.append(ctx.file.freertos)
    module_files.append(ctx.file.log)
    
    # Optional modules
    if ctx.attr.psram:
        module_files.append(ctx.file.psram)
    if ctx.attr.wifi:
        module_files.append(ctx.file.wifi)
    if ctx.attr.lwip:
        module_files.append(ctx.file.lwip)
    if ctx.attr.spiffs:
        module_files.append(ctx.file.spiffs)
    if ctx.attr.littlefs:
        module_files.append(ctx.file.littlefs)
    if ctx.attr.sr:
        module_files.append(ctx.file.sr)
    if ctx.attr.crypto:
        module_files.append(ctx.file.crypto)
    if ctx.attr.newlib:
        module_files.append(ctx.file.newlib)
    if ctx.attr.bt:
        module_files.append(ctx.file.bt)
    
    # Concatenate all fragments
    cmd = "echo '# Auto-generated sdkconfig' > {out} && cat {files} >> {out}".format(
        out = out.path,
        files = " ".join([f.path for f in module_files]),
    )
    ctx.actions.run_shell(
        inputs = module_files,
        outputs = [out],
        command = cmd,
    )
    
    return [DefaultInfo(files = depset([out]))]

esp_sdkconfig = rule(
    implementation = _esp_sdkconfig_impl,
    attrs = {
        # Required modules
        "core": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "esp_core rule output",
        ),
        "freertos": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "esp_freertos rule output",
        ),
        "log": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "esp_log rule output",
        ),
        # Optional modules
        "psram": attr.label(
            allow_single_file = True,
            doc = "esp_psram rule output",
        ),
        "wifi": attr.label(
            allow_single_file = True,
            doc = "esp_wifi rule output",
        ),
        "lwip": attr.label(
            allow_single_file = True,
            doc = "esp_lwip rule output",
        ),
        "spiffs": attr.label(
            allow_single_file = True,
            doc = "esp_spiffs rule output",
        ),
        "littlefs": attr.label(
            allow_single_file = True,
            doc = "esp_littlefs rule output",
        ),
        "sr": attr.label(
            allow_single_file = True,
            doc = "esp_sr rule output (ESP-SR speech recognition)",
        ),
        "crypto": attr.label(
            allow_single_file = True,
            doc = "esp_crypto rule output (disable mbedTLS)",
        ),
        "newlib": attr.label(
            allow_single_file = True,
            doc = "esp_newlib rule output (nano printf, etc.)",
        ),
        "bt": attr.label(
            allow_single_file = True,
            doc = "esp_bt rule output (Bluetooth controller, VHCI)",
        ),
    },
    doc = """Concatenate sdkconfig fragments from module rules.

Required:
    - core     : esp_core
    - freertos : esp_freertos  
    - log      : esp_log

Optional:
    - psram    : esp_psram
    - wifi     : esp_wifi
    - lwip     : esp_lwip
    - spiffs   : esp_spiffs
    - littlefs : esp_littlefs
    - crypto   : esp_crypto
    - newlib   : esp_newlib
    - bt       : esp_bt
""",
)
