"""ESP32 build settings.

Usage:
    bazel build //target:app --//bazel/esp:board=my_board
    bazel build //target:app --//bazel/esp:board=my_board --//bazel/esp:chip=esp32c3
    bazel run //target:flash --//bazel/esp:port=/dev/ttyUSB0

Options:
    --//bazel/esp:board   Board name passed to Zig (-Dboard=xxx)
    --//bazel/esp:chip    ESP chip type for esptool (esp32, esp32s2, esp32s3, esp32c3, etc.)
    --//bazel/esp:port    Serial port (auto-detect if not specified)
    --//bazel/esp:baud    Flash baud rate (default: 460800)
"""

# Defaults
DEFAULT_BOARD = "esp32s3_devkit"
DEFAULT_CHIP = "esp32s3"
