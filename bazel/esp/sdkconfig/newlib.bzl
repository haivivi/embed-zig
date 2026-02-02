# ESP-IDF Newlib Configuration
# Component: newlib

def _esp_newlib_impl(ctx):
    """Generate newlib sdkconfig fragment."""
    out = ctx.actions.declare_file(ctx.attr.name + ".sdkconfig")
    
    lines = []
    lines.append("# Newlib")
    
    # Nano format (saves ~20KB but no 64-bit int / C99 support)
    if ctx.attr.nano_format:
        lines.append("CONFIG_NEWLIB_NANO_FORMAT=y")
    else:
        lines.append("CONFIG_NEWLIB_NANO_FORMAT=n")
    
    # Stdout line ending
    endings = {"crlf": "CRLF", "lf": "LF", "cr": "CR"}
    stdout_end = endings.get(ctx.attr.stdout_line_ending, "CRLF")
    lines.append("CONFIG_NEWLIB_STDOUT_LINE_ENDING_{}=y".format(stdout_end))
    
    # Stdin line ending
    stdin_end = endings.get(ctx.attr.stdin_line_ending, "CR")
    lines.append("CONFIG_NEWLIB_STDIN_LINE_ENDING_{}=y".format(stdin_end))
    
    # Time syscall
    time_opts = {
        "rtc_hrt": "RTC_HRT",   # RTC + high-res timer (default, best)
        "rtc": "RTC",           # RTC only (deep sleep ok, 6.6us resolution)
        "hrt": "HRT",           # High-res only (no deep sleep)
        "none": "NONE",         # Disabled
    }
    time_cfg = time_opts.get(ctx.attr.time_syscall, "RTC_HRT")
    lines.append("CONFIG_NEWLIB_TIME_SYSCALL_USE_{}=y".format(time_cfg))
    
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

esp_newlib = rule(
    implementation = _esp_newlib_impl,
    attrs = {
        "nano_format": attr.bool(
            default = False,
            doc = """CONFIG_NEWLIB_NANO_FORMAT
            使用 nano printf/scanf，节省 ~20KB
            限制：不支持 64 位整数格式和 C99 特性""",
        ),
        "stdout_line_ending": attr.string(
            default = "crlf",
            doc = """CONFIG_NEWLIB_STDOUT_LINE_ENDING
            UART 输出行尾格式
            Values: crlf, lf, cr""",
        ),
        "stdin_line_ending": attr.string(
            default = "cr",
            doc = """CONFIG_NEWLIB_STDIN_LINE_ENDING
            UART 输入行尾格式
            Values: crlf, lf, cr""",
        ),
        "time_syscall": attr.string(
            default = "rtc_hrt",
            doc = """CONFIG_NEWLIB_TIME_SYSCALL
            gettimeofday 使用的定时器
            rtc_hrt: RTC + 高精度定时器（推荐，支持深度睡眠）
            rtc: 仅 RTC（深度睡眠 ok，6.6us 精度）
            hrt: 仅高精度定时器（不支持深度睡眠）
            none: 禁用""",
        ),
    },
    doc = """Newlib C 库配置""",
)
