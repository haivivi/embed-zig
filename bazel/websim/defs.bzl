"""WebSim build rules — compile Zig apps to WASM for browser simulation.

Usage:
    load("//bazel/websim:defs.bzl", "websim_app")

    websim_app(
        name = "gpio_button",
        main = "wasm_main.zig",
        srcs = glob(["*.zig"]),
        deps = [
            "//lib/platform/websim",
            "//lib/hal",
        ],
    )

Run:
    bazel run //examples/websim/gpio_button:serve
"""

load("//bazel/zig:defs.bzl", "ZigModuleInfo")

def _get_zig_bin(zig_toolchain_files):
    """Find the zig binary from toolchain files."""
    for f in zig_toolchain_files:
        if f.basename == "zig" and f.is_source:
            return f
    fail("Could not find zig binary in toolchain")

def _decode_module(encoded):
    """Decode a tab-separated module string (same format as zig/defs.bzl)."""
    parts = encoded.split("\t")
    return struct(
        name = parts[0],
        root_path = parts[1],
        dep_names = parts[2].split(",") if len(parts) > 2 and parts[2] else [],
        c_include_dirs = parts[3].split(",") if len(parts) > 3 and parts[3] else [],
        link_libc = parts[4] == "1" if len(parts) > 4 else False,
        c_build_args = parts[5].split("|") if len(parts) > 5 and parts[5] else [],
    )

def _websim_app_impl(ctx):
    """Compile a Zig app to WASM and bundle with the web shell.

    Cross-compiles everything (Zig + C) to wasm32-freestanding-none.
    Cannot reuse host-compiled .a caches — must recompile C sources for WASM.
    """

    zig_files = ctx.attr._zig_toolchain.files.to_list()
    zig_bin = _get_zig_bin(zig_files)

    # Output
    site_dir = ctx.actions.declare_directory(ctx.label.name + "_site")
    wasm_file = ctx.actions.declare_file(ctx.label.name + ".wasm")
    cache_dir = ctx.actions.declare_directory(ctx.label.name + "_zig_cache")

    # Collect source files
    all_srcs = []
    for src in ctx.attr.srcs:
        all_srcs.extend(src.files.to_list())

    # Collect dep module info
    dep_infos = []
    dep_src_files = []
    dep_c_inputs = []
    needs_libc = False
    for dep in ctx.attr.deps:
        if ZigModuleInfo in dep:
            info = dep[ZigModuleInfo]
            dep_infos.append(info)
            dep_src_files.extend(info.transitive_srcs.to_list())
            dep_c_inputs.extend(info.transitive_c_inputs.to_list())
            if info.own_link_libc:
                needs_libc = True

    # Build zig args: cross-compile to WASM
    zig_args = [
        "build-exe",
        "-target", "wasm32-wasi-musl",
        "-rdynamic",
        "-O", "ReleaseSmall",
    ]

    # Use -lc for musl headers (needed by @cImport for C header processing).
    # LVGL with LV_STDLIB_BUILTIN provides its own malloc/string at runtime,
    # but still needs standard type headers (stdint.h etc.) at compile time.
    zig_args.append("-lc")

    # Collect C include dirs and C build args from ALL deps (direct + transitive).
    # When cross-compiling to WASM, we must recompile C sources from scratch
    # (host .a caches are for the wrong target). We need:
    #   - Global -I flags for C source compilation (before -M modules)
    #   - C source args (-cflags/files) from every dep that has C code
    # Direct deps provide these via ZigModuleInfo fields; transitive deps
    # carry them in the encoded module strings. Dedup by module name to avoid
    # duplicate symbols when diamond dependencies exist.
    c_include_seen = {}
    c_args_seen = {}
    for info in dep_infos:
        for inc_dir in info.own_c_include_dirs:
            if inc_dir not in c_include_seen:
                c_include_seen[inc_dir] = True
                zig_args.extend(["-I", inc_dir])
        if info.own_c_build_args and info.module_name not in c_args_seen:
            c_args_seen[info.module_name] = True
            zig_args.extend(info.own_c_build_args)
        # Also collect from transitive deps encoded in module strings
        for encoded in info.transitive_module_strings.to_list():
            mod = _decode_module(encoded)
            for inc_dir in mod.c_include_dirs:
                if inc_dir not in c_include_seen:
                    c_include_seen[inc_dir] = True
                    zig_args.extend(["-I", inc_dir])
            if mod.c_build_args and mod.name not in c_args_seen:
                c_args_seen[mod.name] = True
                zig_args.extend(mod.c_build_args)

    # Main module
    main_file = ctx.file.main
    module_name = ctx.label.name

    dep_names = [info.module_name for info in dep_infos]
    for dep_name in dep_names:
        zig_args.extend(["--dep", dep_name])
    zig_args.append("-M{}={}".format(module_name, main_file.path))

    # Add all transitive module definitions (same as zig_static_library cross-compile)
    # Zig compiler constraint: modules with C includes must come after modules without.
    # Passing them in the wrong order causes compilation failures (zig cc module resolution bug).
    # Remove this ordering workaround when fixed upstream in ziglang/zig.
    seen = {module_name: True}
    mods_no_inc = []
    mods_with_inc = []

    for info in dep_infos:
        if info.module_name not in seen:
            seen[info.module_name] = True
            mod = struct(
                name = info.module_name,
                root_path = info.root_source.path,
                dep_names = info.direct_dep_names,
                c_include_dirs = info.own_c_include_dirs,
                link_libc = info.own_link_libc,
            )
            if mod.c_include_dirs:
                mods_with_inc.append(mod)
            else:
                mods_no_inc.append(mod)
            if mod.link_libc:
                needs_libc = True

        for encoded in info.transitive_module_strings.to_list():
            mod = _decode_module(encoded)
            if mod.name not in seen:
                seen[mod.name] = True
                if mod.link_libc:
                    needs_libc = True
                if mod.c_include_dirs:
                    mods_with_inc.append(mod)
                else:
                    mods_no_inc.append(mod)

    for mod in mods_no_inc + mods_with_inc:
        for d in mod.dep_names:
            zig_args.extend(["--dep", d])
        zig_args.append("-M{}={}".format(mod.name, mod.root_path))
        for inc_dir in mod.c_include_dirs:
            zig_args.extend(["-I", inc_dir])

    zig_args.extend([
        "-femit-bin=" + wasm_file.path,
        "--cache-dir", cache_dir.path,
        "--global-cache-dir", cache_dir.path,
    ])

    # Compile WASM (fresh build, no cache reuse — all C sources recompiled for WASM)
    ctx.actions.run(
        executable = zig_bin,
        arguments = zig_args,
        inputs = all_srcs + dep_src_files + dep_c_inputs + zig_files,
        outputs = [wasm_file, cache_dir],
        env = {"HOME": cache_dir.path},
        mnemonic = "ZigWasmBuild",
        progress_message = "Compiling WASM %s" % ctx.label,
    )

    # Collect web files: board-specific shell + shared JS + FFmpeg + html2canvas
    board_web_files = ctx.attr.web_shell.files.to_list() if ctx.attr.web_shell else []
    shared_web_files = ctx.attr._web_shared.files.to_list()
    ffmpeg_files = ctx.attr._ffmpeg.files.to_list()
    h2c_files = ctx.attr._html2canvas.files.to_list()

    # Bundle: copy all into site directory
    all_web = board_web_files + shared_web_files + ffmpeg_files + h2c_files
    copy_cmds = ["mkdir -p " + site_dir.path]
    copy_cmds.append("cp {} {}/app.wasm".format(wasm_file.path, site_dir.path))
    for f in all_web:
        copy_cmds.append("cp {} {}/{}".format(f.path, site_dir.path, f.basename))

    ctx.actions.run_shell(
        command = " && ".join(copy_cmds),
        inputs = [wasm_file] + all_web,
        outputs = [site_dir],
        mnemonic = "WebSimBundle",
        progress_message = "Bundling WebSim site %s" % ctx.label,
    )

    return [DefaultInfo(
        files = depset([site_dir, wasm_file]),
    )]

_websim_build = rule(
    implementation = _websim_app_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Zig source files + embedded assets for the WASM app",
        ),
        "main": attr.label(
            allow_single_file = [".zig"],
            mandatory = True,
            doc = "WASM entry point (e.g., wasm_main.zig)",
        ),
        "deps": attr.label_list(
            providers = [ZigModuleInfo],
            doc = "zig_library / zig_module dependencies",
        ),
        "web_shell": attr.label(
            doc = "Board-specific web shell (index.html, style.css). Required.",
        ),
        "_zig_toolchain": attr.label(
            default = "@zig_toolchain//:zig_files",
        ),
        "_web_shared": attr.label(
            default = "//lib/platform/websim:web_shared",
        ),
        "_ffmpeg": attr.label(
            default = "//lib/platform/websim:ffmpeg",
        ),
        "_html2canvas": attr.label(
            default = "//lib/platform/websim:html2canvas",
        ),
    },
    doc = "Internal: compile Zig app to WASM + bundle web shell.",
)

# =============================================================================
# websim_serve — Run the WebSim site with a local HTTP server
# =============================================================================

def _websim_serve_impl(ctx):
    """Run the websim site with the Go HTTP server."""
    site_dir = None
    for f in ctx.attr.app[DefaultInfo].files.to_list():
        if f.is_directory:
            site_dir = f
            break

    if not site_dir:
        fail("No site directory found in websim_app output")

    server = ctx.executable._server
    
    # Create a runner script that passes the site directory to the server
    run_script = ctx.actions.declare_file(ctx.label.name + "_run.sh")
    ctx.actions.write(
        output = run_script,
        content = """#!/bin/bash
exec "{server}" "{site_dir}" "$@"
""".format(
            server = server.short_path,
            site_dir = site_dir.short_path,
        ),
        is_executable = True,
    )

    return [DefaultInfo(
        executable = run_script,
        runfiles = ctx.runfiles(
            files = [site_dir],
            transitive_files = ctx.attr._server[DefaultInfo].default_runfiles.files,
        ),
    )]

_websim_serve = rule(
    implementation = _websim_serve_impl,
    executable = True,
    attrs = {
        "app": attr.label(
            mandatory = True,
            doc = "websim_build target",
        ),
        "_server": attr.label(
            default = "//tools/websim_serve",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Serve a WebSim app with a local HTTP server.",
)

# =============================================================================
# websim_app — High-level macro: build + serve
# =============================================================================

def websim_app(name, main, srcs, web_shell, deps = [], visibility = None):
    """Build a WebSim WASM app and create a serve target.

    Creates two targets:
        {name}       — Build WASM + bundle web shell
        {name}_serve — Run local HTTP server (bazel run)

    Args:
        web_shell: Board-specific web shell label (e.g., "//lib/platform/websim:web_h106").
                   Contains index.html + style.css for the board layout.

    Example:
        websim_app(
            name = "sim",
            main = "wasm_main.zig",
            srcs = glob(["**/*.zig"]),
            web_shell = "//lib/platform/websim:web_h106",
            deps = ["//lib/platform/websim", "//lib/hal"],
        )

    Run:
        bazel run //examples/apps/lvgl:sim_serve
    """
    _vis = visibility if visibility else ["//visibility:public"]

    _websim_build(
        name = name,
        main = main,
        srcs = srcs,
        deps = deps,
        web_shell = web_shell,
        visibility = _vis,
    )

    _websim_serve(
        name = name + "_serve",
        app = ":" + name,
        visibility = _vis,
    )

# =============================================================================
# websim_native_app — Native webview-based simulator (single binary)
# =============================================================================

def _websim_native_impl(ctx):
    """Compile a Zig app as a native executable with webview UI.

    Produces a single binary that opens a webview window.
    HTML/CSS/JS are embedded into the binary via @embedFile.
    """
    zig_files = ctx.attr._zig_toolchain.files.to_list()
    zig_bin = _get_zig_bin(zig_files)

    output = ctx.actions.declare_file(ctx.label.name)
    cache_dir = ctx.actions.declare_directory(ctx.label.name + "_zig_cache")

    # Collect source files
    all_srcs = []
    for src in ctx.attr.srcs:
        all_srcs.extend(src.files.to_list())

    # Collect dep module info
    dep_infos = []
    dep_src_files = []
    dep_c_inputs = []
    for dep in ctx.attr.deps:
        if ZigModuleInfo in dep:
            info = dep[ZigModuleInfo]
            dep_infos.append(info)
            dep_src_files.extend(info.transitive_srcs.to_list())
            dep_c_inputs.extend(info.transitive_c_inputs.to_list())

    # Build zig args: native target
    zig_args = ["build-exe"]

    # Link libc++ for webview C++ code
    zig_args.extend(["-lc++", "-lc"])

    # Platform-specific linking.
    # Currently macOS-only: WebKit (webview backend) + Cocoa (clipboard/media).
    # Linux would need WebKitGTK + GTK, Windows would need WebView2 + COM.
    # TODO: Add platform detection when Linux/Windows support is added.
    zig_args.extend(["-framework", "WebKit", "-framework", "Cocoa"])

    # Compute webview include dir
    webview_headers = ctx.attr._webview_headers.files.to_list()
    webview_include_dir = None
    for h in webview_headers:
        if h.path.endswith("webview.h") and "/include/" in h.path:
            parts = h.path.split("/include/")
            webview_include_dir = parts[0] + "/include"
            break

    # Add webview include as global (before -M) so all modules can use @cImport
    if webview_include_dir:
        zig_args.extend(["-I", webview_include_dir])

    # Collect C include dirs from deps
    c_include_seen = {}
    c_args_seen = {}
    for info in dep_infos:
        for inc_dir in info.own_c_include_dirs:
            if inc_dir not in c_include_seen:
                c_include_seen[inc_dir] = True
                zig_args.extend(["-I", inc_dir])
        if info.own_c_build_args and info.module_name not in c_args_seen:
            c_args_seen[info.module_name] = True
            zig_args.extend(info.own_c_build_args)
        for encoded in info.transitive_module_strings.to_list():
            mod = _decode_module(encoded)
            for inc_dir in mod.c_include_dirs:
                if inc_dir not in c_include_seen:
                    c_include_seen[inc_dir] = True
                    zig_args.extend(["-I", inc_dir])
            if mod.c_build_args and mod.name not in c_args_seen:
                c_args_seen[mod.name] = True
                zig_args.extend(mod.c_build_args)

    # Main module
    main_file = ctx.file.main
    module_name = ctx.label.name

    dep_names = [info.module_name for info in dep_infos]
    for dep_name in dep_names:
        zig_args.extend(["--dep", dep_name])
    zig_args.append("-M{}={}".format(module_name, main_file.path))

    # Add recorder C source right after main module definition
    # (C files must come after the -M they belong to)
    recorder_c = ctx.file._recorder_c
    recorder_h = ctx.file._recorder_h
    minih264_headers = ctx.attr._minih264_headers.files.to_list()
    minimp4_headers = ctx.attr._minimp4_headers.files.to_list()

    recorder_dir = recorder_c.path.rsplit("/", 1)[0] if "/" in recorder_c.path else ""
    if recorder_dir:
        zig_args.extend(["-I", recorder_dir])
    for h in minih264_headers:
        hdir = h.path.rsplit("/", 1)[0] if "/" in h.path else ""
        if hdir:
            zig_args.extend(["-I", hdir])
            break
    for h in minimp4_headers:
        hdir = h.path.rsplit("/", 1)[0] if "/" in h.path else ""
        if hdir:
            zig_args.extend(["-I", hdir])
            break

    zig_args.append(recorder_c.path)

    # Add minih264e and minimp4 implementation files
    recorder_impl_files = ctx.attr._recorder_impl_c.files.to_list()
    for impl_f in recorder_impl_files:
        zig_args.append(impl_f.path)

    # Add transitive module definitions
    seen = {module_name: True}
    mods_no_inc = []
    mods_with_inc = []

    for info in dep_infos:
        if info.module_name not in seen:
            seen[info.module_name] = True
            mod = struct(
                name = info.module_name,
                root_path = info.root_source.path,
                dep_names = info.direct_dep_names,
                c_include_dirs = info.own_c_include_dirs,
            )
            if mod.c_include_dirs:
                mods_with_inc.append(mod)
            else:
                mods_no_inc.append(mod)

        for encoded in info.transitive_module_strings.to_list():
            mod = _decode_module(encoded)
            if mod.name not in seen:
                seen[mod.name] = True
                if mod.c_include_dirs:
                    mods_with_inc.append(mod)
                else:
                    mods_no_inc.append(mod)

    for mod in mods_no_inc + mods_with_inc:
        for d in mod.dep_names:
            zig_args.extend(["--dep", d])
        zig_args.append("-M{}={}".format(mod.name, mod.root_path))
        for inc_dir in mod.c_include_dirs:
            zig_args.extend(["-I", inc_dir])
    # Link webview static library
    webview_lib = ctx.file._webview_lib
    zig_args.append(webview_lib.path)

    zig_args.extend([
        "-femit-bin=" + output.path,
        "--cache-dir", cache_dir.path,
        "--global-cache-dir", cache_dir.path,
    ])

    # Compile
    ctx.actions.run(
        executable = zig_bin,
        arguments = zig_args,
        inputs = all_srcs + dep_src_files + dep_c_inputs + zig_files +
                 webview_headers + [webview_lib] +
                 [recorder_c, recorder_h] + recorder_impl_files +
                 minih264_headers + minimp4_headers,
        outputs = [output, cache_dir],
        env = {"HOME": cache_dir.path},
        mnemonic = "ZigNativeBuild",
        progress_message = "Compiling native WebSim %s" % ctx.label,
    )

    return [DefaultInfo(
        files = depset([output]),
        executable = output,
    )]

_websim_native_build = rule(
    implementation = _websim_native_impl,
    executable = True,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Zig source files + web assets (HTML/CSS/JS for @embedFile)",
        ),
        "main": attr.label(
            allow_single_file = [".zig"],
            mandatory = True,
            doc = "Native entry point (e.g., main.zig)",
        ),
        "deps": attr.label_list(
            providers = [ZigModuleInfo],
            doc = "zig_library / zig_package dependencies",
        ),
        "_zig_toolchain": attr.label(
            default = "@zig_toolchain//:zig_files",
        ),
        "_webview_lib": attr.label(
            default = "//third_party/webview:webview_static",
            allow_single_file = True,
        ),
        "_webview_headers": attr.label(
            default = "//third_party/webview:webview_headers",
        ),
        "_recorder_c": attr.label(
            default = "//lib/platform/websim:recorder_c",
            allow_single_file = True,
        ),
        "_recorder_h": attr.label(
            default = "//lib/platform/websim:recorder_h",
            allow_single_file = True,
        ),
        "_minih264_headers": attr.label(
            default = "//third_party/minih264:minih264_headers",
        ),
        "_minimp4_headers": attr.label(
            default = "//third_party/minimp4:minimp4_headers",
        ),
        "_recorder_impl_c": attr.label(
            default = "//lib/platform/websim:recorder_impl_c",
        ),
    },
    doc = "Compile a native WebSim app with webview UI.",
)

def websim_native_app(name, main, srcs, deps = [], visibility = None):
    """Build a native WebSim app (single binary with webview window).

    Unlike websim_app (WASM + browser), this produces a native executable
    that opens a webview window directly. No HTTP server needed.

    Run:
        bazel run //examples/apps/adc_button/websim:native

    Args:
        main: Native entry point (e.g., "main.zig")
        srcs: Zig sources + web assets (HTML/CSS/JS for @embedFile)
        deps: zig_library dependencies
    """
    _vis = visibility if visibility else ["//visibility:public"]

    _websim_native_build(
        name = name,
        main = main,
        srcs = srcs,
        deps = deps,
        visibility = _vis,
    )
