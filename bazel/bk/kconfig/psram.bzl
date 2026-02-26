# BK PSRAM module

def _kconfig_bool(key, enabled):
    if enabled:
        return "CONFIG_{}=y".format(key)
    return "# CONFIG_{} is not set".format(key)

def _render_psram_lines(ctx, core_label):
    if (not ctx.attr.enable) and (ctx.attr.as_sys_memory or ctx.attr.write_through or ctx.attr.calibrate or ctx.attr.auto_detect):
        fail("bk_{0}_psram: as_sys_memory/write_through/calibrate/auto_detect require enable=True".format(core_label.lower()))

    if (not ctx.attr.enable) and (ctx.attr.task_stack_in_psram or ctx.attr.queue_in_psram):
        fail("bk_{0}_psram: task_stack_in_psram/queue_in_psram require enable=True".format(core_label.lower()))

    if (not ctx.attr.enable) and ctx.attr.heap_init_set_zero:
        fail("bk_{0}_psram: heap_init_set_zero requires enable=True".format(core_label.lower()))

    if (not ctx.attr.enable) and ctx.attr.mbedtls_use_psram:
        fail("bk_{0}_psram: mbedtls_use_psram requires enable=True".format(core_label.lower()))

    if core_label == "CP" and ctx.attr.mbedtls_use_psram:
        fail("bk_cp_psram: mbedtls_use_psram is AP-only")

    lines = ["# {0} PSRAM".format(core_label)]

    lines.append(_kconfig_bool("PSRAM", ctx.attr.enable))

    if ctx.attr.enable:
        lines.append(_kconfig_bool("PSRAM_AS_SYS_MEMORY", ctx.attr.as_sys_memory))
        lines.append(_kconfig_bool("PSRAM_WRITE_THROUGH", ctx.attr.write_through))
        lines.append(_kconfig_bool("PSRAM_CALIBRATE", ctx.attr.calibrate))
        lines.append(_kconfig_bool("PSRAM_AUTO_DETECT", ctx.attr.auto_detect))
    else:
        lines.append("# CONFIG_PSRAM_AS_SYS_MEMORY is not set")
        lines.append("# CONFIG_PSRAM_WRITE_THROUGH is not set")
        lines.append("# CONFIG_PSRAM_CALIBRATE is not set")
        lines.append("# CONFIG_PSRAM_AUTO_DETECT is not set")

    # BK FreeRTOS/RTOS options that control PSRAM placement/initialization.
    # These are grouped in psram.bzl to keep freertos.bzl focused on RTOS policy.
    lines.append(_kconfig_bool("TASK_STACK_IN_PSRAM", ctx.attr.task_stack_in_psram))
    lines.append(_kconfig_bool("QUEUE_IN_PSRAM", ctx.attr.queue_in_psram))
    lines.append(_kconfig_bool("PSRAM_HEAP_INIT_SET_ZERO", ctx.attr.heap_init_set_zero))

    # AP-only: mbedTLS allocator backend.
    if core_label == "AP":
        lines.append(_kconfig_bool("MBEDTLS_USE_PSRAM", ctx.attr.mbedtls_use_psram))

    return lines

def _bk_ap_psram_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = _render_psram_lines(ctx, "AP")
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

def _bk_cp_psram_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = _render_psram_lines(ctx, "CP")
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

_PSRAM_ATTRS = {
    "enable": attr.bool(
        default = True,
        doc = "Enable PSRAM driver",
    ),
    "as_sys_memory": attr.bool(
        default = False,
        doc = "CONFIG_PSRAM_AS_SYS_MEMORY",
    ),
    "write_through": attr.bool(
        default = False,
        doc = "CONFIG_PSRAM_WRITE_THROUGH",
    ),
    "calibrate": attr.bool(
        default = False,
        doc = "CONFIG_PSRAM_CALIBRATE",
    ),
    "auto_detect": attr.bool(
        default = False,
        doc = "CONFIG_PSRAM_AUTO_DETECT",
    ),
    "task_stack_in_psram": attr.bool(
        default = False,
        doc = "CONFIG_TASK_STACK_IN_PSRAM",
    ),
    "queue_in_psram": attr.bool(
        default = False,
        doc = "CONFIG_QUEUE_IN_PSRAM",
    ),
    "heap_init_set_zero": attr.bool(
        default = False,
        doc = "CONFIG_PSRAM_HEAP_INIT_SET_ZERO",
    ),
    "mbedtls_use_psram": attr.bool(
        default = False,
        doc = "CONFIG_MBEDTLS_USE_PSRAM (AP only)",
    ),
}

bk_ap_psram = rule(
    implementation = _bk_ap_psram_impl,
    attrs = _PSRAM_ATTRS,
    doc = "AP PSRAM configuration (including RTOS PSRAM placement flags)",
)

bk_cp_psram = rule(
    implementation = _bk_cp_psram_impl,
    attrs = _PSRAM_ATTRS,
    doc = "CP PSRAM configuration (including RTOS PSRAM placement flags)",
)
