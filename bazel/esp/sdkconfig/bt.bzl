# ESP-IDF Bluetooth (Controller-only, VHCI mode)
# Component: bt

def _esp_bt_impl(ctx):
    """Generate BT controller sdkconfig fragment."""
    out = ctx.actions.declare_file(ctx.attr.name + ".sdkconfig")

    lines = []

    lines.append("# Bluetooth")
    lines.append("CONFIG_BT_ENABLED=y")

    # Host: disabled (controller-only, we use our own Zig host via VHCI)
    lines.append("CONFIG_BT_CONTROLLER_ONLY=y")

    # Controller: enabled
    lines.append("CONFIG_BT_CONTROLLER_ENABLED=y")

    # BLE mode only (no classic BT on ESP32-S3)
    lines.append("CONFIG_BT_CTRL_MODE_EFF=1")

    # HCI transport: VHCI (not UART)
    lines.append("CONFIG_BT_CTRL_HCI_MODE_VHCI=y")
    lines.append("CONFIG_BT_CTRL_HCI_TL_EFF=1")

    # BLE max activities (connections + advertising + scanning)
    lines.append("CONFIG_BT_CTRL_BLE_MAX_ACT={}".format(ctx.attr.ble_max_act))
    lines.append("CONFIG_BT_CTRL_BLE_MAX_ACT_EFF={}".format(ctx.attr.ble_max_act))

    # Controller task pinned to core 0
    lines.append("CONFIG_BT_CTRL_PINNED_TO_CORE=0")

    # Sleep mode: disabled (for throughput testing)
    lines.append("CONFIG_BT_CTRL_SLEEP_MODE_EFF=0")

    # Coexistence: disabled (no WiFi+BT coex needed for testing)
    lines.append("CONFIG_BT_CTRL_COEX_PHY_CODED_TX_RX_TLIM_DIS=y")
    lines.append("CONFIG_BT_CTRL_COEX_PHY_CODED_TX_RX_TLIM_EFF=0")

    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

esp_bt = rule(
    implementation = _esp_bt_impl,
    attrs = {
        "ble_max_act": attr.int(
            default = 6,
            doc = """CONFIG_BT_CTRL_BLE_MAX_ACT
            Maximum BLE activities (connections + advertising + scanning).
            Each activity uses ~1KB RAM.
            Typical: 6 (default), 10 (high)""",
        ),
    },
    doc = """Bluetooth controller configuration (VHCI mode, no host stack).""",
)

BT_ATTRS = {
    "bt": attr.label(
        allow_single_file = True,
        doc = "BT config from esp_bt rule",
    ),
}
