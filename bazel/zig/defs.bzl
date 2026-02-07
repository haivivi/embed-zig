"""Zig build rules for Bazel.

Legacy rules (wrap zig build):
    load("//bazel/zig:defs.bzl", "zig_lib", "zig_run")

Bazel-native rules (invoke zig compiler directly):
    load("//bazel/zig:defs.bzl", "zig_library", "zig_binary", "zig_test", "zig_static_library")

    zig_library(
        name = "trait",
        main = "src/trait.zig",
        srcs = glob(["src/**/*.zig"]),
    )

    zig_library(
        name = "hal",
        main = "src/hal.zig",
        srcs = glob(["src/**/*.zig"]),
        deps = ["//lib/trait"],
    )

    zig_binary(
        name = "my_app",
        main = "src/main.zig",
        srcs = ["src/main.zig"],
        deps = [":hal"],
    )

    zig_test(
        name = "hal_test",
        main = "src/hal.zig",
        srcs = glob(["src/**/*.zig"]),
        deps = ["//lib/trait"],
    )

    zig_static_library(
        name = "hal_a",
        lib = ":hal",
    )
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

# #############################################################################
#
# Bazel-native Zig rules — invoke zig compiler directly, no build.zig
#
# #############################################################################

# =============================================================================
# ZigModuleInfo — Provider for Bazel-native Zig module metadata
# =============================================================================

# Struct-like record for a single module in the transitive graph.
# Stored as a plain struct (not a provider) inside ZigModuleInfo.transitive_modules.
# Fields:
#   name:           string — module name (for --dep / -M flags)
#   root_source:    File   — root .zig source file
#   dep_names:      list(string) — names of direct module dependencies

ZigModuleInfo = provider(
    doc = "Bazel-native Zig module information (no build.zig needed)",
    fields = {
        "module_name": "string — Module name used in @import() and -M flag",
        "root_source": "File — Root .zig source file (e.g., src/trait.zig)",
        "srcs": "depset(File) — Source files belonging to this module only",
        "transitive_srcs": "depset(File) — All source files across transitive deps",
        "direct_dep_names": "list(string) — Names of direct module dependencies",
        "transitive_modules": "list(struct) — Flattened, deduped list of all transitive module records (name, root_source, dep_names)",
    },
)

# =============================================================================
# Helpers
# =============================================================================

def _get_zig_bin(zig_toolchain_files):
    """Find the zig binary from toolchain files."""
    for f in zig_toolchain_files:
        if f.basename == "zig" and f.is_source:
            return f
    fail("Could not find zig binary in toolchain")

def _collect_transitive_modules(direct_deps):
    """Walk the dep graph and return a deduped list of module records.

    Each record is a struct(name, root_source, dep_names).
    Order: direct deps first, then their deps, etc. (BFS).
    Deduped by module_name — first occurrence wins.
    """
    seen = {}
    result = []
    queue = list(direct_deps)  # list of ZigModuleInfo
    for info in queue:
        if info.module_name in seen:
            continue
        seen[info.module_name] = True
        result.append(struct(
            name = info.module_name,
            root_source = info.root_source,
            dep_names = info.direct_dep_names,
        ))
        for sub in info.transitive_modules:
            if sub.name not in seen:
                seen[sub.name] = True
                result.append(sub)
        # Also enqueue direct deps' direct deps for BFS
        for dep in direct_deps:
            pass  # already handled via transitive_modules
    return result

def _build_module_args(main_name, main_root, direct_dep_names, transitive_modules):
    """Build the -M / --dep argument list for the zig compiler.

    Returns a list of strings, e.g.:
        ["--dep", "trait", "--dep", "motion", "-Mhal=lib/hal/src/hal.zig",
         "-Mtrait=lib/trait/src/trait.zig",
         "--dep", "math", "-Mmotion=lib/pkg/motion/src/motion.zig",
         "-Mmath=lib/pkg/math/src/math.zig"]

    Rules:
      1. Main module first: --dep X --dep Y -Mmain=root.zig
      2. Each dep module: --dep A --dep B -Mname=root.zig
      3. Each module name defined exactly once with -M
    """
    args = []

    # 1. Main module
    for dep_name in direct_dep_names:
        args.extend(["--dep", dep_name])
    args.append("-M{}={}".format(main_name, main_root.path))

    # 2. Dependency modules (already deduped, topological-ish via BFS)
    for mod in transitive_modules:
        for dep_name in mod.dep_names:
            args.extend(["--dep", dep_name])
        args.append("-M{}={}".format(mod.name, mod.root_source.path))

    return args

# =============================================================================
# zig_library — Metadata-only module definition (no compilation)
# =============================================================================

def _zig_library_impl(ctx):
    """Define a Zig module. No compilation — just metadata for downstream rules."""

    # Root source file
    root_source = ctx.file.main

    # Module name
    module_name = ctx.attr.module_name if ctx.attr.module_name else ctx.label.name

    # This module's source files
    own_srcs = depset(ctx.files.srcs)

    # Collect direct deps
    direct_deps = []
    direct_dep_names = []
    transitive_src_depsets = [own_srcs]

    for dep in ctx.attr.deps:
        info = dep[ZigModuleInfo]
        direct_deps.append(info)
        direct_dep_names.append(info.module_name)
        transitive_src_depsets.append(info.transitive_srcs)

    # Flatten transitive modules (deduped)
    transitive_modules = _collect_transitive_modules(direct_deps)

    return [
        DefaultInfo(files = own_srcs),
        ZigModuleInfo(
            module_name = module_name,
            root_source = root_source,
            srcs = own_srcs,
            transitive_srcs = depset(transitive = transitive_src_depsets),
            direct_dep_names = direct_dep_names,
            transitive_modules = transitive_modules,
        ),
    ]

zig_library = rule(
    implementation = _zig_library_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".zig"],
            mandatory = True,
            doc = "Zig source files for this module",
        ),
        "main": attr.label(
            allow_single_file = [".zig"],
            mandatory = True,
            doc = "Root source file (e.g., src/trait.zig)",
        ),
        "module_name": attr.string(
            doc = "Module name for @import(). Defaults to target name.",
        ),
        "deps": attr.label_list(
            providers = [ZigModuleInfo],
            doc = "zig_library dependencies",
        ),
    },
    doc = """Define a Zig module (metadata only, no compilation).

Downstream zig_binary / zig_test / zig_static_library rules consume this
to build -M / --dep flags for the zig compiler.

Example:
    zig_library(
        name = "trait",
        main = "src/trait.zig",
        srcs = glob(["src/**/*.zig"]),
    )
""",
)

# =============================================================================
# zig_static_library — Compile a zig_library to .a (for C interop)
# =============================================================================

def _zig_static_library_impl(ctx):
    """Compile a zig_library to a static library (.a) via zig build-lib."""

    info = ctx.attr.lib[ZigModuleInfo]
    zig_files = ctx.attr._zig_toolchain.files.to_list()
    zig_bin = _get_zig_bin(zig_files)

    # Output .a file
    output = ctx.actions.declare_file("lib{}.a".format(info.module_name))

    # Build -M / --dep args
    module_args = _build_module_args(
        main_name = info.module_name,
        main_root = info.root_source,
        direct_dep_names = info.direct_dep_names,
        transitive_modules = info.transitive_modules,
    )

    # Assemble full command
    cmd_parts = [
        '"{zig}"'.format(zig = zig_bin.path),
        "build-lib",
    ]
    cmd_parts.extend(['"{}"'.format(a) for a in module_args])
    cmd_parts.extend([
        "-femit-bin=" + output.path,
        "--cache-dir", '"$ZC"',
        "--global-cache-dir", '"$ZC"',
    ])

    # Extra compile options
    if ctx.attr.optimize:
        cmd_parts.extend(["-O", ctx.attr.optimize])
    if ctx.attr.target:
        cmd_parts.extend(["-target", ctx.attr.target])

    cmd = " ".join(cmd_parts)
    script = 'set -e && ZC=$(mktemp -d) && trap \'rm -rf "$ZC"\' EXIT && {cmd}'.format(cmd = cmd)

    # All transitive source files as inputs
    all_srcs = info.transitive_srcs.to_list()

    ctx.actions.run_shell(
        command = script,
        inputs = all_srcs + zig_files,
        outputs = [output],
        mnemonic = "ZigBuildLib",
        progress_message = "Compiling Zig static library %s" % ctx.label,
        use_default_shell_env = True,
    )

    return [
        DefaultInfo(files = depset([output])),
        # Also forward ZigModuleInfo so this can be used as a dep
        info,
    ]

zig_static_library = rule(
    implementation = _zig_static_library_impl,
    attrs = {
        "lib": attr.label(
            mandatory = True,
            providers = [ZigModuleInfo],
            doc = "zig_library target to compile",
        ),
        "optimize": attr.string(
            doc = "Optimization mode: Debug, ReleaseFast, ReleaseSafe, ReleaseSmall",
        ),
        "target": attr.string(
            doc = "Cross-compilation target (e.g., xtensa-esp32s3-none-elf)",
        ),
        "_zig_toolchain": attr.label(
            default = "@zig_toolchain//:zig_files",
        ),
    },
    doc = """Compile a zig_library into a static library (.a).

Useful for C interop — e.g., linking Zig code into an ESP-IDF CMake project.

Example:
    zig_static_library(
        name = "hal_a",
        lib = ":hal",
    )
""",
)

# =============================================================================
# zig_binary — Compile a Zig executable
# =============================================================================

def _zig_binary_impl(ctx):
    """Compile a Zig executable via zig build-exe."""

    root_source = ctx.file.main
    module_name = ctx.attr.module_name if ctx.attr.module_name else ctx.label.name
    zig_files = ctx.attr._zig_toolchain.files.to_list()
    zig_bin = _get_zig_bin(zig_files)

    # Output executable
    output = ctx.actions.declare_file(ctx.label.name)

    # Collect deps
    direct_dep_names = []
    transitive_src_depsets = [depset(ctx.files.srcs)]
    direct_deps = []

    for dep in ctx.attr.deps:
        info = dep[ZigModuleInfo]
        direct_deps.append(info)
        direct_dep_names.append(info.module_name)
        transitive_src_depsets.append(info.transitive_srcs)

    transitive_modules = _collect_transitive_modules(direct_deps)

    # Build -M / --dep args
    module_args = _build_module_args(
        main_name = module_name,
        main_root = root_source,
        direct_dep_names = direct_dep_names,
        transitive_modules = transitive_modules,
    )

    # Assemble command
    cmd_parts = [
        '"{zig}"'.format(zig = zig_bin.path),
        "build-exe",
    ]
    cmd_parts.extend(['"{}"'.format(a) for a in module_args])
    cmd_parts.extend([
        "-femit-bin=" + output.path,
        "--cache-dir", '"$ZC"',
        "--global-cache-dir", '"$ZC"',
    ])

    if ctx.attr.optimize:
        cmd_parts.extend(["-O", ctx.attr.optimize])
    if ctx.attr.target:
        cmd_parts.extend(["-target", ctx.attr.target])

    cmd = " ".join(cmd_parts)
    script = 'set -e && ZC=$(mktemp -d) && trap \'rm -rf "$ZC"\' EXIT && {cmd}'.format(cmd = cmd)

    all_srcs = depset(transitive = transitive_src_depsets).to_list()

    ctx.actions.run_shell(
        command = script,
        inputs = all_srcs + zig_files,
        outputs = [output],
        mnemonic = "ZigBuildExe",
        progress_message = "Compiling Zig binary %s" % ctx.label,
        use_default_shell_env = True,
    )

    return [DefaultInfo(
        files = depset([output]),
        executable = output,
    )]

zig_binary = rule(
    implementation = _zig_binary_impl,
    executable = True,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".zig"],
            mandatory = True,
            doc = "Zig source files for the main module",
        ),
        "main": attr.label(
            allow_single_file = [".zig"],
            mandatory = True,
            doc = "Root source file (entry point)",
        ),
        "module_name": attr.string(
            doc = "Main module name. Defaults to target name.",
        ),
        "deps": attr.label_list(
            providers = [ZigModuleInfo],
            doc = "zig_library dependencies",
        ),
        "optimize": attr.string(
            doc = "Optimization mode: Debug, ReleaseFast, ReleaseSafe, ReleaseSmall",
        ),
        "target": attr.string(
            doc = "Cross-compilation target",
        ),
        "_zig_toolchain": attr.label(
            default = "@zig_toolchain//:zig_files",
        ),
    },
    doc = """Compile a Zig executable.

Example:
    zig_binary(
        name = "my_app",
        main = "src/main.zig",
        srcs = ["src/main.zig", "src/config.zig"],
        deps = [":hal", "//lib/trait"],
    )
""",
)

# =============================================================================
# zig_test — Compile and run Zig tests
# =============================================================================

def _zig_test_impl(ctx):
    """Compile and run Zig tests via zig test."""

    root_source = ctx.file.main
    module_name = ctx.attr.module_name if ctx.attr.module_name else ctx.label.name
    zig_files = ctx.attr._zig_toolchain.files.to_list()
    zig_bin = _get_zig_bin(zig_files)

    # Output test binary
    test_bin = ctx.actions.declare_file(ctx.label.name + "_test_bin")

    # Collect deps
    direct_dep_names = []
    transitive_src_depsets = [depset(ctx.files.srcs)]
    direct_deps = []

    for dep in ctx.attr.deps:
        info = dep[ZigModuleInfo]
        direct_deps.append(info)
        direct_dep_names.append(info.module_name)
        transitive_src_depsets.append(info.transitive_srcs)

    transitive_modules = _collect_transitive_modules(direct_deps)

    # Build -M / --dep args
    module_args = _build_module_args(
        main_name = module_name,
        main_root = root_source,
        direct_dep_names = direct_dep_names,
        transitive_modules = transitive_modules,
    )

    # For zig test, we compile the test binary, then create a wrapper script
    # that runs it. This lets Bazel's test infrastructure handle the execution.
    cmd_parts = [
        '"{zig}"'.format(zig = zig_bin.path),
        "test",
    ]
    cmd_parts.extend(['"{}"'.format(a) for a in module_args])
    cmd_parts.extend([
        "--test-no-exec",
        "-femit-bin=" + test_bin.path,
        "--cache-dir", '"$ZC"',
        "--global-cache-dir", '"$ZC"',
    ])

    if ctx.attr.optimize:
        cmd_parts.extend(["-O", ctx.attr.optimize])
    if ctx.attr.target:
        cmd_parts.extend(["-target", ctx.attr.target])

    cmd = " ".join(cmd_parts)
    script = 'set -e && ZC=$(mktemp -d) && trap \'rm -rf "$ZC"\' EXIT && {cmd}'.format(cmd = cmd)

    all_srcs = depset(transitive = transitive_src_depsets).to_list()

    ctx.actions.run_shell(
        command = script,
        inputs = all_srcs + zig_files,
        outputs = [test_bin],
        mnemonic = "ZigTestCompile",
        progress_message = "Compiling Zig tests %s" % ctx.label,
        use_default_shell_env = True,
    )

    # Create a runner script that executes the compiled test binary
    runner = ctx.actions.declare_file(ctx.label.name + "_test_runner.sh")
    ctx.actions.write(
        output = runner,
        content = '#!/bin/bash\nexec "./{bin}" "$@"\n'.format(bin = test_bin.short_path),
        is_executable = True,
    )

    return [DefaultInfo(
        executable = runner,
        runfiles = ctx.runfiles(files = [test_bin]),
    )]

zig_test = rule(
    implementation = _zig_test_impl,
    test = True,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".zig"],
            mandatory = True,
            doc = "Zig source files",
        ),
        "main": attr.label(
            allow_single_file = [".zig"],
            mandatory = True,
            doc = "Root source file containing tests",
        ),
        "module_name": attr.string(
            doc = "Module name. Defaults to target name.",
        ),
        "deps": attr.label_list(
            providers = [ZigModuleInfo],
            doc = "zig_library dependencies",
        ),
        "optimize": attr.string(
            doc = "Optimization mode",
        ),
        "target": attr.string(
            doc = "Cross-compilation target",
        ),
        "_zig_toolchain": attr.label(
            default = "@zig_toolchain//:zig_files",
        ),
    },
    doc = """Compile and run Zig tests.

Example:
    zig_test(
        name = "trait_test",
        main = "src/trait.zig",
        srcs = glob(["src/**/*.zig"]),
    )
""",
)
