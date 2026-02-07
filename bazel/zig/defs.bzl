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

ZigModuleInfo = provider(
    doc = "Bazel-native Zig module information (no build.zig needed)",
    fields = {
        "module_name": "string — Module name used in @import() and -M flag",
        "root_source": "File — Root .zig source file (e.g., src/trait.zig)",
        "srcs": "depset(File) — Source files belonging to this module only",
        "transitive_srcs": "depset(File) — All source files across transitive deps",
        "direct_dep_names": "list(string) — Names of direct module dependencies",
        "transitive_module_strings": "depset(string) — Encoded module records for all transitive deps (O(1) merge per layer)",
        "cache_dir": "File (TreeArtifact) — accumulated zig cache (own + deps)",
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

def _encode_module(name, root_path, dep_names):
    """Encode a module record as a tab-separated string for depset storage.

    Format: "name\\troot_source_path\\tdep1,dep2,dep3"
    """
    return "{}\t{}\t{}".format(name, root_path, ",".join(dep_names) if dep_names else "")

def _decode_module(encoded):
    """Decode a tab-separated module string back to a struct."""
    parts = encoded.split("\t")
    return struct(
        name = parts[0],
        root_path = parts[1],
        dep_names = parts[2].split(",") if len(parts) > 2 and parts[2] else [],
    )

def _build_module_args(main_name, main_root_path, direct_dep_names, all_dep_module_strings):
    """Build the -M / --dep argument list for the zig compiler.

    Args:
        main_name: string — main module name
        main_root_path: string — path to main module root source file
        direct_dep_names: list(string) — names of main module's direct deps
        all_dep_module_strings: depset(string) — encoded module records for ALL
            transitive deps (direct deps + their transitive deps, deduped by depset)

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
    args.append("-M{}={}".format(main_name, main_root_path))

    # 2. Dependency modules (deduped by depset)
    seen = {main_name: True}
    for encoded in all_dep_module_strings.to_list():
        mod = _decode_module(encoded)
        if mod.name in seen:
            continue
        seen[mod.name] = True
        for dep_name in mod.dep_names:
            args.extend(["--dep", dep_name])
        args.append("-M{}={}".format(mod.name, mod.root_path))

    return args

def _collect_deps(own_srcs, deps):
    """Collect dependency info from zig_library deps.

    Args:
        own_srcs: depset(File) — this module's own source files
        deps: list(Target) — targets providing ZigModuleInfo

    Returns a struct with:
        direct_dep_names: list(string)
        dep_cache_dirs: list(File)
        transitive_src_depsets: list(depset) — own_srcs + all deps' transitive_srcs
        all_dep_module_strings: depset(string) — encoded module records for all deps
    """
    direct_dep_infos = []
    direct_dep_names = []
    transitive_src_depsets = [own_srcs]
    dep_cache_dirs = []

    for dep in deps:
        info = dep[ZigModuleInfo]
        direct_dep_infos.append(info)
        direct_dep_names.append(info.module_name)
        transitive_src_depsets.append(info.transitive_srcs)
        if info.cache_dir:
            dep_cache_dirs.append(info.cache_dir)

    direct_dep_strings = [
        _encode_module(info.module_name, info.root_source.path, info.direct_dep_names)
        for info in direct_dep_infos
    ]
    all_dep_module_strings = depset(
        direct_dep_strings,
        transitive = [info.transitive_module_strings for info in direct_dep_infos],
    )

    return struct(
        direct_dep_names = direct_dep_names,
        dep_cache_dirs = dep_cache_dirs,
        transitive_src_depsets = transitive_src_depsets,
        all_dep_module_strings = all_dep_module_strings,
    )

# =============================================================================
# _zig_tool — Bootstrap rule for compiling Zig helper tools (e.g., cache_merge)
# =============================================================================

def _zig_tool_impl(ctx):
    """Compile a single .zig file into an executable tool. No deps, no modules."""
    zig_files = ctx.attr._zig_toolchain.files.to_list()
    zig_bin = _get_zig_bin(zig_files)
    src = ctx.file.src
    output = ctx.actions.declare_file(ctx.label.name)
    cache_dir = ctx.actions.declare_directory(ctx.label.name + "_zig_cache")

    ctx.actions.run(
        executable = zig_bin,
        arguments = [
            "build-exe",
            "-Mroot=" + src.path,
            "-femit-bin=" + output.path,
            "--cache-dir", cache_dir.path,
            "--global-cache-dir", cache_dir.path,
        ],
        inputs = [src] + zig_files,
        outputs = [output, cache_dir],
        mnemonic = "ZigToolBuild",
        progress_message = "Building Zig tool %s" % ctx.label,
    )

    return [DefaultInfo(
        files = depset([output]),
        executable = output,
    )]

zig_tool = rule(
    implementation = _zig_tool_impl,
    executable = True,
    attrs = {
        "src": attr.label(
            allow_single_file = [".zig"],
            mandatory = True,
            doc = "Single .zig source file to compile",
        ),
        "_zig_toolchain": attr.label(
            default = "@zig_toolchain//:zig_files",
        ),
    },
    doc = "Bootstrap rule for compiling Zig helper tools (no deps, no modules).",
)

# =============================================================================
# zig_library — Compile a Zig module and propagate cache for incremental builds
# =============================================================================

def _zig_library_impl(ctx):
    """Define and pre-compile a Zig module, propagating accumulated cache."""

    root_source = ctx.file.main
    module_name = ctx.attr.module_name if ctx.attr.module_name else ctx.label.name
    own_srcs = depset(ctx.files.srcs)

    collected = _collect_deps(own_srcs, ctx.attr.deps)

    # Compile: zig build-lib through cache_merge tool
    zig_files = ctx.attr._zig_toolchain.files.to_list()
    zig_bin = _get_zig_bin(zig_files)

    # Use target name (not module name) for .a to avoid conflicts with zig_static_library
    output_a = ctx.actions.declare_file("lib{}.a".format(ctx.label.name))
    cache_dir = ctx.actions.declare_directory(ctx.label.name + "_zig_cache")

    module_args = _build_module_args(
        main_name = module_name,
        main_root_path = root_source.path,
        direct_dep_names = collected.direct_dep_names,
        all_dep_module_strings = collected.all_dep_module_strings,
    )

    # cache_merge <out_cache> [dep_caches...] -- <zig> build-lib <args> -femit-bin=out.a
    cm_args = [cache_dir.path]
    for dc in collected.dep_cache_dirs:
        cm_args.append(dc.path)
    cm_args.append("--")
    cm_args.append(zig_bin.path)
    cm_args.extend(["build-lib"] + module_args + ["-femit-bin=" + output_a.path])

    all_srcs = depset(transitive = collected.transitive_src_depsets).to_list()

    ctx.actions.run(
        executable = ctx.executable._compile_tool,
        arguments = cm_args,
        inputs = all_srcs + zig_files + collected.dep_cache_dirs,
        outputs = [output_a, cache_dir],
        mnemonic = "ZigLibCompile",
        progress_message = "Compiling Zig library %s" % ctx.label,
    )

    return [
        DefaultInfo(files = depset([output_a])),
        ZigModuleInfo(
            module_name = module_name,
            root_source = root_source,
            srcs = own_srcs,
            transitive_srcs = depset(transitive = collected.transitive_src_depsets),
            direct_dep_names = collected.direct_dep_names,
            transitive_module_strings = collected.all_dep_module_strings,
            cache_dir = cache_dir,
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
        "_zig_toolchain": attr.label(
            default = "@zig_toolchain//:zig_files",
        ),
        "_compile_tool": attr.label(
            default = "//bazel/zig:cache_merge",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = """Define a Zig module and pre-compile to populate cache for downstream rules.

Each zig_library compiles with zig build-lib through the cache_merge tool,
producing an accumulated cache_dir that downstream rules can reuse for
incremental builds.

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

    output = ctx.actions.declare_file("lib{}.a".format(info.module_name))
    cache_dir = ctx.actions.declare_directory(ctx.label.name + "_zig_cache")

    module_args = _build_module_args(
        main_name = info.module_name,
        main_root_path = info.root_source.path,
        direct_dep_names = info.direct_dep_names,
        all_dep_module_strings = info.transitive_module_strings,
    )

    # Collect dep cache from the lib target
    dep_cache_dirs = []
    if info.cache_dir:
        dep_cache_dirs.append(info.cache_dir)

    # cache_merge <out_cache> [dep_caches...] -- <zig> build-lib <args>
    cm_args = [cache_dir.path]
    for dc in dep_cache_dirs:
        cm_args.append(dc.path)
    cm_args.append("--")
    cm_args.append(zig_bin.path)
    cm_args.extend(["build-lib"] + module_args + ["-femit-bin=" + output.path])
    if ctx.attr.optimize:
        cm_args.extend(["-O", ctx.attr.optimize])
    if ctx.attr.target:
        cm_args.extend(["-target", ctx.attr.target])

    all_srcs = info.transitive_srcs.to_list()

    ctx.actions.run(
        executable = ctx.executable._compile_tool,
        arguments = cm_args,
        inputs = all_srcs + zig_files + dep_cache_dirs,
        outputs = [output, cache_dir],
        mnemonic = "ZigBuildLib",
        progress_message = "Compiling Zig static library %s" % ctx.label,
    )

    return [
        DefaultInfo(files = depset([output])),
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
        "_compile_tool": attr.label(
            default = "//bazel/zig:cache_merge",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = """Compile a zig_library into a static library (.a).

Uses the dep's accumulated cache for incremental compilation.

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

    output = ctx.actions.declare_file(ctx.label.name)
    cache_dir = ctx.actions.declare_directory(ctx.label.name + "_zig_cache")

    collected = _collect_deps(depset(ctx.files.srcs), ctx.attr.deps)

    module_args = _build_module_args(
        main_name = module_name,
        main_root_path = root_source.path,
        direct_dep_names = collected.direct_dep_names,
        all_dep_module_strings = collected.all_dep_module_strings,
    )

    # cache_merge <out_cache> [dep_caches...] -- <zig> build-exe <args>
    cm_args = [cache_dir.path]
    for dc in collected.dep_cache_dirs:
        cm_args.append(dc.path)
    cm_args.append("--")
    cm_args.append(zig_bin.path)
    cm_args.extend(["build-exe"] + module_args + ["-femit-bin=" + output.path])
    if ctx.attr.optimize:
        cm_args.extend(["-O", ctx.attr.optimize])
    if ctx.attr.target:
        cm_args.extend(["-target", ctx.attr.target])

    all_srcs = depset(transitive = collected.transitive_src_depsets).to_list()

    ctx.actions.run(
        executable = ctx.executable._compile_tool,
        arguments = cm_args,
        inputs = all_srcs + zig_files + collected.dep_cache_dirs,
        outputs = [output, cache_dir],
        mnemonic = "ZigBuildExe",
        progress_message = "Compiling Zig binary %s" % ctx.label,
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
        "_compile_tool": attr.label(
            default = "//bazel/zig:cache_merge",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = """Compile a Zig executable using dep caches for incremental builds.

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

    test_bin = ctx.actions.declare_file(ctx.label.name + "_test_bin")
    cache_dir = ctx.actions.declare_directory(ctx.label.name + "_zig_cache")

    collected = _collect_deps(depset(ctx.files.srcs), ctx.attr.deps)

    module_args = _build_module_args(
        main_name = module_name,
        main_root_path = root_source.path,
        direct_dep_names = collected.direct_dep_names,
        all_dep_module_strings = collected.all_dep_module_strings,
    )

    # cache_merge <out_cache> [dep_caches...] -- <zig> test <args>
    cm_args = [cache_dir.path]
    for dc in collected.dep_cache_dirs:
        cm_args.append(dc.path)
    cm_args.append("--")
    cm_args.append(zig_bin.path)
    cm_args.extend(["test"] + module_args + [
        "--test-no-exec",
        "-femit-bin=" + test_bin.path,
    ])
    if ctx.attr.optimize:
        cm_args.extend(["-O", ctx.attr.optimize])
    if ctx.attr.target:
        cm_args.extend(["-target", ctx.attr.target])

    all_srcs = depset(transitive = collected.transitive_src_depsets).to_list()

    ctx.actions.run(
        executable = ctx.executable._compile_tool,
        arguments = cm_args,
        inputs = all_srcs + zig_files + collected.dep_cache_dirs,
        outputs = [test_bin, cache_dir],
        mnemonic = "ZigTestCompile",
        progress_message = "Compiling Zig tests %s" % ctx.label,
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
        "_compile_tool": attr.label(
            default = "//bazel/zig:cache_merge",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = """Compile and run Zig tests using dep caches for incremental builds.

Example:
    zig_test(
        name = "trait_test",
        main = "src/trait.zig",
        srcs = glob(["src/**/*.zig"]),
    )
""",
)
