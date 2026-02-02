# ESP-IDF WiFi
# Component: esp_wifi

def _esp_wifi_impl(ctx):
    """Generate WiFi sdkconfig fragment."""
    out = ctx.actions.declare_file(ctx.attr.name + ".sdkconfig")
    
    lines = []
    
    lines.append("# WiFi")
    lines.append("CONFIG_ESP_WIFI_STATIC_RX_BUFFER_NUM={}".format(ctx.attr.static_rx_buffer_num))
    lines.append("CONFIG_ESP_WIFI_DYNAMIC_RX_BUFFER_NUM={}".format(ctx.attr.dynamic_rx_buffer_num))
    lines.append("CONFIG_ESP_WIFI_RX_BA_WIN={}".format(ctx.attr.rx_ba_win))
    lines.append("CONFIG_ESP_WIFI_TX_BA_WIN={}".format(ctx.attr.tx_ba_win))
    lines.append("CONFIG_ESP_WIFI_AMPDU_RX_ENABLED=y")
    lines.append("CONFIG_ESP_WIFI_AMPDU_TX_ENABLED=y")
    lines.append("CONFIG_ESP_WIFI_NVS_ENABLED=n")
    lines.append("CONFIG_ESP_WIFI_SOFTAP_SUPPORT=y")
    
    # Disable WPA3 SAE to avoid mbedTLS dependency
    lines.append("CONFIG_ESP_WIFI_ENABLE_WPA3_SAE=n")
    
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

esp_wifi = rule(
    implementation = _esp_wifi_impl,
    attrs = {
        "static_rx_buffer_num": attr.int(
            mandatory = True,
            doc = """CONFIG_ESP_WIFI_STATIC_RX_BUFFER_NUM
            静态 RX 缓冲区数量，启动时分配在内部 RAM
            越高吞吐量越好，但占用更多内存
            Typical: 8 (low memory), 16 (balanced)""",
        ),
        "dynamic_rx_buffer_num": attr.int(
            mandatory = True,
            doc = """CONFIG_ESP_WIFI_DYNAMIC_RX_BUFFER_NUM
            动态 RX 缓冲区上限，按需从堆分配（可用 PSRAM）
            越高越能处理突发流量
            Typical: 32 (normal), 64 (high throughput)""",
        ),
        "rx_ba_win": attr.int(
            mandatory = True,
            doc = """CONFIG_ESP_WIFI_RX_BA_WIN
            RX Block Ack 窗口大小，用于 AMPDU 聚合
            越高吞吐量越好
            Typical: 16 (normal), 32 (high throughput)""",
        ),
        "tx_ba_win": attr.int(
            mandatory = True,
            doc = """CONFIG_ESP_WIFI_TX_BA_WIN
            TX Block Ack 窗口大小，用于 AMPDU 聚合
            Typical: 6""",
        ),
    },
    doc = """WiFi 配置模块""",
)

WIFI_ATTRS = {
    "wifi": attr.label(
        allow_single_file = True,
        doc = "WiFi config from esp_wifi rule",
    ),
}
