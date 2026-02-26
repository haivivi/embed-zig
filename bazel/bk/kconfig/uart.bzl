# BK UART / Print configuration modules

def _kconfig_bool(key, enabled):
    if enabled:
        return "CONFIG_{}=y".format(key)
    return "# CONFIG_{} is not set".format(key)

def _bk_uart_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")

    lines = ["# UART"]

    lines.append(_kconfig_bool("UART0", ctx.attr.enable_uart0))
    lines.append(_kconfig_bool("UART1", ctx.attr.enable_uart1))
    lines.append(_kconfig_bool("UART2", ctx.attr.enable_uart2))

    if ctx.attr.printf_buf_size > 0:
        lines.append("CONFIG_PRINTF_BUF_SIZE={}".format(ctx.attr.printf_buf_size))

    if ctx.attr.uart_print_port >= 0:
        lines.append("CONFIG_UART_PRINT_PORT={}".format(ctx.attr.uart_print_port))

    if ctx.attr.uart_print_baud_rate > 0:
        lines.append("CONFIG_UART_PRINT_BAUD_RATE={}".format(ctx.attr.uart_print_baud_rate))

    if ctx.attr.sys_print_dev == "uart":
        lines.append("CONFIG_SYS_PRINT_DEV_UART=y")
        lines.append("# CONFIG_SYS_PRINT_DEV_MAILBOX is not set")
        lines.append("# CONFIG_SYS_PRINT_DEV_NULL is not set")
    elif ctx.attr.sys_print_dev == "mailbox":
        lines.append("# CONFIG_SYS_PRINT_DEV_UART is not set")
        lines.append("CONFIG_SYS_PRINT_DEV_MAILBOX=y")
        lines.append("# CONFIG_SYS_PRINT_DEV_NULL is not set")
    elif ctx.attr.sys_print_dev == "null":
        lines.append("# CONFIG_SYS_PRINT_DEV_UART is not set")
        lines.append("# CONFIG_SYS_PRINT_DEV_MAILBOX is not set")
        lines.append("CONFIG_SYS_PRINT_DEV_NULL=y")
    else:
        fail("bk_uart: sys_print_dev must be one of: uart, mailbox, null")

    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_ap_uart = rule(
    implementation = _bk_uart_impl,
    attrs = {
        "enable_uart0": attr.bool(
            default = True,
            doc = "Enable UART0 driver",
        ),
        "enable_uart1": attr.bool(
            default = True,
            doc = "Enable UART1 driver",
        ),
        "enable_uart2": attr.bool(
            default = True,
            doc = "Enable UART2 driver",
        ),
        "uart_print_port": attr.int(
            default = 0,
            doc = "CONFIG_UART_PRINT_PORT (0=UART0, 1=UART1, 2=UART2)",
        ),
        "uart_print_baud_rate": attr.int(
            default = 115200,
            doc = "CONFIG_UART_PRINT_BAUD_RATE",
        ),
        "printf_buf_size": attr.int(
            default = 256,
            doc = "CONFIG_PRINTF_BUF_SIZE (set -1 to skip override)",
        ),
        "sys_print_dev": attr.string(
            default = "uart",
            doc = "System print device: uart | mailbox | null",
        ),
    },
    doc = "Configure UART drivers and system print device.",
)

def _bk_uart_direct_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = [
        "# UART direct print — AP logs visible on UART0",
        "CONFIG_UART0=y",
        "CONFIG_UART1=y",
        "CONFIG_UART2=y",
        "CONFIG_UART_PRINT_PORT=0",
        "CONFIG_UART_PRINT_BAUD_RATE=115200",
        "CONFIG_PRINTF_BUF_SIZE=256",
        "CONFIG_SYS_PRINT_DEV_UART=y",
        "# CONFIG_SYS_PRINT_DEV_MAILBOX is not set",
        "# CONFIG_SYS_PRINT_DEV_NULL is not set",
    ]
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_ap_uart_direct = rule(
    implementation = _bk_uart_direct_impl,
    attrs = {},
    doc = "AP logs direct to UART0 (required for serial monitoring)",
)
