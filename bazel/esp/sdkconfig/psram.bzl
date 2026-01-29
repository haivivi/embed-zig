# ESP-IDF PSRAM/SPIRAM
# Component: esp_psram

def _esp_psram_impl(ctx):
    """Generate PSRAM sdkconfig fragment."""
    out = ctx.actions.declare_file(ctx.attr.name + ".sdkconfig")
    
    lines = []
    lines.append("# PSRAM")
    
    chip = ctx.attr.chip
    if chip == "esp32s3":
        lines.append("CONFIG_ESP32S3_SPIRAM_SUPPORT=y")
    elif chip == "esp32s2":
        lines.append("CONFIG_ESP32S2_SPIRAM_SUPPORT=y")
    elif chip == "esp32":
        lines.append("CONFIG_ESP32_SPIRAM_SUPPORT=y")
    
    lines.append("CONFIG_SPIRAM=y")
    
    if ctx.attr.mode == "oct":
        lines.append("CONFIG_SPIRAM_MODE_OCT=y")
    else:
        lines.append("CONFIG_SPIRAM_MODE_QUAD=y")
    
    if ctx.attr.speed == "80m":
        lines.append("CONFIG_SPIRAM_SPEED_80M=y")
    else:
        lines.append("CONFIG_SPIRAM_SPEED_40M=y")
    
    lines.append("CONFIG_SPIRAM_TYPE_AUTO=y")
    lines.append("CONFIG_SPIRAM_BOOT_INIT=y")
    lines.append("CONFIG_SPIRAM_USE_MALLOC=y")
    lines.append("CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL=0")
    lines.append("CONFIG_SPIRAM_ALLOW_BSS_SEG_EXTERNAL_MEMORY=y")
    lines.append("CONFIG_SPIRAM_ALLOW_STACK_EXTERNAL_MEMORY=y")
    lines.append("CONFIG_SPIRAM_TRY_ALLOCATE_WIFI_LWIP=y")
    
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

esp_psram = rule(
    implementation = _esp_psram_impl,
    attrs = {
        "chip": attr.string(
            mandatory = True,
            doc = """目标芯片，用于选择正确的 SPIRAM_SUPPORT 配置
            Values: esp32, esp32s2, esp32s3""",
        ),
        "mode": attr.string(
            mandatory = True,
            doc = """CONFIG_SPIRAM_MODE
            PSRAM 接口模式
            oct: Octal SPI 8-bit (ESP32-S3 only, faster)
            quad: Quad SPI 4-bit (all chips)""",
        ),
        "speed": attr.string(
            mandatory = True,
            doc = """CONFIG_SPIRAM_SPEED
            PSRAM 时钟频率
            Values: 40m, 80m""",
        ),
    },
    doc = """PSRAM 外部内存配置""",
)
