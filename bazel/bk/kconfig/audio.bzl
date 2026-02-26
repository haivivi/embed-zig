# BK audio pipeline module

def _kconfig_bool(key, enabled):
    if enabled:
        return "CONFIG_{}=y".format(key)
    return "# CONFIG_{} is not set".format(key)

def _bk_audio_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = ["# Audio override"]
    lines.append(_kconfig_bool("AUDIO", ctx.attr.audio))
    lines.append(_kconfig_bool("AUDIO_ADC", ctx.attr.audio_adc))
    lines.append(_kconfig_bool("AUDIO_DAC", ctx.attr.audio_dac))
    lines.append(_kconfig_bool("AUDIO_RING_BUFF", ctx.attr.audio_ring_buff))
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_ap_audio = rule(
    implementation = _bk_audio_impl,
    attrs = {
        "audio": attr.bool(mandatory = True, doc = "CONFIG_AUDIO"),
        "audio_adc": attr.bool(mandatory = True, doc = "CONFIG_AUDIO_ADC"),
        "audio_dac": attr.bool(mandatory = True, doc = "CONFIG_AUDIO_DAC"),
        "audio_ring_buff": attr.bool(mandatory = True, doc = "CONFIG_AUDIO_RING_BUFF"),
    },
    doc = "Enable audio pipeline (ADC/DAC/ring buffer)",
)