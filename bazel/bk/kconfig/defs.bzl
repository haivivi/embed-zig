"""BK7258 Kconfig generation rules.

BK configs are OVERRIDES appended to the Armino base project config.
All rules carry an AP/CP prefix to indicate which core they target.

Usage:
    load("//bazel/bk/kconfig:defs.bzl", "bk_config", "bk_ap_uart", "bk_ap_debug")

    bk_ap_uart(name = "uart", sys_print_dev = "uart")
    bk_ap_debug(name = "debug", assert_halt = True, assert_reboot = False)

    bk_config(
        name = "ap_config",
        modules = [":uart", ":debug"],
    )
"""

# =============================================================================
# Feature modules (loaded from per-feature .bzl files)
# =============================================================================

load("//bazel/bk/kconfig:uart.bzl", "bk_ap_uart", "bk_ap_uart_direct")
load("//bazel/bk/kconfig:debug.bzl", "bk_ap_debug")
load("//bazel/bk/kconfig:pwm.bzl", "bk_ap_pwm")
load("//bazel/bk/kconfig:audio.bzl", "bk_ap_audio")
load("//bazel/bk/kconfig:saradc.bzl", "bk_ap_saradc")
load("//bazel/bk/kconfig:timer.bzl", "bk_ap_timer")
load("//bazel/bk/kconfig:bt.bzl", "bk_ap_bt")
load("//bazel/bk/kconfig:psram.bzl", "bk_ap_psram", "bk_cp_psram")
load("//bazel/bk/kconfig:freertos.bzl", "bk_ap_freertos", "bk_cp_freertos")
load("//bazel/bk/kconfig:app.bzl", "bk_ap_app", "bk_cp_app")
load("//bazel/bk/kconfig:lwip.bzl", "bk_ap_lwip")

def _bk_custom_impl(ctx):
    """Escape hatch: raw Kconfig lines."""
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = ["# Custom Kconfig override"] + ctx.attr.configs
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_custom = rule(
    implementation = _bk_custom_impl,
    attrs = {
        "configs": attr.string_list(mandatory = True, doc = "Raw CONFIG_xxx=y lines"),
    },
    doc = "Raw Kconfig lines (escape hatch for uncommon options)",
)

# =============================================================================
# bk_config — Concatenate override fragments into a single file
# =============================================================================

def _bk_config_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".config")

    fragments = []
    for module in ctx.attr.modules:
        fragments.extend(module.files.to_list())

    if not fragments:
        ctx.actions.write(output = out, content = "# Empty BK Kconfig override\n")
    else:
        cmd = "cat"
        for f in fragments:
            cmd += " " + f.path
        cmd += " > " + out.path

        ctx.actions.run_shell(
            inputs = fragments,
            outputs = [out],
            command = cmd,
        )

    return [DefaultInfo(files = depset([out]))]

bk_config = rule(
    implementation = _bk_config_impl,
    attrs = {
        "modules": attr.label_list(
            allow_files = True,
            doc = "Feature module config fragments (bk_pwm, bk_audio, etc.)",
        ),
    },
    doc = """Concatenate Kconfig override fragments.

    Usage:
        bk_config(
            name = "ap_config",
            modules = [":pwm", ":audio"],
        )
    """,
)
