# BK7258 Bluetooth configuration (AP core)
# Matches esp bt.bzl pattern

def _kconfig_bool(key, enabled):
    if enabled:
        return "CONFIG_{}=y".format(key)
    return "# CONFIG_{} is not set".format(key)

def _bk_ap_bt_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = ["# Bluetooth"]

    if ctx.attr.enabled:
        lines.append("CONFIG_BLE=y")
        lines.append("CONFIG_BLUETOOTH_AP=y")
        lines.append(_kconfig_bool("BT", ctx.attr.classic_bt))
        lines.append(_kconfig_bool("BLUETOOTH_HOST_ONLY", ctx.attr.host_only))
        lines.append(_kconfig_bool("BLUETOOTH_AUTO_ENABLE", ctx.attr.auto_enable))
        lines.append(_kconfig_bool("BLUETOOTH_SUPPORT_IPC", ctx.attr.support_ipc))
        lines.append(_kconfig_bool("BLUETOOTH_BLE_DISCOVER_AUTO", ctx.attr.ble_discover_auto))
    else:
        lines.append("# CONFIG_BLE is not set")
        lines.append("# CONFIG_BLUETOOTH_AP is not set")
        lines.append("# CONFIG_BT is not set")

    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_ap_bt = rule(
    implementation = _bk_ap_bt_impl,
    attrs = {
        "enabled": attr.bool(
            mandatory = True,
            doc = "Enable BLE stack on AP core (CONFIG_BLE + CONFIG_BLUETOOTH_AP)",
        ),
        "classic_bt": attr.bool(
            default = False,
            doc = "CONFIG_BT — enable classic Bluetooth (BR/EDR). Usually False for BLE-only.",
        ),
        "host_only": attr.bool(
            default = True,
            doc = "CONFIG_BLUETOOTH_HOST_ONLY — host stack only (controller on CP core).",
        ),
        "auto_enable": attr.bool(
            default = True,
            doc = "CONFIG_BLUETOOTH_AUTO_ENABLE — auto-init BT stack at boot.",
        ),
        "support_ipc": attr.bool(
            default = True,
            doc = "CONFIG_BLUETOOTH_SUPPORT_IPC — AP/CP inter-core BT communication.",
        ),
        "ble_discover_auto": attr.bool(
            default = True,
            doc = "CONFIG_BLUETOOTH_BLE_DISCOVER_AUTO — auto BLE service discovery.",
        ),
    },
    doc = """Bluetooth configuration for AP core.
    BK7258 runs BT controller on CP, host on AP. This configures the AP side.""",
)
