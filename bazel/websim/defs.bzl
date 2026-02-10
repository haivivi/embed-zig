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
    bazel build //examples/websim/gpio_button
    cd bazel-bin/examples/websim/gpio_button/gpio_button_site
    python3 -m http.server 8080
"""

load("//bazel/zig:defs.bzl", "ZigModuleInfo")

def _get_zig_bin(zig_toolchain_files):
    """Find the zig binary from toolchain files."""
    for f in zig_toolchain_files:
        if f.basename == "zig" and f.is_source:
            return f
    fail("Could not find zig binary in toolchain")

def _websim_app_impl(ctx):
    """Compile a Zig app to WASM and bundle with the web shell."""

    zig_files = ctx.attr._zig_toolchain.files.to_list()
    zig_bin = _get_zig_bin(zig_files)

    # Output: site directory containing .wasm + web shell
    site_dir = ctx.actions.declare_directory(ctx.label.name + "_site")
    wasm_file = ctx.actions.declare_file(ctx.label.name + ".wasm")
    cache_dir = ctx.actions.declare_directory(ctx.label.name + "_zig_cache")

    # Collect source files
    all_srcs = []
    for src in ctx.attr.srcs:
        all_srcs.extend(src.files.to_list())

    # Collect dep module info for -M flags
    dep_infos = []
    dep_src_files = []
    for dep in ctx.attr.deps:
        if ZigModuleInfo in dep:
            info = dep[ZigModuleInfo]
            dep_infos.append(info)
            dep_src_files.extend(info.transitive_srcs.to_list())

    # Build zig compile command
    zig_args = [
        "build-exe",
        "-target", "wasm32-freestanding-none",
        "-rdynamic",
        "-fno-entry",
        "-O", "ReleaseSmall",
    ]

    # Main module
    main_file = ctx.file.main
    module_name = ctx.label.name

    # Add dep modules
    dep_names = []
    for info in dep_infos:
        dep_names.append(info.module_name)

    for dep_name in dep_names:
        zig_args.extend(["--dep", dep_name])
    zig_args.append("-M{}={}".format(module_name, main_file.path))

    # Add transitive module definitions
    seen = {module_name: True}
    for info in dep_infos:
        if info.module_name not in seen:
            seen[info.module_name] = True
            inner_deps = info.direct_dep_names
            for d in inner_deps:
                zig_args.extend(["--dep", d])
            zig_args.append("-M{}={}".format(info.module_name, info.root_source.path))

        # Add transitive deps
        for encoded in info.transitive_module_strings.to_list():
            parts = encoded.split("\t")
            name = parts[0]
            root_path = parts[1]
            sub_deps = parts[2].split(",") if len(parts) > 2 and parts[2] else []
            if name not in seen:
                seen[name] = True
                for d in sub_deps:
                    zig_args.extend(["--dep", d])
                zig_args.append("-M{}={}".format(name, root_path))

    zig_args.extend([
        "-femit-bin=" + wasm_file.path,
        "--cache-dir", cache_dir.path,
        "--global-cache-dir", cache_dir.path,
    ])

    # Compile WASM
    ctx.actions.run(
        executable = zig_bin,
        arguments = zig_args,
        inputs = all_srcs + dep_src_files + zig_files,
        outputs = [wasm_file, cache_dir],
        env = {"HOME": cache_dir.path},
        mnemonic = "ZigWasmBuild",
        progress_message = "Compiling WASM %s" % ctx.label,
    )

    # Collect web shell files
    web_files = ctx.attr._web_shell.files.to_list()

    # Bundle: copy wasm + web shell into site directory
    # Build a shell command that creates the site directory
    copy_cmds = ["mkdir -p " + site_dir.path]
    copy_cmds.append("cp {} {}/app.wasm".format(wasm_file.path, site_dir.path))
    for f in web_files:
        # Strip the lib/platform/websim/web/ prefix
        basename = f.basename
        copy_cmds.append("cp {} {}/{}".format(f.path, site_dir.path, basename))

    ctx.actions.run_shell(
        command = " && ".join(copy_cmds),
        inputs = [wasm_file] + web_files,
        outputs = [site_dir],
        mnemonic = "WebSimBundle",
        progress_message = "Bundling WebSim site %s" % ctx.label,
    )

    return [DefaultInfo(
        files = depset([site_dir, wasm_file]),
    )]

websim_app = rule(
    implementation = _websim_app_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".zig"],
            mandatory = True,
            doc = "Zig source files for the WASM app",
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
        "_zig_toolchain": attr.label(
            default = "@zig_toolchain//:zig_files",
        ),
        "_web_shell": attr.label(
            default = "//lib/platform/websim:web_shell",
        ),
    },
    doc = """Compile a Zig app to WASM and bundle with the WebSim web shell.

    Output: {name}_site/ directory containing app.wasm + HTML/JS/CSS.
    Serve with any HTTP server to run in browser.

    Example:
        websim_app(
            name = "gpio_button",
            main = "wasm_main.zig",
            srcs = ["wasm_main.zig", "platform.zig"],
            deps = ["//lib/platform/websim", "//lib/hal"],
        )
    """,
)
