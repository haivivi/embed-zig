"""BK7258 Kconfig generation rules.

Unlike ESP's esp_sdkconfig which generates a COMPLETE sdkconfig, BK configs
are OVERRIDES appended to the Armino base project config. Modules should only
contain the minimal Kconfig lines to ENABLE a feature that is NOT already
enabled in the Armino base project.

Usage:
    load("//bazel/bk/kconfig:defs.bzl", "bk_config", "bk_pwm", "bk_audio", "bk_saradc")

    # Feature modules (only what the base project doesn't enable)
    bk_pwm(name = "pwm")
    bk_audio(name = "audio")

    # Assemble overrides
    bk_config(
        name = "ap_config",
        modules = [":pwm"],
    )
"""

# =============================================================================
# Feature modules — each generates a Kconfig override fragment
# =============================================================================

def _bk_pwm_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = [
        "# PWM override",
        "CONFIG_PWM=y",
    ]
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_pwm = rule(
    implementation = _bk_pwm_impl,
    attrs = {},
    doc = "Enable PWM driver",
)

def _bk_audio_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = [
        "# Audio override",
        "CONFIG_AUDIO=y",
        "CONFIG_AUDIO_ADC=y",
        "CONFIG_AUDIO_DAC=y",
        "CONFIG_AUDIO_RING_BUFF=y",
    ]
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_audio = rule(
    implementation = _bk_audio_impl,
    attrs = {},
    doc = "Enable audio pipeline (ADC/DAC/ring buffer)",
)

def _bk_saradc_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = [
        "# SARADC override",
        "CONFIG_SARADC=y",
    ]
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_saradc = rule(
    implementation = _bk_saradc_impl,
    attrs = {},
    doc = "Enable SARADC driver",
)

def _bk_timer_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = [
        "# Timer override",
        "CONFIG_TIMER=y",
        "CONFIG_TIMER_COUNTER=y",
    ]
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_timer = rule(
    implementation = _bk_timer_impl,
    attrs = {},
    doc = "Enable hardware timer",
)

def _bk_ble_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = [
        "# BLE override",
        "CONFIG_BLE=y",
        "CONFIG_BLUETOOTH_AP=y",
    ]
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_ble = rule(
    implementation = _bk_ble_impl,
    attrs = {},
    doc = "Enable BLE stack on AP core",
)

def _bk_aec_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = [
        "# AEC algorithm override",
        "CONFIG_ADK_AEC_ALGORITHM=y",
    ]
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_aec = rule(
    implementation = _bk_aec_impl,
    attrs = {},
    doc = "Enable AEC (Acoustic Echo Cancellation) algorithm",
)

def _bk_uart_direct_impl(ctx):
    """AP logs direct to UART0 (not via mailbox to CP)."""
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = [
        "# UART direct print — AP logs visible on UART0",
        "CONFIG_UART_PRINT_PORT=0",
        "CONFIG_SYS_PRINT_DEV_UART=y",
        "# CONFIG_SYS_PRINT_DEV_MAILBOX is not set",
    ]
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_uart_direct = rule(
    implementation = _bk_uart_direct_impl,
    attrs = {},
    doc = "AP logs direct to UART0 (required for serial monitoring)",
)

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
