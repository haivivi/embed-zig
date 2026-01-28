"""ESP32 build settings.

Usage:
    bazel build //target:app --//bazel/esp:board=my_board
    bazel build //target:app --//bazel/esp:board=my_board --//bazel/esp:chip=esp32c3
    bazel run //target:flash --//bazel/esp:port=/dev/ttyUSB0

Options:
    --//bazel/esp:board         Board name passed to Zig (-Dboard=xxx)
    --//bazel/esp:chip          ESP chip type for esptool (esp32, esp32s2, esp32s3, esp32c3, etc.)
    --//bazel/esp:port          Serial port (auto-detect if not specified)
    --//bazel/esp:baud          Flash baud rate (default: 460800)
    --//bazel/esp:wifi_ssid     WiFi SSID (overrides CONFIG_WIFI_SSID)
    --//bazel/esp:wifi_password WiFi password (overrides CONFIG_WIFI_PASSWORD)
    --//bazel/esp:test_server_ip  Test server IP (for http_speed_test)
"""

# Defaults
DEFAULT_BOARD = "esp32s3_devkit"
DEFAULT_CHIP = "esp32s3"
# Note: Default WiFi credentials are for a public development network, not a security concern
DEFAULT_WIFI_SSID = "HAIVIVI-MFG"
DEFAULT_WIFI_PASSWORD = "!haivivi"
DEFAULT_TEST_SERVER_IP = ""