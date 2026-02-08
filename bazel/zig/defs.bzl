"""Zig build rules for Bazel — invoke zig compiler directly, no build.zig.

Rules:
    zig_library      — Compile a Zig module, propagate cache
    zig_test         — Compile and run Zig tests
    zig_binary       — Compile a Zig executable
    zig_static_library — Compile to .a (for C interop)
    zig_tool         — Bootstrap helper tools (e.g., cache_merge)

Macro:
    zig_package      — High-level: auto zig_library + zig_test from convention

Usage:
    load("//bazel/zig:defs.bzl", "zig_package")

    # One-liner for most packages (convention: src/{name}.zig)
    zig_package(name = "trait")

    # With deps
    zig_package(name = "hal", deps = ["//lib/trait", "//lib/pkg/motion"])

    # Custom root source or module name
    zig_package(name = "crypto", main = "src/suite.zig")
    zig_package(name = "std", module_name = "std_sal")

    # Mixed Zig + C + ASM
    zig_package(
        name = "noise",
        c_srcs = glob(["src/**/*.c", "src/**/*.h"]),
        asm_srcs = glob(["src/**/*.S"]),
        c_flags = ["-O3"],
        link_libc = True,
    )

    # Lower-level rules when needed
    load("//bazel/zig:defs.bzl", "zig_library", "zig_binary", "zig_test", "zig_static_library")

    zig_binary(
        name = "my_app",
        main = "src/main.zig",
        srcs = ["src/main.zig"],
        deps = [":hal"],
    )

    zig_static_library(
        name = "hal_a",
        lib = ":hal",
    )
"""

# =============================================================================
# ZigModuleInfo — Provider for Bazel-native Zig module metadata
# =============================================================================

ZigModuleInfo = provider(
    doc = "Zig module information for Bazel-native compilation (no build.zig needed)",
    fields = {
        "module_name": "string — Module name used in @import() and -M flag",
        "package_path": "string — Bazel package path (e.g., 'lib/hal'), for esp_zig_app compat",
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

    Returns a struct with:
        main: list(string) — main module args (--dep X -Mmain=root.zig)
        deps: list(string) — dep module args (-Mdep=dep.zig ...)

    C/ASM source files must go between main and deps (zig associates
    positional C/ASM sources with the most recently defined module).
    """
    main_args = []
    dep_args = []

    # 1. Main module
    for dep_name in direct_dep_names:
        main_args.extend(["--dep", dep_name])
    main_args.append("-M{}={}".format(main_name, main_root_path))

    # 2. Dependency modules (deduped by depset)
    seen = {main_name: True}
    for encoded in all_dep_module_strings.to_list():
        mod = _decode_module(encoded)
        if mod.name in seen:
            continue
        seen[mod.name] = True
        for dep_name in mod.dep_names:
            dep_args.extend(["--dep", dep_name])
        dep_args.append("-M{}={}".format(mod.name, mod.root_path))

    return struct(main = main_args, deps = dep_args)

def _build_c_asm_args(ctx):
    """Build C/ASM compiler arguments from rule attributes.

    Returns a struct with:
        pre_args: list(string) — global flags that go BEFORE -M module defs (-lc, -I)
        src_args: list(string) — source args that go AFTER main module's -M (-cflags, files)
        inputs: list(File) — C/ASM/header files to add to action inputs

    In zig CLI, flags after -M are module-scoped. Include paths (-I) and link
    flags (-lc) must come before the first -M to be global. C/ASM source files
    go after the main module's -M and before dep modules' -M.
    """
    pre_args = []
    src_args = []
    inputs = []

    # Link libc (global flag, before -M)
    if ctx.attr.link_libc:
        pre_args.append("-lc")

    # Include paths (global flag, before -M)
    pkg = ctx.label.package
    for inc in ctx.attr.c_includes:
        if inc:
            pre_args.extend(["-I", pkg + "/" + inc])
        else:
            pre_args.extend(["-I", pkg])

    # Collect C and ASM source files
    c_files = []
    for src in ctx.attr.c_srcs:
        for f in src.files.to_list():
            inputs.append(f)
            if f.path.endswith(".c"):
                c_files.append(f)
            # .h files are inputs (for include resolution) but not compiled

    asm_files = []
    for src in ctx.attr.asm_srcs:
        for f in src.files.to_list():
            inputs.append(f)
            if f.path.endswith(".S") or f.path.endswith(".s"):
                asm_files.append(f)

    # C/ASM source files with optional c_flags (after main module's -M)
    if c_files or asm_files:
        if ctx.attr.c_flags:
            src_args.append("-cflags")
            src_args.extend(ctx.attr.c_flags)
            src_args.append("--")
        for f in c_files + asm_files:
            src_args.append(f.path)

    return struct(pre_args = pre_args, src_args = src_args, inputs = inputs)

# Common C/ASM attributes shared by zig_library, zig_binary, zig_test
_C_ASM_ATTRS = {
    "c_srcs": attr.label_list(
        allow_files = [".c", ".h"],
        doc = "C source and header files. Headers are inputs only (not compiled).",
    ),
    "asm_srcs": attr.label_list(
        allow_files = [".S", ".s"],
        doc = "Assembly source files (.S/.s)",
    ),
    "c_includes": attr.string_list(
        doc = "C include directories, relative to package (e.g., 'src/noise/include')",
    ),
    "c_flags": attr.string_list(
        doc = "C compiler flags (e.g., ['-O3']). Applied to all c_srcs and asm_srcs.",
    ),
    "link_libc": attr.bool(
        default = False,
        doc = "Whether to link libc (-lc)",
    ),
}

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

    mods = _build_module_args(
        main_name = module_name,
        main_root_path = root_source.path,
        direct_dep_names = collected.direct_dep_names,
        all_dep_module_strings = collected.all_dep_module_strings,
    )

    # C/ASM sources
    c_asm = _build_c_asm_args(ctx)

    # cache_merge <out_cache> [dep_caches...] -- <zig> build-lib [global] <main-M> [c/asm] <dep-M> -femit-bin=out.a
    # pre_args (-lc, -I) are this module's own C/ASM flags only (not transitive — deps' C is in their cache)
    cm_args = [cache_dir.path]
    for dc in collected.dep_cache_dirs:
        cm_args.append(dc.path)
    cm_args.append("--")
    cm_args.append(zig_bin.path)
    cm_args.extend(["build-lib"] + c_asm.pre_args + mods.main + c_asm.src_args + mods.deps + ["-femit-bin=" + output_a.path])

    all_srcs = depset(transitive = collected.transitive_src_depsets).to_list()

    ctx.actions.run(
        executable = ctx.executable._compile_tool,
        arguments = cm_args,
        inputs = all_srcs + zig_files + collected.dep_cache_dirs + c_asm.inputs,
        outputs = [output_a, cache_dir],
        mnemonic = "ZigLibCompile",
        progress_message = "Compiling Zig library %s" % ctx.label,
    )

    return [
        DefaultInfo(files = depset([output_a])),
        ZigModuleInfo(
            module_name = module_name,
            package_path = ctx.label.package,
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
    attrs = dict(_C_ASM_ATTRS, **{
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
    }),
    doc = """Define a Zig module and pre-compile to populate cache for downstream rules.

Each zig_library compiles with zig build-lib through the cache_merge tool,
producing an accumulated cache_dir that downstream rules can reuse for
incremental builds. Supports mixed Zig + C + ASM compilation.

Example:
    zig_library(
        name = "noise",
        main = "src/noise.zig",
        srcs = glob(["src/**/*.zig"]),
        c_srcs = glob(["src/**/*.c", "src/**/*.h"]),
        asm_srcs = glob(["src/**/*.S"]),
        c_includes = ["src/noise/include"],
        c_flags = ["-O3"],
        link_libc = True,
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

    # Use target name (not module name) to avoid filename conflicts with zig_library
    output = ctx.actions.declare_file("lib{}.a".format(ctx.label.name))
    cache_dir = ctx.actions.declare_directory(ctx.label.name + "_zig_cache")

    mods = _build_module_args(
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
    cm_args.extend(["build-lib"] + mods.main + mods.deps + ["-femit-bin=" + output.path])
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

    mods = _build_module_args(
        main_name = module_name,
        main_root_path = root_source.path,
        direct_dep_names = collected.direct_dep_names,
        all_dep_module_strings = collected.all_dep_module_strings,
    )

    # C/ASM sources
    c_asm = _build_c_asm_args(ctx)

    # cache_merge <out_cache> [dep_caches...] -- <zig> build-exe [global] <main-M> [c/asm] <dep-M>
    # pre_args are this binary's own C/ASM flags only (deps' C is in their cache)
    cm_args = [cache_dir.path]
    for dc in collected.dep_cache_dirs:
        cm_args.append(dc.path)
    cm_args.append("--")
    cm_args.append(zig_bin.path)
    cm_args.extend(["build-exe"] + c_asm.pre_args + mods.main + c_asm.src_args + mods.deps + ["-femit-bin=" + output.path])
    if ctx.attr.optimize:
        cm_args.extend(["-O", ctx.attr.optimize])
    if ctx.attr.target:
        cm_args.extend(["-target", ctx.attr.target])

    all_srcs = depset(transitive = collected.transitive_src_depsets).to_list()

    ctx.actions.run(
        executable = ctx.executable._compile_tool,
        arguments = cm_args,
        inputs = all_srcs + zig_files + collected.dep_cache_dirs + c_asm.inputs,
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
    attrs = dict(_C_ASM_ATTRS, **{
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
    }),
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

    mods = _build_module_args(
        main_name = module_name,
        main_root_path = root_source.path,
        direct_dep_names = collected.direct_dep_names,
        all_dep_module_strings = collected.all_dep_module_strings,
    )

    # C/ASM sources
    c_asm = _build_c_asm_args(ctx)

    # cache_merge <out_cache> [dep_caches...] -- <zig> test [global] <main-M> [c/asm] <dep-M>
    # pre_args are this test's own C/ASM flags only (deps' C is in their cache)
    cm_args = [cache_dir.path]
    for dc in collected.dep_cache_dirs:
        cm_args.append(dc.path)
    cm_args.append("--")
    cm_args.append(zig_bin.path)
    cm_args.extend(["test"] + c_asm.pre_args + mods.main + c_asm.src_args + mods.deps + [
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
        inputs = all_srcs + zig_files + collected.dep_cache_dirs + c_asm.inputs,
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
    attrs = dict(_C_ASM_ATTRS, **{
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
    }),
    doc = """Compile and run Zig tests using dep caches for incremental builds.

Example:
    zig_test(
        name = "trait_test",
        main = "src/trait.zig",
        srcs = glob(["src/**/*.zig"]),
    )
""",
)

# =============================================================================
# zig_package — High-level macro: zig_library + zig_test from convention
# =============================================================================

def zig_package(
        name,
        main = None,
        srcs = None,
        module_name = None,
        deps = [],
        c_srcs = [],
        asm_srcs = [],
        c_includes = [],
        c_flags = [],
        link_libc = False,
        test = True,
        visibility = None):
    """High-level macro for Zig packages.

    Creates a zig_library target and optionally a zig_test target.
    Supports mixed Zig + C + ASM compilation.

    Convention: root source file is src/{name}.zig. Override with `main`.

    Targets created:
        {name}       — zig_library (provides ZigModuleInfo)
        {name}_test  — zig_test (if test=True)

    Args:
        name: Package name. Also used as module_name and to find src/{name}.zig.
        main: Root source file. Defaults to "src/{name}.zig".
        srcs: Zig source files. Defaults to glob(["src/**/*.zig"]).
        module_name: Module name for @import(). Defaults to name.
        deps: zig_library / zig_package dependencies.
        c_srcs: C source and header files (.c, .h).
        asm_srcs: Assembly source files (.S, .s).
        c_includes: C include directories, relative to package.
        c_flags: C compiler flags (e.g., ["-O3"]).
        link_libc: Whether to link libc.
        test: Whether to create a test target. Default True.
        visibility: Visibility. Defaults to ["//visibility:public"].

    Example:
        # Simplest form — convention-based
        zig_package(name = "trait")

        # With deps
        zig_package(name = "hal", deps = ["//lib/trait", "//lib/pkg/motion"])

        # Mixed Zig + C + ASM
        zig_package(
            name = "noise",
            c_srcs = glob(["src/**/*.c", "src/**/*.h"]),
            asm_srcs = glob(["src/**/*.S"]),
            c_flags = ["-O3"],
            link_libc = True,
        )
    """
    _main = main if main else "src/{}.zig".format(name)
    _srcs = srcs if srcs else native.glob(["src/**/*.zig"])
    _module_name = module_name if module_name else name
    _vis = visibility if visibility else ["//visibility:public"]

    zig_library(
        name = name,
        main = _main,
        srcs = _srcs,
        module_name = _module_name,
        deps = deps,
        c_srcs = c_srcs,
        asm_srcs = asm_srcs,
        c_includes = c_includes,
        c_flags = c_flags,
        link_libc = link_libc,
        visibility = _vis,
    )

    if test:
        zig_test(
            name = name + "_test",
            main = _main,
            srcs = _srcs,
            module_name = _module_name,
            deps = deps,
            c_srcs = c_srcs,
            asm_srcs = asm_srcs,
            c_includes = c_includes,
            c_flags = c_flags,
            link_libc = link_libc,
        )
