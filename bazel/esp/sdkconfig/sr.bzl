# ESP-SR (Speech Recognition) sdkconfig
# Component: esp-sr (from ESP-ADF)

def _esp_sr_impl(ctx):
    """Generate ESP-SR sdkconfig fragment."""
    out = ctx.actions.declare_file(ctx.attr.name + ".sdkconfig")
    
    lines = []
    lines.append("# ESP-SR")
    
    # AFE interface version
    if ctx.attr.afe_interface == "v1":
        lines.append("CONFIG_AFE_INTERFACE_V1=y")
    
    # Model partitions (optional)
    if ctx.attr.model_partition:
        lines.append('CONFIG_MODEL_IN_SPIFFS=y')
    
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

esp_sr = rule(
    implementation = _esp_sr_impl,
    attrs = {
        "afe_interface": attr.string(
            default = "v1",
            doc = """AFE interface version
            v1: Original interface (default)
            v2: New interface (experimental)""",
        ),
        "model_partition": attr.bool(
            default = False,
            doc = "Store models in SPIFFS partition",
        ),
    },
    doc = """ESP-SR speech recognition configuration.
    
    Configures the Audio Front End (AFE) and model storage for ESP-SR.
    """,
)
