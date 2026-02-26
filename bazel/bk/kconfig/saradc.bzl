# BK SARADC module

def _kconfig_bool(key, enabled):
    if enabled:
        return "CONFIG_{}=y".format(key)
    return "# CONFIG_{} is not set".format(key)

def _bk_saradc_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = ["# SARADC override"]
    lines.append(_kconfig_bool("SARADC", ctx.attr.saradc))
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_ap_saradc = rule(
    implementation = _bk_saradc_impl,
    attrs = {
        "saradc": attr.bool(mandatory = True, doc = "CONFIG_SARADC"),
    },
    doc = "Enable SARADC driver",
)