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
    # Use CAPS_ALLOC mode: malloc() uses internal RAM only,
    # PSRAM only via heap_caps_malloc(..., MALLOC_CAP_SPIRAM)
    lines.append("CONFIG_SPIRAM_USE_CAPS_ALLOC=y")
    # Disable external BSS - can cause BSS init issues
    # lines.append("CONFIG_SPIRAM_ALLOW_BSS_SEG_EXTERNAL_MEMORY=y")
    
    # XIP from PSRAM - allows PSRAM access during flash operations
    # Required for WiFi apps using PSRAM task stack
    if ctx.attr.xip_from_psram:
        lines.append("")
        lines.append("# XIP from PSRAM (execute in place)")
        lines.append("CONFIG_SPIRAM_XIP_FROM_PSRAM=y")
        lines.append("CONFIG_SPIRAM_FETCH_INSTRUCTIONS=y")
        lines.append("CONFIG_SPIRAM_RODATA=y")
        lines.append("CONFIG_SPIRAM_FLASH_LOAD_TO_PSRAM=y")
    
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
        "xip_from_psram": attr.bool(
            default = False,
            doc = """CONFIG_SPIRAM_XIP_FROM_PSRAM
            启用从 PSRAM 执行代码 (XiP)
            启用后，代码和只读数据会从 flash 复制到 PSRAM
            这允许在 flash 操作期间仍能访问 PSRAM
            对于 WiFi 应用使用 PSRAM 栈是必需的
            注意：会增加启动时间和 PSRAM 占用""",
        ),
    },
    doc = """PSRAM 外部内存配置""",
)
