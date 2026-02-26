# BK Kconfig Modules

BK7258 uses **override fragments** appended to an Armino base project config.
Each module below generates a small `.kconfig` fragment that enables a focused
feature, similar to ESP's `sdkconfig` modules.

## How to use

```python
load("//bazel/bk/kconfig:defs.bzl", "bk_config", "bk_uart", "bk_debug", "bk_at")

bk_uart(
    name = "uart",
    sys_print_dev = "uart",
    uart_print_port = 0,
    uart_print_baud_rate = 115200,
)

bk_debug(
    name = "debug",
    assert_halt = True,
    assert_reboot = False,
    dump_enable = True,
)

bk_at(
    name = "at",
    enable = False,
)

bk_config(
    name = "kconfig",
    modules = [":uart", ":debug", ":at"],
)
```

Pass the resulting `bk_config` to `bk_zig_app`:

```python
bk_zig_app(
    name = "app",
    ...
    kconfig_ap = ":kconfig",
)
```

## Available modules

- **bk_uart**: UART + system print device configuration
- **bk_uart_direct**: Convenience for UART0 direct print
- **bk_at**: Enable/disable AT server
- **bk_debug**: Assert + dump settings
- **bk_psram**: PSRAM enable + options
- **bk_pwm** / **bk_audio** / **bk_saradc** / **bk_timer** / **bk_ble** / **bk_aec**
- **bk_ap_freertos** / **bk_cp_freertos**
- **bk_ap_app** / **bk_cp_app**
- **bk_ap_crypto** / **bk_ap_lwip**

## Notes

- BK configs are **overrides** appended to the base project config.
- Keep fragments minimal: only set what you need.
- For advanced one-off options, use `bk_custom` with raw Kconfig lines.
