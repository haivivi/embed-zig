# BK7258 Kconfig: FreeRTOS configuration (AP/CP)

def _kconfig_bool(key, enabled):
    if enabled:
        return "CONFIG_{}=y".format(key)
    return "# CONFIG_{} is not set".format(key)

def _render_freertos_lines(ctx, core_label):
    ver = ctx.attr.version
    if ver not in ["v9", "v10", "smp"]:
        fail("bk_{0}_freertos: version must be one of v9, v10, smp".format(core_label.lower()))

    lines = ["# {0} FreeRTOS configuration".format(core_label)]

    lines.append(_kconfig_bool("FREERTOS", ctx.attr.enable))
    lines.append(_kconfig_bool("FREERTOS_FPU_ENABLE", ctx.attr.fpu_enable))
    lines.append(_kconfig_bool("FREERTOS_USE_QUEUE_SETS", ctx.attr.use_queue_sets))
    lines.append(_kconfig_bool("MEM_MGMT", ctx.attr.mem_mgmt))

    # Version selection
    lines.append(_kconfig_bool("FREERTOS_V9", ver == "v9"))
    lines.append(_kconfig_bool("FREERTOS_V10", ver == "v10"))
    lines.append(_kconfig_bool("FREERTOS_SMP", ver == "smp"))

    # Optional features
    lines.append(_kconfig_bool("FREERTOS_POSIX", ctx.attr.posix))
    lines.append(_kconfig_bool("FREERTOS_TRACE", ctx.attr.trace))
    lines.append(_kconfig_bool("FREERTOS_ALLOW_OS_API_IN_IRQ_DISABLED", ctx.attr.allow_os_api_in_irq_disabled))
    lines.append(_kconfig_bool("FREERTOS_SMP_TEMP", ctx.attr.smp_temp))
    lines.append(_kconfig_bool("FREERTOS_RTT_MONITOR", ctx.attr.rtt_monitor))
    lines.append("CONFIG_FREERTOS_USE_TICKLESS_IDLE={}".format(ctx.attr.tickless_idle))
    lines.append("CONFIG_FREERTOS_TICK_RATE_HZ={}".format(ctx.attr.tick_rate_hz))

    # Debug / stats
    lines.append(_kconfig_bool("BK_OS_TIMER_DEBUG", ctx.attr.os_timer_debug))
    lines.append(_kconfig_bool("DEBUG_RTOS_TIMER", ctx.attr.debug_rtos_timer))
    lines.append("CONFIG_RTOS_TIMER_DEBUG_CNT={}".format(ctx.attr.rtos_timer_debug_cnt))
    lines.append(_kconfig_bool("FREERTOS_HISTORY_CPU_PERCENT", ctx.attr.history_cpu_percent))

    # Task name settings
    lines.append(_kconfig_bool("USE_STATIC_TASK_NAME", ctx.attr.use_static_task_name))
    lines.append("CONFIG_DYNAMIC_TASK_NAME_LEN={}".format(ctx.attr.dynamic_task_name_len))

    # Heap
    if ctx.attr.customize_heap_size > 0:
        lines.append("CONFIG_CUSTOMIZE_HEAP_SIZE={}".format(ctx.attr.customize_heap_size))
    else:
        lines.append("# CONFIG_CUSTOMIZE_HEAP_SIZE is not set")

    return lines

def _bk_ap_freertos_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = _render_freertos_lines(ctx, "AP")
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

def _bk_cp_freertos_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = _render_freertos_lines(ctx, "CP")
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

_FREERTOS_ATTRS = {
    "enable": attr.bool(mandatory = True, doc = "CONFIG_FREERTOS"),
    "fpu_enable": attr.bool(mandatory = True, doc = "CONFIG_FREERTOS_FPU_ENABLE"),
    "use_queue_sets": attr.bool(mandatory = True, doc = "CONFIG_FREERTOS_USE_QUEUE_SETS"),
    "mem_mgmt": attr.bool(mandatory = True, doc = "CONFIG_MEM_MGMT"),
    "version": attr.string(mandatory = True, doc = "FreeRTOS version: v9 | v10 | smp"),
    "posix": attr.bool(mandatory = True, doc = "CONFIG_FREERTOS_POSIX"),
    "trace": attr.bool(mandatory = True, doc = "CONFIG_FREERTOS_TRACE"),
    "allow_os_api_in_irq_disabled": attr.bool(
        mandatory = True,
        doc = "CONFIG_FREERTOS_ALLOW_OS_API_IN_IRQ_DISABLED",
    ),
    "smp_temp": attr.bool(mandatory = True, doc = "CONFIG_FREERTOS_SMP_TEMP"),
    "rtt_monitor": attr.bool(mandatory = True, doc = "CONFIG_FREERTOS_RTT_MONITOR"),
    "tickless_idle": attr.int(mandatory = True, doc = "CONFIG_FREERTOS_USE_TICKLESS_IDLE"),
    "tick_rate_hz": attr.int(mandatory = True, doc = "CONFIG_FREERTOS_TICK_RATE_HZ"),
    "os_timer_debug": attr.bool(mandatory = True, doc = "CONFIG_BK_OS_TIMER_DEBUG"),
    "debug_rtos_timer": attr.bool(mandatory = True, doc = "CONFIG_DEBUG_RTOS_TIMER"),
    "rtos_timer_debug_cnt": attr.int(mandatory = True, doc = "CONFIG_RTOS_TIMER_DEBUG_CNT"),
    "history_cpu_percent": attr.bool(mandatory = True, doc = "CONFIG_FREERTOS_HISTORY_CPU_PERCENT"),
    "use_static_task_name": attr.bool(mandatory = True, doc = "CONFIG_USE_STATIC_TASK_NAME"),
    "dynamic_task_name_len": attr.int(mandatory = True, doc = "CONFIG_DYNAMIC_TASK_NAME_LEN"),
    "customize_heap_size": attr.int(mandatory = True, doc = "CONFIG_CUSTOMIZE_HEAP_SIZE"),
}

bk_ap_freertos = rule(
    implementation = _bk_ap_freertos_impl,
    attrs = _FREERTOS_ATTRS,
    doc = "AP FreeRTOS configuration (explicit, no presets)",
)

bk_cp_freertos = rule(
    implementation = _bk_cp_freertos_impl,
    attrs = _FREERTOS_ATTRS,
    doc = "CP FreeRTOS configuration (explicit, no presets)",
)
