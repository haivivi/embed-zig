# BK7258 Kconfig: AP LWIP configuration

def _bk_ap_lwip_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")

    lines = [
        "# AP LWIP configuration",
        "CONFIG_LWIP_TCP_MSS={}".format(ctx.attr.tcp_mss),
        "CONFIG_LWIP_TCP_WND={}".format(ctx.attr.tcp_wnd),
        "CONFIG_LWIP_TCP_SND_BUF={}".format(ctx.attr.tcp_snd_buf),
        "CONFIG_LWIP_TCP_SND_QUEUELEN={}".format(ctx.attr.tcp_snd_queuelen),
        "CONFIG_LWIP_MEM_SIZE={}".format(ctx.attr.mem_size),
        "CONFIG_LWIP_MEM_MAX_TX_SIZE={}".format(ctx.attr.mem_max_tx_size),
        "CONFIG_LWIP_MEM_MAX_RX_SIZE={}".format(ctx.attr.mem_max_rx_size),
        "CONFIG_LWIP_MEMP_NUM_TCP_SEG={}".format(ctx.attr.memp_num_tcp_seg),
        "CONFIG_LWIP_MEMP_NUM_NETBUF={}".format(ctx.attr.memp_num_netbuf),
        "CONFIG_LWIP_UDP_RECVMBOX_SIZE={}".format(ctx.attr.udp_recvmbox_size),
    ]

    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_ap_lwip = rule(
    implementation = _bk_ap_lwip_impl,
    attrs = {
        "tcp_mss": attr.int(mandatory = True, doc = "CONFIG_LWIP_TCP_MSS"),
        "tcp_wnd": attr.int(mandatory = True, doc = "CONFIG_LWIP_TCP_WND"),
        "tcp_snd_buf": attr.int(mandatory = True, doc = "CONFIG_LWIP_TCP_SND_BUF"),
        "tcp_snd_queuelen": attr.int(mandatory = True, doc = "CONFIG_LWIP_TCP_SND_QUEUELEN"),
        "mem_size": attr.int(mandatory = True, doc = "CONFIG_LWIP_MEM_SIZE"),
        "mem_max_tx_size": attr.int(mandatory = True, doc = "CONFIG_LWIP_MEM_MAX_TX_SIZE"),
        "mem_max_rx_size": attr.int(mandatory = True, doc = "CONFIG_LWIP_MEM_MAX_RX_SIZE"),
        "memp_num_tcp_seg": attr.int(mandatory = True, doc = "CONFIG_LWIP_MEMP_NUM_TCP_SEG"),
        "memp_num_netbuf": attr.int(mandatory = True, doc = "CONFIG_LWIP_MEMP_NUM_NETBUF"),
        "udp_recvmbox_size": attr.int(mandatory = True, doc = "CONFIG_LWIP_UDP_RECVMBOX_SIZE"),
    },
    doc = "AP LWIP configuration (explicit, no presets)",
)
