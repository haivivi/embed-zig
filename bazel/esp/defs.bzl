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
    bazel build //examples/apps/led_strip_flash:esp --//bazel/esp:board=korvo2_v3
    
    # Flash (auto-detect port)
    bazel run //examples/apps/led_strip_flash:flash
    
    # Flash to specific port
    bazel run //examples/apps/led_strip_flash:flash --//bazel/esp:port=/dev/ttyUSB0
    
    # Monitor
    bazel run //bazel/esp:monitor --//bazel/esp:port=/dev/ttyUSB0
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//bazel/esp:settings.bzl", "DEFAULT_BOARD", "DEFAULT_CHIP")

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
        outputs = [bin_file, elf_file],
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
            files = depset([bin_file, elf_file]),
            runfiles = ctx.runfiles(files = [bin_file, elf_file]),
        ),
        OutputGroupInfo(
            bin = depset([bin_file]),
            elf = depset([elf_file]),
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
            default = "//bazel/esp:board",
        ),
        "_scripts": attr.label(
            default = _SCRIPTS_LABEL,
            doc = "Build scripts",
        ),
    },
    doc = "Build an ESP-IDF project with Zig support",
)

# =============================================================================
# esp_zig_app - Build ESP-IDF project from app (generates shell automatically)
# =============================================================================

def _esp_zig_app_impl(ctx):
    """Build an ESP-IDF project with Zig, generating the ESP shell automatically."""
    
    # Output files
    project_name = ctx.attr.project_name or ctx.label.name
    bin_file = ctx.actions.declare_file("{}.bin".format(project_name))
    elf_file = ctx.actions.declare_file("{}.elf".format(project_name))
    
    # Get app files
    app_files = ctx.attr.app.files.to_list()
    app_path = ctx.attr.app.label.package  # e.g., "examples/apps/gpio_button"
    app_name = ctx.attr.app.label.package.split("/")[-1]  # e.g., "gpio_button"
    
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
    
    # Get lib files
    lib_files = ctx.attr._libs.files.to_list()
    
    # Detect lib/cmake prefix from files (handles external repo case)
    # Internal: "lib/esp/..." -> lib_prefix="lib", cmake_prefix="cmake"
    # External: "../embed_zig+/lib/esp/..." -> lib_prefix="../embed_zig+/lib", cmake_prefix="../embed_zig+/cmake"
    lib_prefix = "lib"
    cmake_prefix = "cmake"
    if lib_files:
        first_lib = lib_files[0].short_path
        parts = first_lib.split("/lib/", 1)
        if len(parts) == 2:
            lib_prefix = parts[0] + "/lib"
            cmake_prefix = parts[0] + "/cmake"
    
    # Calculate path from app directory to lib directory
    # app is at $WORK/{app_path}/, lib is at $WORK/../{lib_prefix}/
    # Need: "../" * (app_path_depth + 1) + lib_prefix_without_leading_dotdot
    app_depth = len(app_path.split("/"))
    dotdots_to_work = "../" * app_depth  # from app to $WORK
    if lib_prefix.startswith("../"):
        # External lib: lib_prefix = "../embed_zig+/lib"
        # Path from $WORK to lib = "../embed_zig+/lib"
        # Total path = dotdots_to_work + lib_prefix = "../../../" + "../embed_zig+/lib"
        app_to_lib_prefix = dotdots_to_work + lib_prefix
    else:
        # Internal lib: lib_prefix = "lib"
        # Path from $WORK to lib = "lib"
        # But lib files are copied to $WORK/../lib/ due to short_path behavior
        # Actually for internal, lib is at $WORK/lib/
        app_to_lib_prefix = dotdots_to_work + lib_prefix
    
    # Build settings
    board = ctx.attr._board[BuildSettingInfo].value if ctx.attr._board and BuildSettingInfo in ctx.attr._board else DEFAULT_BOARD
    
    # Get env file if provided
    env_file = None
    if ctx.attr.env:
        env_files = ctx.attr.env.files.to_list()
        if env_files:
            env_file = env_files[0]
    
    # Get script files
    script_files = ctx.attr._scripts.files.to_list()
    build_sh = None
    for f in script_files:
        if f.basename == "build.sh":
            build_sh = f
            break
    
    # Get sdkconfig file if provided
    sdkconfig_file = None
    sdkconfig_files = []
    if ctx.attr.sdkconfig:
        sdkconfig_files = ctx.attr.sdkconfig.files.to_list()
        if sdkconfig_files:
            sdkconfig_file = sdkconfig_files[0]
    
    # Get app_config file if provided (for run_in_psram setting)
    app_config_file = None
    app_config_files = []
    run_in_psram = False
    if ctx.attr.app_config:
        app_config_files = ctx.attr.app_config.files.to_list()
        if app_config_files:
            app_config_file = app_config_files[0]
            # We'll pass this to the shell script to parse
            run_in_psram = True  # Will be determined at runtime from file
    
    # Generate copy commands
    app_copy_commands = _generate_copy_commands_preserve_structure(app_files)
    cmake_copy_commands = _generate_copy_commands_preserve_structure(cmake_files)
    lib_copy_commands = _generate_copy_commands_preserve_structure(lib_files)
    
    # ESP-IDF configuration from attributes
    requires = " ".join(ctx.attr.requires) if ctx.attr.requires else "driver"
    force_link = "\n        ".join(ctx.attr.force_link) if ctx.attr.force_link else ""
    extra_cmake = "\n".join(ctx.attr.extra_cmake) if ctx.attr.extra_cmake else ""
    extra_c_sources = " ".join(["${" + s + "}" for s in ctx.attr.extra_c_sources]) if ctx.attr.extra_c_sources else ""
    
    # IDF component manager dependencies
    idf_deps_yml = ""
    for dep in ctx.attr.idf_deps:
        parts = dep.split(":")
        if len(parts) == 2:
            idf_deps_yml += '  {}: "{}"\n'.format(parts[0], parts[1])
        else:
            idf_deps_yml += '  {}: "*"\n'.format(dep)
    
    # Board types for generated build.zig (from boards attribute)
    boards_list = ctx.attr.boards if ctx.attr.boards else ["esp32s3_devkit"]
    boards_enum_fields = ", ".join(boards_list)
    default_board = boards_list[0]
    
    # Extra lib dependencies for build.zig.zon
    extra_deps_zon = ""
    extra_deps_zig_imports = ""
    extra_deps_zig_decls = ""
    for dep in ctx.attr.extra_deps:
        dep_name = dep.lstrip(".")
        extra_deps_zon += '        .{name} = .{{ .path = "../../{lib_prefix}/{name}" }},\n'.format(name = dep_name, lib_prefix = lib_prefix)
        extra_deps_zig_imports += '    root_module.addImport("{name}", {name}_dep.module("{name}"));\n'.format(name = dep_name)
        extra_deps_zig_decls += '''    const {name}_dep = b.dependency("{name}", .{{
        .target = target,
        .optimize = optimize,
    }});
'''.format(name = dep_name)
    
    # Create wrapper script
    build_script = ctx.actions.declare_file("{}_build.sh".format(ctx.label.name))
    
    script_content = """#!/bin/bash
set -e
export ESP_BAZEL_RUN=1 ESP_BOARD="{board}"
export ESP_PROJECT_NAME="{project_name}" ESP_BIN_OUT="{bin_out}" ESP_ELF_OUT="{elf_out}"
export ZIG_INSTALL="$(pwd)/{zig_dir}" ESP_EXECROOT="$(pwd)"
export ESP_GENERATE_SHELL=1
export ESP_APP_NAME="{app_name}"
export ESP_APP_PATH="{app_path}"
{env_file_export}

# Load app config if provided (for run_in_psram)
{app_config_source}

WORK=$(mktemp -d) && export ESP_WORK_DIR="$WORK" && trap "rm -rf $WORK" EXIT

# Copy files preserving structure
{app_copy_commands}
{cmake_copy_commands}
{lib_copy_commands}

# Generate app build.zig.zon with correct relative paths to lib (without fingerprint first)
cat > "$WORK/{app_path}/build.zig.zon" << 'APPZONEOF'
.{{
    .name = .{app_name}_app,
    .version = "0.1.0",
    .dependencies = .{{
        .esp = .{{
            .path = "{app_to_lib_prefix}/esp",
        }},
        .hal = .{{
            .path = "{app_to_lib_prefix}/hal",
        }},
        .drivers = .{{
            .path = "{app_to_lib_prefix}/drivers",
        }},
    }},
    .paths = .{{
        "build.zig",
        "build.zig.zon",
        "app.zig",
        "platform.zig",
        "boards",
    }},
}}
APPZONEOF

# Calculate fingerprint for app build.zig.zon
cd "$WORK/{app_path}"
APP_ZIG_OUTPUT=$(HOME="$WORK" "$ZIG_INSTALL/zig" build --fetch --cache-dir "$WORK/.zig-cache" --global-cache-dir "$WORK/.zig-global-cache" 2>&1 || true)
APP_FINGERPRINT=$(echo "$APP_ZIG_OUTPUT" | grep -o "suggested value: 0x[0-9a-f]*" | grep -o "0x[0-9a-f]*" || echo "")
cd - > /dev/null

if [ -n "$APP_FINGERPRINT" ]; then
    awk -v fp="$APP_FINGERPRINT" '
        /\\.version = "0\\.1\\.0",/ {{
            print
            print "    .fingerprint = " fp ","
            next
        }}
        {{ print }}
    ' "$WORK/{app_path}/build.zig.zon" > "$WORK/{app_path}/build.zig.zon.new"
    mv "$WORK/{app_path}/build.zig.zon.new" "$WORK/{app_path}/build.zig.zon"
fi

# Generate ESP shell project
export ESP_PROJECT_PATH="esp_project"
mkdir -p "$WORK/$ESP_PROJECT_PATH/main/src"

# Generate top-level CMakeLists.txt
cat > "$WORK/$ESP_PROJECT_PATH/CMakeLists.txt" << 'CMAKEOF'
cmake_minimum_required(VERSION 3.16)
include(${{CMAKE_CURRENT_SOURCE_DIR}}/../{cmake_prefix}/zig_install.cmake)
include($ENV{{IDF_PATH}}/tools/cmake/project.cmake)
project({project_name})
CMAKEOF

# Generate main/CMakeLists.txt
cat > "$WORK/$ESP_PROJECT_PATH/main/CMakeLists.txt" << 'MAINCMAKEOF'
# Auto-generated ESP-IDF component CMakeLists.txt

# Set _ESP_LIB to the lib directory in the work tree
get_filename_component(_ESP_LIB "${{CMAKE_CURRENT_SOURCE_DIR}}/../../{lib_prefix}" ABSOLUTE)

{extra_cmake}

if(NOT DEFINED ZIG_BOARD)
    set(ZIG_BOARD "esp32s3_devkit")
endif()
message(STATUS "[{app_name}] Board: ${{ZIG_BOARD}}")

idf_component_register(
    SRCS "src/main.c" {extra_c_sources}
    INCLUDE_DIRS "."
    REQUIRES {requires}
)

esp_zig_build(
    FORCE_LINK
        {force_link}
)
MAINCMAKEOF

# Generate main/build.zig
cat > "$WORK/$ESP_PROJECT_PATH/main/build.zig" << 'BUILDZIGEOF'
const std = @import("std");
const esp = @import("esp");

pub fn build(b: *std.Build) void {{
    const target = b.standardTargetOptions(.{{}});
    const optimize = b.standardOptimizeOption(.{{}});
    
    // Board selection - passed from CMake via -Dboard=<board_name>
    const board = b.option([]const u8, "board", "Target board") orelse "{default_board}";

    // Convert board string to enum for app dependency
    const BoardType = enum {{ {boards_enum_fields} }};
    const board_enum = std.meta.stringToEnum(BoardType, board) orelse .{default_board};
    
    const app_dep = b.dependency("app", .{{
        .target = target,
        .optimize = optimize,
        .board = board_enum,
    }});

    const esp_dep = b.dependency("esp", .{{
        .target = target,
        .optimize = optimize,
    }});

{extra_deps_zig_decls}
    const root_module = b.createModule(.{{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }});
    root_module.addImport("esp", esp_dep.module("esp"));
    root_module.addImport("app", app_dep.module("app"));
{extra_deps_zig_imports}

    const lib = b.addLibrary(.{{
        .name = "main_zig",
        .linkage = .static,
        .root_module = root_module,
    }});

    esp.addEspDeps(b, root_module) catch {{
        @panic("Failed to add ESP dependencies");
    }};

    root_module.addIncludePath(b.path("include"));
    b.installArtifact(lib);
}}
BUILDZIGEOF

# Generate main/build.zig.zon (without fingerprint first)
cat > "$WORK/$ESP_PROJECT_PATH/main/build.zig.zon" << 'ZONEOF'
.{{
    .name = .{app_name},
    .version = "0.1.0",
    .dependencies = .{{
        .esp = .{{ .path = "../../{lib_prefix}/esp" }},
        .app = .{{ .path = "../../{app_path}" }},
{extra_deps_zon}    }},
    .paths = .{{
        "build.zig",
        "build.zig.zon",
        "src",
    }},
}}
ZONEOF

# Calculate fingerprint by running zig build --fetch to get suggested value
# Note: --fetch works without a valid build, just needs build.zig.zon to exist
# Use --cache-dir to avoid "AppDataDirUnavailable" error in Bazel sandbox where $HOME may not be set
# Calculate fingerprint by running zig build --fetch
# Set HOME and cache dirs for Bazel sandbox compatibility
cd "$WORK/$ESP_PROJECT_PATH/main"
ZIG_OUTPUT=$(HOME="$WORK" "$ZIG_INSTALL/zig" build --fetch --cache-dir "$WORK/.zig-cache" --global-cache-dir "$WORK/.zig-global-cache" 2>&1 || true)
FINGERPRINT=$(echo "$ZIG_OUTPUT" | grep -o "suggested value: 0x[0-9a-f]*" | grep -o "0x[0-9a-f]*" || echo "")
cd - > /dev/null

if [ -n "$FINGERPRINT" ]; then
    # Insert fingerprint using awk
    awk -v fp="$FINGERPRINT" '
        /\\.version = "0\\.1\\.0",/ {{
            print
            print "    .fingerprint = " fp ","
            next
        }}
        {{ print }}
    ' "$WORK/$ESP_PROJECT_PATH/main/build.zig.zon" > "$WORK/$ESP_PROJECT_PATH/main/build.zig.zon.new"
    mv "$WORK/$ESP_PROJECT_PATH/main/build.zig.zon.new" "$WORK/$ESP_PROJECT_PATH/main/build.zig.zon"
fi

# Generate main/src/main.c
cat > "$WORK/$ESP_PROJECT_PATH/main/src/main.c" << 'MAINCEOF'
// Entry point - calls Zig's app_main
extern void app_main(void);
MAINCEOF

# Generate main/src/env.zig - dynamic env from env file
# Parse env file and generate Zig struct
ENV_STRUCT_FIELDS=""
ENV_STRUCT_VALUES=""

if [ -n "$ESP_ENV_FILE" ] && [ -f "$ESP_ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and empty lines
        case "$line" in
            '#'*|"") continue ;;
        esac
        # Parse KEY=VALUE or KEY="VALUE" or export KEY=VALUE
        line="${{line#export }}"  # Remove export prefix if present
        key="${{line%%=*}}"
        value="${{line#*=}}"
        # Remove quotes from value
        value="${{value#'"'}}"
        value="${{value%'"'}}"
        # Convert to lowercase for Zig field name
        field=$(echo "$key" | tr '[:upper:]' '[:lower:]')
        # Add to struct fields and values
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

# Generate env.zig
cat > "$WORK/$ESP_PROJECT_PATH/main/src/env.zig" << ENVZIGEOF
//! Application Environment (generated from env file)

pub const Env = struct {{
$ENV_STRUCT_FIELDS
}};

pub const env: Env = .{{
$ENV_STRUCT_VALUES
}};
ENVZIGEOF

# Generate main/src/main.zig - unified entry point
# Check if RUN_APP_IN_PSRAM is set (from app_config)
if [ "$RUN_APP_IN_PSRAM" = "y" ]; then
    # PSRAM task version - larger stack in PSRAM
    cat > "$WORK/$ESP_PROJECT_PATH/main/src/main.zig" << 'MAINZIGEOF'
//! ESP Platform Entry Point (PSRAM Task Mode)

const std = @import("std");
const esp = @import("esp");
const app = @import("app");
pub const env_module = @import("env.zig");

const c = @cImport({{
    @cInclude("sdkconfig.h");
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
    @cInclude("esp_heap_caps.h");
}});

/// Log level from sdkconfig (CONFIG_LOG_DEFAULT_LEVEL)
const log_level: std.log.Level = if (c.CONFIG_LOG_DEFAULT_LEVEL >= 4)
    .debug
else if (c.CONFIG_LOG_DEFAULT_LEVEL >= 3)
    .info
else if (c.CONFIG_LOG_DEFAULT_LEVEL >= 2)
    .warn
else
    .err;

pub const std_options = std.Options{{
    .log_level = log_level,
    .logFn = esp.idf.log.stdLogFn,
}};

/// PSRAM task stack size (32KB, can be larger since it's in PSRAM)
const PSRAM_TASK_STACK_SIZE = 32 * 1024;
const PSRAM_TASK_STACK_WORDS = PSRAM_TASK_STACK_SIZE / @sizeOf(c.StackType_t);

/// Static task control block (in internal RAM for performance)
var task_tcb: c.StaticTask_t = undefined;

/// Stack buffer allocated in PSRAM
var psram_stack: ?[*]c.StackType_t = null;

fn appTaskFn(_: ?*anyopaque) callconv(.c) void {{
    app.run(env_module.env);
    // Task should not return, but if it does, loop forever
    while (true) {{
        c.vTaskDelay(c.portMAX_DELAY);
    }}
}}

export fn app_main() void {{
    std.log.info("Starting app in PSRAM task (stack: {{d}}KB)", .{{PSRAM_TASK_STACK_SIZE / 1024}});
    
    // Allocate stack in PSRAM
    psram_stack = @ptrCast(@alignCast(c.heap_caps_malloc(
        PSRAM_TASK_STACK_SIZE,
        c.MALLOC_CAP_SPIRAM,
    )));
    
    if (psram_stack == null) {{
        std.log.err("Failed to allocate PSRAM stack!", .{{}});
        // Fallback to direct call
        app.run(env_module.env);
        return;
    }}
    
    std.log.info("PSRAM stack allocated at {{*}}", .{{psram_stack}});
    
    // Create task with static allocation
    const task_handle = c.xTaskCreateStatic(
        appTaskFn,              // Task function
        "app",                  // Task name
        PSRAM_TASK_STACK_WORDS, // Stack size in words
        null,                   // Parameters
        5,                      // Priority
        psram_stack.?,          // Stack buffer (in PSRAM)
        &task_tcb,              // Task control block
    );
    
    if (task_handle == null) {{
        std.log.err("Failed to create PSRAM task!", .{{}});
        c.heap_caps_free(psram_stack);
        // Fallback to direct call
        app.run(env_module.env);
        return;
    }}
    
    std.log.info("PSRAM task created successfully", .{{}});
    // app_main returns, the app task continues running
}}
MAINZIGEOF
else
    # Direct call version - runs in main task
    cat > "$WORK/$ESP_PROJECT_PATH/main/src/main.zig" << 'MAINZIGEOF'
//! ESP Platform Entry Point

const std = @import("std");
const esp = @import("esp");
const app = @import("app");
pub const env_module = @import("env.zig");

const c = @cImport({{
    @cInclude("sdkconfig.h");
}});

/// Log level from sdkconfig (CONFIG_LOG_DEFAULT_LEVEL)
const log_level: std.log.Level = if (c.CONFIG_LOG_DEFAULT_LEVEL >= 4)
    .debug
else if (c.CONFIG_LOG_DEFAULT_LEVEL >= 3)
    .info
else if (c.CONFIG_LOG_DEFAULT_LEVEL >= 2)
    .warn
else
    .err;

pub const std_options = std.Options{{
    .log_level = log_level,
    .logFn = esp.idf.log.stdLogFn,
}};

export fn app_main() void {{
    app.run(env_module.env);
}}
MAINZIGEOF
fi

# Generate sdkconfig.defaults
cat > "$WORK/$ESP_PROJECT_PATH/sdkconfig.defaults" << SDKCONFIGEOF
# Auto-generated sdkconfig defaults
CONFIG_ESPTOOLPY_FLASHSIZE_4MB=y
CONFIG_PARTITION_TABLE_SINGLE_APP_LARGE=y
SDKCONFIGEOF

# Append user-provided sdkconfig if exists
{sdkconfig_append}

# Generate idf_component.yml if there are IDF component manager dependencies
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
        zig_dir = zig_bin.dirname if zig_bin else "",
        build_sh = build_sh.path if build_sh else "",
        app_name = app_name,
        app_path = app_path,
        app_copy_commands = "\n".join(app_copy_commands),
        cmake_copy_commands = "\n".join(cmake_copy_commands),
        lib_copy_commands = "\n".join(lib_copy_commands),
        lib_prefix = lib_prefix,
        cmake_prefix = cmake_prefix,
        app_to_lib_prefix = app_to_lib_prefix,
        requires = requires,
        force_link = force_link,
        extra_cmake = extra_cmake,
        extra_c_sources = extra_c_sources,
        extra_deps_zon = extra_deps_zon,
        extra_deps_zig_imports = extra_deps_zig_imports,
        extra_deps_zig_decls = extra_deps_zig_decls,
        idf_deps_yml = idf_deps_yml,
        sdkconfig_append = 'cat "{}" >> "$WORK/$ESP_PROJECT_PATH/sdkconfig.defaults"'.format(sdkconfig_file.path) if sdkconfig_file else "",
        boards_enum_fields = boards_enum_fields,
        default_board = default_board,
    )
    
    ctx.actions.write(
        output = build_script,
        content = script_content,
        is_executable = True,
    )
    
    # Collect all inputs
    env_files = [env_file] if env_file else []
    app_cfg_files = [app_config_file] if app_config_file else []
    inputs = app_files + cmake_files + zig_files + lib_files + script_files + sdkconfig_files + env_files + app_cfg_files + [build_script]
    
    # Run build
    ctx.actions.run_shell(
        command = build_script.path,
        inputs = inputs,
        outputs = [bin_file, elf_file],
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
            files = depset([bin_file, elf_file]),
            runfiles = ctx.runfiles(files = [bin_file, elf_file]),
        ),
        OutputGroupInfo(
            bin = depset([bin_file]),
            elf = depset([elf_file]),
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
        "extra_deps": attr.string_list(
            default = [],
            doc = "Extra lib dependencies (e.g., hal, drivers)",
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
            default = "//bazel/esp:board",
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
    
    # Get the binary to flash
    app_files = ctx.attr.app.files.to_list()
    bin_file = None
    for f in app_files:
        if f.path.endswith(".bin"):
            bin_file = f
            break
    
    if not bin_file:
        fail("No .bin file found in app target")
    
    # Get configuration
    board = ctx.attr._board[BuildSettingInfo].value if ctx.attr._board and BuildSettingInfo in ctx.attr._board else DEFAULT_BOARD
    port = ctx.attr._port[BuildSettingInfo].value if ctx.attr._port and BuildSettingInfo in ctx.attr._port else ""
    baud = ctx.attr._baud[BuildSettingInfo].value if ctx.attr._baud and BuildSettingInfo in ctx.attr._baud else "460800"
    
    # Get script files
    script_files = ctx.attr._scripts.files.to_list()
    
    # Create wrapper script
    flash_script = ctx.actions.declare_file("{}_flash.sh".format(ctx.label.name))
    
    script_content = """#!/bin/bash
set -e

# Mark as Bazel-invoked
export ESP_BAZEL_RUN=1

# Configuration
export ESP_BOARD="{board}"
export ESP_BAUD="{baud}"
export ESP_BIN="{bin_path}"
export ESP_PORT_CONFIG="{port}"

# Source common functions
source "{common_sh}"

# Run flash
setup_home
find_idf_python

if ! detect_serial_port "$ESP_PORT_CONFIG" "esp_flash"; then
    exit 1
fi

echo "[esp_flash] Board: $ESP_BOARD"
echo "[esp_flash] Flashing to $PORT at $ESP_BAUD baud..."
echo "[esp_flash] Binary: $ESP_BIN"

# esptool auto-detects chip type
"$IDF_PYTHON" -m esptool --port "$PORT" --baud "$ESP_BAUD" \\
    --before default_reset --after hard_reset \\
    write_flash -z 0x10000 "$ESP_BIN"

echo "[esp_flash] Flash complete!"
""".format(
        board = board,
        baud = baud,
        port = port,
        bin_path = bin_file.short_path,
        common_sh = [f for f in script_files if f.basename == "common.sh"][0].path,
    )
    
    ctx.actions.write(
        output = flash_script,
        content = script_content,
        is_executable = True,
    )
    
    return [
        DefaultInfo(
            executable = flash_script,
            runfiles = ctx.runfiles(files = [bin_file] + script_files),
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
        "_board": attr.label(
            default = "//bazel/esp:board",
        ),
        "_port": attr.label(
            default = "//bazel/esp:port",
        ),
        "_baud": attr.label(
            default = "//bazel/esp:baud",
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

echo "[esp_monitor] Board: $ESP_BOARD"
echo "[esp_monitor] Monitoring $PORT at $ESP_MONITOR_BAUD baud..."
echo "[esp_monitor] Press Ctrl+C to exit"

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
    print('\\nMonitor stopped.')
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
            default = "//bazel/esp:board",
        ),
        "_port": attr.label(
            default = "//bazel/esp:port",
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
""",
)
