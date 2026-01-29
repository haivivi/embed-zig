# ESP-IDF Core: chip, cpu, flash
# Components: esp_system, esptool_py

def _esp_core_impl(ctx):
    """Generate core sdkconfig fragment."""
    out = ctx.actions.declare_file(ctx.attr.name + ".sdkconfig")
    
    lines = []
    chip = ctx.attr.idf_target
    
    # Chip
    lines.append("# Chip")
    lines.append('CONFIG_IDF_TARGET="{}"'.format(chip))
    
    # CPU frequency
    lines.append("")
    lines.append("# CPU")
    chip_prefix = chip.upper().replace("-", "_")
    if chip in ["esp32", "esp32s2", "esp32s3"]:
        lines.append("CONFIG_{}_DEFAULT_CPU_FREQ_{}=y".format(chip_prefix, ctx.attr.cpu_freq_mhz))
        lines.append("CONFIG_{}_DEFAULT_CPU_FREQ_MHZ={}".format(chip_prefix, ctx.attr.cpu_freq_mhz))
    else:
        lines.append("CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ_{}=y".format(ctx.attr.cpu_freq_mhz))
        lines.append("CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ={}".format(ctx.attr.cpu_freq_mhz))
    
    # Flash
    lines.append("")
    lines.append("# Flash")
    lines.append('CONFIG_ESPTOOLPY_FLASHSIZE="{}MB"'.format(ctx.attr.flash_size_mb))
    lines.append("CONFIG_ESPTOOLPY_FLASHSIZE_{}MB=y".format(ctx.attr.flash_size_mb))
    lines.append("CONFIG_ESPTOOLPY_FLASHFREQ_{}=y".format(ctx.attr.flash_freq.upper()))
    lines.append('CONFIG_ESPTOOLPY_FLASHFREQ="{}"'.format(ctx.attr.flash_freq))
    lines.append("CONFIG_ESPTOOLPY_FLASHMODE_{}=y".format(ctx.attr.flash_mode.upper()))
    mode_str = "dio" if ctx.attr.flash_mode == "qio" else ctx.attr.flash_mode
    lines.append('CONFIG_ESPTOOLPY_FLASHMODE="{}"'.format(mode_str))
    lines.append("CONFIG_ESPTOOLPY_MONITOR_BAUD=115200")
    
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

esp_core = rule(
    implementation = _esp_core_impl,
    attrs = {
        "idf_target": attr.string(
            mandatory = True,
            doc = """CONFIG_IDF_TARGET
            目标芯片型号
            Values: esp32, esp32s2, esp32s3, esp32c3, esp32c6, esp32h2""",
        ),
        "cpu_freq_mhz": attr.int(
            mandatory = True,
            doc = """CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ
            CPU 运行频率（MHz）
            ESP32/S2/S3: 80, 160, 240
            ESP32-C3/C6: 80, 160""",
        ),
        "flash_size_mb": attr.int(
            mandatory = True,
            doc = """CONFIG_ESPTOOLPY_FLASHSIZE
            Flash 存储大小（MB）
            Values: 2, 4, 8, 16, 32""",
        ),
        "flash_mode": attr.string(
            mandatory = True,
            doc = """CONFIG_ESPTOOLPY_FLASHMODE
            Flash SPI 模式
            qio: Quad I/O (fastest)
            dio: Dual I/O
            qout: Quad Output
            dout: Dual Output""",
        ),
        "flash_freq": attr.string(
            mandatory = True,
            doc = """CONFIG_ESPTOOLPY_FLASHFREQ
            Flash SPI 频率
            Values: 20m, 40m, 80m, 120m""",
        ),
    },
    doc = """芯片核心配置：芯片型号、CPU、Flash""",
)
