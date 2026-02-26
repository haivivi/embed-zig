# BK debug configuration

def _kconfig_bool(key, enabled):
    if enabled:
        return "CONFIG_{}=y".format(key)
    return "# CONFIG_{} is not set".format(key)

def _bk_debug_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = ["# Debug"]
    lines.append(_kconfig_bool("ASSERT_HALT", ctx.attr.assert_halt))
    lines.append(_kconfig_bool("ASSERT_REBOOT", ctx.attr.assert_reboot))
    lines.append(_kconfig_bool("DUMP_ENABLE", ctx.attr.dump_enable))

    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_ap_debug = rule(
    implementation = _bk_debug_impl,
    attrs = {
        "assert_halt": attr.bool(
            default = False,
            doc = "CONFIG_ASSERT_HALT",
        ),
        "assert_reboot": attr.bool(
            default = True,
            doc = "CONFIG_ASSERT_REBOOT",
        ),
        "dump_enable": attr.bool(
            default = False,
            doc = "CONFIG_DUMP_ENABLE",
        ),
    },
    doc = "Debug/assert/dump settings.",
)
