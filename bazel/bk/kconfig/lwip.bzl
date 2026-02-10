"""BK7258 Kconfig: LWIP TCP optimization for throughput."""

def _bk_lwip_fast_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = [
        "# LWIP TCP optimization (based on Beken iperf reference config)",
        "CONFIG_LWIP_TCP_MSS=1460",
        "CONFIG_LWIP_TCP_WND=43800",
        "CONFIG_LWIP_TCP_SND_BUF=43800",
        "CONFIG_LWIP_TCP_SND_QUEUELEN=60",
        "CONFIG_LWIP_MEM_SIZE=112640",
        "CONFIG_LWIP_MEM_MAX_TX_SIZE=107008",
        "CONFIG_LWIP_MEM_MAX_RX_SIZE=107008",
        "CONFIG_LWIP_MEMP_NUM_TCP_SEG=80",
        "CONFIG_LWIP_MEMP_NUM_NETBUF=128",
        "CONFIG_LWIP_UDP_RECVMBOX_SIZE=128",
    ]
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_lwip_fast = rule(
    implementation = _bk_lwip_fast_impl,
    attrs = {},
    doc = "Optimize LWIP TCP for higher throughput (larger windows and buffers)",
)
