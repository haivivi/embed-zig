# ESP-IDF LWIP
# Component: lwip

def _esp_lwip_impl(ctx):
    """Generate LWIP sdkconfig fragment."""
    out = ctx.actions.declare_file(ctx.attr.name + ".sdkconfig")
    
    lines = []
    
    # LWIP task
    lines.append("# LWIP")
    lines.append("CONFIG_LWIP_TCPIP_TASK_STACK_SIZE={}".format(ctx.attr.tcpip_task_stack_size))
    lines.append("CONFIG_LWIP_MAX_SOCKETS={}".format(ctx.attr.max_sockets))
    lines.append("CONFIG_LWIP_MAX_ACTIVE_TCP={}".format(ctx.attr.max_active_tcp))
    lines.append("CONFIG_LWIP_MAX_LISTENING_TCP={}".format(ctx.attr.max_active_tcp))
    
    # TCP
    lines.append("")
    lines.append("# TCP")
    lines.append("CONFIG_LWIP_TCP_SND_BUF_DEFAULT={}".format(ctx.attr.tcp_snd_buf_default))
    lines.append("CONFIG_LWIP_TCP_WND_DEFAULT={}".format(ctx.attr.tcp_wnd_default))
    lines.append("CONFIG_LWIP_TCP_RECVMBOX_SIZE={}".format(ctx.attr.tcp_recvmbox_size))
    lines.append("CONFIG_LWIP_TCP_SACK_OUT=y")
    lines.append("CONFIG_LWIP_TCP_QUEUE_OOSEQ=y")
    lines.append("CONFIG_LWIP_TCP_OVERSIZE_MSS=y")
    lines.append("CONFIG_LWIP_TCP_HIGH_SPEED_RETRANSMISSION=y")
    
    # DNS
    lines.append("")
    lines.append("# DNS")
    lines.append("CONFIG_LWIP_DNS_MAX_SERVERS=3")
    
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

esp_lwip = rule(
    implementation = _esp_lwip_impl,
    attrs = {
        "tcpip_task_stack_size": attr.int(
            mandatory = True,
            doc = """CONFIG_LWIP_TCPIP_TASK_STACK_SIZE
            TCP/IP 协议栈任务的栈大小（字节）
            Typical: 3072 (minimal), 8192 (recommended)""",
        ),
        "max_sockets": attr.int(
            mandatory = True,
            doc = """CONFIG_LWIP_MAX_SOCKETS
            最大 socket 数量
            Typical: 10""",
        ),
        "max_active_tcp": attr.int(
            mandatory = True,
            doc = """CONFIG_LWIP_MAX_ACTIVE_TCP
            最大同时 TCP 连接数
            Typical: 8 (normal), 16 (server)""",
        ),
        "tcp_snd_buf_default": attr.int(
            mandatory = True,
            doc = """CONFIG_LWIP_TCP_SND_BUF_DEFAULT
            TCP 发送缓冲区大小（字节）
            Typical: 5744 (minimal), 65535 (max throughput)""",
        ),
        "tcp_wnd_default": attr.int(
            mandatory = True,
            doc = """CONFIG_LWIP_TCP_WND_DEFAULT
            TCP 接收窗口大小（字节）
            Typical: 5744 (minimal), 65535 (max throughput)""",
        ),
        "tcp_recvmbox_size": attr.int(
            mandatory = True,
            doc = """CONFIG_LWIP_TCP_RECVMBOX_SIZE
            TCP 接收邮箱队列深度
            Typical: 6 (minimal), 64 (high throughput)""",
        ),
    },
    doc = """LWIP 网络栈配置""",
)

LWIP_ATTRS = {
    "lwip": attr.label(
        allow_single_file = True,
        doc = "LWIP config from esp_lwip rule",
    ),
}
