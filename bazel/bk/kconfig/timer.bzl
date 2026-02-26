# BK timer module

def _kconfig_bool(key, enabled):
    if enabled:
        return "CONFIG_{}=y".format(key)
    return "# CONFIG_{} is not set".format(key)

def _bk_timer_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = ["# Timer override"]
    lines.append(_kconfig_bool("TIMER", ctx.attr.timer))
    lines.append(_kconfig_bool("TIMER_COUNTER", ctx.attr.timer_counter))
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_ap_timer = rule(
    implementation = _bk_timer_impl,
    attrs = {
        "timer": attr.bool(mandatory = True, doc = "CONFIG_TIMER"),
        "timer_counter": attr.bool(mandatory = True, doc = "CONFIG_TIMER_COUNTER"),
    },
    doc = "Enable hardware timer",
)