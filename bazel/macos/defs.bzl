"""macOS build rules for Bazel.

Usage:
    load("//bazel/macos:defs.bzl", "macos_run")

    macos_run(
        name = "run",
        project_dir = "examples/apps/tls_speed_test/macos",
    )

Run:
    bazel run //examples/apps/tls_speed_test/macos:run
"""

def _generate_copy_commands_preserve_structure(files):
    """Generate copy commands that preserve the original directory structure."""
    commands = []
    for f in files:
        rel_path = f.short_path
        commands.append('mkdir -p "$WORK/$(dirname {})" && cp "{}" "$WORK/{}"'.format(
            rel_path, f.path, rel_path
        ))
    return commands

def _macos_run_impl(ctx):
    """Build and run a macOS project."""
    
    # Collect source files
    src_files = []
    for src in ctx.attr.srcs:
        src_files.extend(src.files.to_list())
    
    # Get Zig toolchain
    zig_files = ctx.attr._zig_toolchain.files.to_list()
    zig_bin = None
    for f in zig_files:
        if f.basename == "zig" and f.is_source:
            zig_bin = f
            break
    
    # Get lib files
    lib_files = ctx.attr._libs.files.to_list()
    apps_files = ctx.attr._apps.files.to_list() if ctx.attr._apps else []
    
    # Create run script
    run_script = ctx.actions.declare_file("{}_run.sh".format(ctx.label.name))
    
    # Generate copy commands preserving structure
    src_copy_commands = _generate_copy_commands_preserve_structure(src_files)
    lib_copy_commands = _generate_copy_commands_preserve_structure(lib_files)
    apps_copy_commands = _generate_copy_commands_preserve_structure(apps_files)
    
    script_content = """#!/bin/bash
set -e

WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

# Copy files preserving structure
{src_copy_commands}
{lib_copy_commands}
{apps_copy_commands}

# Set up Zig path
export PATH="{zig_dir}:$PATH"

# Run zig build run from the project directory
cd "$WORK/{project_dir}"

echo "[macos] Building and running..."
zig build run
""".format(
        zig_dir = zig_bin.dirname if zig_bin else "",
        project_dir = ctx.attr.project_dir,
        src_copy_commands = "\n".join(src_copy_commands),
        lib_copy_commands = "\n".join(lib_copy_commands),
        apps_copy_commands = "\n".join(apps_copy_commands),
    )
    
    ctx.actions.write(
        output = run_script,
        content = script_content,
        is_executable = True,
    )
    
    return [
        DefaultInfo(
            executable = run_script,
            runfiles = ctx.runfiles(files = src_files + zig_files + lib_files + apps_files),
        ),
    ]

macos_run = rule(
    implementation = _macos_run_impl,
    executable = True,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Source files for the macOS project",
        ),
        "project_dir": attr.string(
            mandatory = True,
            doc = "Project directory path (e.g., examples/apps/tls_speed_test/macos)",
        ),
        "_zig_toolchain": attr.label(
            default = "@zig_toolchain//:zig_files",
            doc = "Zig compiler",
        ),
        "_libs": attr.label(
            default = "//:all_libs",
            doc = "Library files",
        ),
        "_apps": attr.label(
            default = "//examples/apps:all_apps",
            doc = "App files",
        ),
    },
    doc = "Build and run a macOS project",
)
