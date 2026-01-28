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
    bazel build //examples/esp/led_strip_flash/zig:app
    
    # Specify board
    bazel build //examples/esp/led_strip_flash/zig:app --//bazel/esp:board=korvo2_v3
    
    # Flash (auto-detect port)
    bazel run //examples/esp/led_strip_flash/zig:flash
    
    # Flash to specific port
    bazel run //examples/esp/led_strip_flash/zig:flash --//bazel/esp:port=/dev/ttyUSB0
    
    # Monitor
    bazel run //examples/esp/led_strip_flash/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//bazel/esp:settings.bzl", "DEFAULT_BOARD", "DEFAULT_CHIP", "DEFAULT_WIFI_SSID", "DEFAULT_WIFI_PASSWORD", "DEFAULT_TEST_SERVER_IP")

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
    chip = ctx.attr._chip[BuildSettingInfo].value if ctx.attr._chip and BuildSettingInfo in ctx.attr._chip else DEFAULT_CHIP
    wifi_ssid = ctx.attr._wifi_ssid[BuildSettingInfo].value if ctx.attr._wifi_ssid and BuildSettingInfo in ctx.attr._wifi_ssid else DEFAULT_WIFI_SSID
    wifi_password = ctx.attr._wifi_password[BuildSettingInfo].value if ctx.attr._wifi_password and BuildSettingInfo in ctx.attr._wifi_password else DEFAULT_WIFI_PASSWORD
    test_server_ip = ctx.attr._test_server_ip[BuildSettingInfo].value if ctx.attr._test_server_ip and BuildSettingInfo in ctx.attr._test_server_ip else DEFAULT_TEST_SERVER_IP
    
    # Get script files
    script_files = ctx.attr._scripts.files.to_list()
    build_sh = None
    for f in script_files:
        if f.basename == "build.sh":
            build_sh = f
            break
    
    # Generate copy commands
    src_copy_commands = _generate_copy_commands(src_files, ctx.label.package, "project")
    cmake_copy_commands = _generate_cmake_copy_commands(cmake_files)
    lib_copy_commands = _generate_lib_copy_commands(lib_files)
    apps_copy_commands = _generate_apps_copy_commands(apps_files)
    
    # Create wrapper script that copies files and calls build.sh
    build_script = ctx.actions.declare_file("{}_build.sh".format(ctx.label.name))
    
    # Wrapper script: sets up environment, copies files, calls build.sh
    # Only dynamic content (file copy commands) stays here
    script_content = """#!/bin/bash
set -e
export ESP_BAZEL_RUN=1 ESP_BOARD="{board}" ESP_CHIP="{chip}"
export ESP_PROJECT_NAME="{project_name}" ESP_BIN_OUT="{bin_out}" ESP_ELF_OUT="{elf_out}"
export ESP_WIFI_SSID="{wifi_ssid}" ESP_WIFI_PASSWORD="{wifi_password}" ESP_TEST_SERVER_IP="{test_server_ip}"
export ZIG_INSTALL="$(pwd)/{zig_dir}" ESP_EXECROOT="$(pwd)"
WORK=$(mktemp -d) && export ESP_WORK_DIR="$WORK" && trap "rm -rf $WORK" EXIT
mkdir -p "$WORK/project" "$WORK/cmake" "$WORK/lib" "$WORK/apps"
{src_copy_commands}
{cmake_copy_commands}
{lib_copy_commands}
{apps_copy_commands}
exec bash "{build_sh}"
""".format(
        board = board,
        chip = chip,
        wifi_ssid = wifi_ssid,
        wifi_password = wifi_password,
        test_server_ip = test_server_ip,
        project_name = project_name,
        bin_out = bin_file.path,
        elf_out = elf_file.path,
        zig_dir = zig_bin.dirname if zig_bin else "",
        build_sh = build_sh.path if build_sh else "",
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

# Helper functions for generating copy commands
def _generate_copy_commands(files, package, dest):
    commands = []
    for f in files:
        rel_path = f.short_path
        if rel_path.startswith(package + "/"):
            rel_path = rel_path[len(package) + 1:]
        commands.append('mkdir -p "$WORK/{}/$(dirname {})" && cp "{}" "$WORK/{}/{}"'.format(
            dest, rel_path, f.path, dest, rel_path
        ))
    return commands

def _generate_cmake_copy_commands(files):
    commands = []
    for f in files:
        rel_path = f.basename
        if "/cmake/" in f.short_path:
            rel_path = f.short_path.split("/cmake/", 1)[1]
        commands.append('mkdir -p "$WORK/cmake/$(dirname {})" && cp "{}" "$WORK/cmake/{}"'.format(
            rel_path, f.path, rel_path
        ))
    return commands

def _generate_lib_copy_commands(files):
    commands = []
    for f in files:
        rel_path = f.short_path
        if rel_path.startswith("lib/"):
            rel_path = rel_path[4:]
        elif "/lib/" in rel_path:
            rel_path = rel_path.split("/lib/", 1)[1]
        commands.append('mkdir -p "$WORK/lib/$(dirname {})" && cp "{}" "$WORK/lib/{}"'.format(
            rel_path, f.path, rel_path
        ))
    return commands

def _generate_apps_copy_commands(files):
    commands = []
    for f in files:
        rel_path = f.short_path
        if rel_path.startswith("examples/apps/"):
            rel_path = rel_path[14:]
        elif "/apps/" in rel_path:
            rel_path = rel_path.split("/apps/", 1)[1]
        commands.append('mkdir -p "$WORK/apps/$(dirname {})" && cp "{}" "$WORK/apps/{}"'.format(
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
            default = ["//cmake:cmake_modules"],
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
            default = "//:all_libs",
            doc = "Library files from embed-zig",
        ),
        "_apps": attr.label(
            default = "//examples/apps:all_apps",
            doc = "App files from embed-zig examples",
        ),
        "_board": attr.label(
            default = "//bazel/esp:board",
        ),
        "_chip": attr.label(
            default = "//bazel/esp:chip",
        ),
        "_wifi_ssid": attr.label(
            default = "//bazel/esp:wifi_ssid",
        ),
        "_wifi_password": attr.label(
            default = "//bazel/esp:wifi_password",
        ),
        "_test_server_ip": attr.label(
            default = "//bazel/esp:test_server_ip",
        ),
        "_scripts": attr.label(
            default = "//bazel/esp:scripts",
            doc = "Build scripts",
        ),
    },
    doc = "Build an ESP-IDF project with Zig support",
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
    chip = ctx.attr._chip[BuildSettingInfo].value if ctx.attr._chip and BuildSettingInfo in ctx.attr._chip else DEFAULT_CHIP
    
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
export ESP_CHIP="{chip}"
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

echo "[esp_flash] Board: $ESP_BOARD, Chip: $ESP_CHIP"
echo "[esp_flash] Flashing to $PORT at $ESP_BAUD baud..."
echo "[esp_flash] Binary: $ESP_BIN"

"$IDF_PYTHON" -m esptool --chip "$ESP_CHIP" --port "$PORT" --baud "$ESP_BAUD" \\
    --before default_reset --after hard_reset \\
    write_flash -z 0x10000 "$ESP_BIN"

echo "[esp_flash] Flash complete!"
""".format(
        board = board,
        chip = chip,
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
        "_chip": attr.label(
            default = "//bazel/esp:chip",
        ),
        "_port": attr.label(
            default = "//bazel/esp:port",
        ),
        "_baud": attr.label(
            default = "//bazel/esp:baud",
        ),
        "_scripts": attr.label(
            default = "//bazel/esp:scripts",
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
            default = "//bazel/esp:scripts",
        ),
    },
    doc = "Monitor serial output from an ESP32 device",
)
