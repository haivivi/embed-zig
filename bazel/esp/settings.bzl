"""ESP32 build settings.

Usage:
    bazel build //target:app --//bazel:board=my_board
    bazel run //target:flash --//bazel:port=/dev/ttyUSB0

Options:
    --//bazel:board             Board name passed to Zig (-Dboard=xxx)
    --//bazel:port              Serial port (auto-detect if not specified)
    --//bazel:baud              Flash baud rate (default: 460800)

Environment variables (via env file):
    WIFI_SSID, WIFI_PASSWORD, TEST_SERVER_IP, TEST_SERVER_PORT
"""

# Defaults
DEFAULT_BOARD = "esp32s3_devkit"
DEFAULT_CHIP = "esp32s3"
