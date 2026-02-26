# BK PWM module

def _kconfig_bool(key, enabled):
    if enabled:
        return "CONFIG_{}=y".format(key)
    return "# CONFIG_{} is not set".format(key)

def _bk_pwm_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = ["# PWM override"]
    lines.append(_kconfig_bool("PWM", ctx.attr.pwm))
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_ap_pwm = rule(
    implementation = _bk_pwm_impl,
    attrs = {
        "pwm": attr.bool(mandatory = True, doc = "CONFIG_PWM"),
    },
    doc = "Enable PWM driver",
)