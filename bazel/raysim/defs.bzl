"""Raylib simulator build rules for Bazel.

Usage:
    load("//bazel/raysim:defs.bzl", "raysim_run")

    raysim_run(
        name = "run",
        project_dir = "examples/raysim/gpio_button",
    )

Run:
    bazel run //examples/raysim/gpio_button:run
"""

def _raysim_run_impl(ctx):
    """Run a Raylib simulator project."""
    
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
    
    # Generate copy commands for source files
    src_copy_commands = []
    for f in src_files:
        rel_path = f.short_path
        if rel_path.startswith(ctx.attr.project_dir + "/"):
            rel_path = rel_path[len(ctx.attr.project_dir) + 1:]
        src_copy_commands.append('mkdir -p "$WORK/project/$(dirname {})" && cp "{}" "$WORK/project/{}"'.format(
            rel_path, f.path, rel_path
        ))
    
    # Generate copy commands for lib files
    lib_copy_commands = []
    for f in lib_files:
        rel_path = f.short_path
        if rel_path.startswith("lib/"):
            rel_path = rel_path[4:]
        elif "/lib/" in rel_path:
            rel_path = rel_path.split("/lib/", 1)[1]
        lib_copy_commands.append('mkdir -p "$WORK/lib/$(dirname {})" && cp "{}" "$WORK/lib/{}"'.format(
            rel_path, f.path, rel_path
        ))
    
    # Generate copy commands for apps files
    apps_copy_commands = []
    for f in apps_files:
        rel_path = f.short_path
        if rel_path.startswith("examples/apps/"):
            rel_path = rel_path[14:]
        elif "/apps/" in rel_path:
            rel_path = rel_path.split("/apps/", 1)[1]
        apps_copy_commands.append('mkdir -p "$WORK/apps/$(dirname {})" && cp "{}" "$WORK/apps/{}"'.format(
            rel_path, f.path, rel_path
        ))
    
    script_content = """#!/bin/bash
set -e

WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

mkdir -p "$WORK/project" "$WORK/lib" "$WORK/apps"

# Copy source files
{src_copy_commands}

# Copy lib files
{lib_copy_commands}

# Copy apps files
{apps_copy_commands}

# Set up Zig path
export PATH="{zig_dir}:$PATH"

# Run zig build
cd "$WORK/project"

# Update build.zig.zon paths to use local copies
if [ -f build.zig.zon ]; then
    # Create symlinks for dependencies
    mkdir -p "$WORK/project/../lib"
    ln -sf "$WORK/lib" "$WORK/project/../lib" 2>/dev/null || true
fi

echo "[raysim] Running simulator..."
zig build run
""".format(
        zig_dir = zig_bin.dirname if zig_bin else "",
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

raysim_run = rule(
    implementation = _raysim_run_impl,
    executable = True,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Source files for the simulator project",
        ),
        "project_dir": attr.string(
            mandatory = True,
            doc = "Project directory path (e.g., examples/raysim/gpio_button)",
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
    doc = "Run a Raylib simulator project",
)
