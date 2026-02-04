"""Zig build rules for Bazel.

Usage:
    load("//bazel/zig:defs.bzl", "zig_lib", "zig_run")

    # Define a Zig library
    zig_lib(
        name = "mylib",
        srcs = glob(["**/*"]),
        deps = ["//lib/trait"],
    )

    # Run a standalone Zig project
    zig_run(
        name = "run",
        srcs = glob(["**/*"]),
        project_dir = "lib/myproject",
    )

Run:
    bazel run //path/to/project:run
"""

# =============================================================================
# ZigLibInfo - Provider for Zig library information
# =============================================================================

ZigLibInfo = provider(
    doc = "Information about a Zig library for dependency resolution",
    fields = {
        "name": "Library name (used in build.zig.zon)",
        "srcs": "Depset of source files",
        "path": "Path to library root (package path, e.g., 'lib/hal')",
        "deps": "Depset of transitive ZigLibInfo dependencies",
    },
)

# =============================================================================
# zig_lib - Define a Zig library
# =============================================================================

def _zig_lib_impl(ctx):
    """Define a Zig library that can be used as a dependency."""
    
    # Collect source files
    src_files = []
    for src in ctx.attr.srcs:
        src_files.extend(src.files.to_list())
    
    # Determine library path from package
    lib_path = ctx.label.package  # e.g., "lib/hal"
    
    # Library name (from label name or explicit)
    lib_name = ctx.attr.lib_name if ctx.attr.lib_name else ctx.label.name
    
    # Collect transitive dependencies
    transitive_deps = []
    for dep in ctx.attr.deps:
        if ZigLibInfo in dep:
            transitive_deps.append(dep[ZigLibInfo])
    
    return [
        DefaultInfo(
            files = depset(src_files),
        ),
        ZigLibInfo(
            name = lib_name,
            srcs = depset(src_files),
            path = lib_path,
            deps = depset(transitive_deps),
        ),
    ]

zig_lib = rule(
    implementation = _zig_lib_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Source files for the Zig library",
        ),
        "lib_name": attr.string(
            doc = "Library name (defaults to target name). Used in build.zig.zon.",
        ),
        "deps": attr.label_list(
            providers = [ZigLibInfo],
            doc = "Other zig_lib dependencies",
        ),
    },
    doc = """Define a Zig library for use with esp_zig_app.

Example:
    zig_lib(
        name = "hal",
        srcs = glob(["**/*"]),
        deps = ["//lib/trait"],
    )
""",
)

# =============================================================================
# zig_run - Run a standalone Zig project
# =============================================================================

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
