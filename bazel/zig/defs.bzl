"""Zig build rules for Bazel.

Usage:
    load("//bazel/zig:defs.bzl", "zig_run")

    zig_run(
        name = "run",
        srcs = glob(["**/*"]),
    )

Run:
    bazel run //path/to/project:run
"""

def _zig_run_impl(ctx):
    """Run a standalone Zig project."""
    
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
    
    # Create run script
    run_script = ctx.actions.declare_file("{}_run.sh".format(ctx.label.name))
    
    # Generate copy commands
    src_copy_commands = []
    for f in src_files:
        rel_path = f.short_path
        if ctx.attr.project_dir and rel_path.startswith(ctx.attr.project_dir + "/"):
            rel_path = rel_path[len(ctx.attr.project_dir) + 1:]
        src_copy_commands.append('mkdir -p "$WORK/$(dirname {})" && cp "{}" "$WORK/{}"'.format(
            rel_path, f.path, rel_path
        ))
    
    script_content = """#!/bin/bash
set -e

WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

# Copy source files
{src_copy_commands}

# Set up Zig path
export PATH="{zig_dir}:$PATH"

# Run zig build
cd "$WORK"
echo "[zig_run] Building and running..."
zig build run
""".format(
        zig_dir = zig_bin.dirname if zig_bin else "",
        src_copy_commands = "\n".join(src_copy_commands),
    )
    
    ctx.actions.write(
        output = run_script,
        content = script_content,
        is_executable = True,
    )
    
    return [
        DefaultInfo(
            executable = run_script,
            runfiles = ctx.runfiles(files = src_files + zig_files),
        ),
    ]

zig_run = rule(
    implementation = _zig_run_impl,
    executable = True,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Source files for the Zig project",
        ),
        "project_dir": attr.string(
            doc = "Project directory path to strip from source paths",
        ),
        "_zig_toolchain": attr.label(
            default = "@zig_toolchain//:zig_files",
            doc = "Zig compiler",
        ),
    },
    doc = "Run a standalone Zig project",
)
