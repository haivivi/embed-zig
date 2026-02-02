"""Zig build rules for Bazel.

Usage:
    load("//bazel/zig:defs.bzl", "zig_run")

    zig_run(
        name = "run",
        srcs = glob(["**/*"]),
        project_dir = "lib/myproject",
    )

Run:
    bazel run //path/to/project:run
"""

def _zig_run_impl(ctx):
    """Run a standalone Zig project.
    
    This rule copies source files maintaining the workspace directory structure,
    which is required for Zig's relative path dependencies (../trait, ../tls, etc.)
    """
    
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
    
    # Generate copy commands - preserve full workspace path structure
    src_copy_commands = []
    for f in src_files:
        rel_path = f.short_path
        src_copy_commands.append('mkdir -p "$WORK/$(dirname {})" && cp "{}" "$WORK/{}"'.format(
            rel_path, f.path, rel_path
        ))
    
    # Determine working directory
    work_dir = ctx.attr.project_dir if ctx.attr.project_dir else "."
    
    # Determine build step
    build_step = ctx.attr.build_step if ctx.attr.build_step else "run"
    
    script_content = """#!/bin/bash
set -e

WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

# Copy source files (preserving directory structure for relative imports)
{src_copy_commands}

# Set up Zig path
export PATH="{zig_dir}:$PATH"

# Run zig build from project directory
cd "$WORK/{work_dir}"
echo "[zig_run] Building and running in {work_dir}..."
zig build {build_step}
""".format(
        zig_dir = zig_bin.dirname if zig_bin else "",
        src_copy_commands = "\n".join(src_copy_commands),
        work_dir = work_dir,
        build_step = build_step,
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
            doc = "Project directory to run zig build from (e.g., 'lib/dns')",
        ),
        "build_step": attr.string(
            default = "run",
            doc = "Zig build step to run (default: 'run')",
        ),
        "_zig_toolchain": attr.label(
            default = "@zig_toolchain//:zig_files",
            doc = "Zig compiler",
        ),
    },
    doc = "Run a standalone Zig project",
)
