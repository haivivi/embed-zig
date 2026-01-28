# GPIO Button - Zig HAL Version

# ESP lib path: use ESP_LIB_PATH env var (Bazel) or relative path (local dev)
if(DEFINED ENV{ESP_LIB_PATH})
    set(_ESP_LIB $ENV{ESP_LIB_PATH})
else()
    set(_ESP_LIB ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../lib)
endif()

# Include I2C helper for TCA9554 support (Korvo-2 V3)
include(${_ESP_LIB}/esp/src/sal/i2c.cmake)

# Board selection (default: esp32s3_devkit)
# Use: idf.py -DZIG_BOARD=korvo2_v3 build
if(NOT DEFINED ZIG_BOARD)
    set(ZIG_BOARD "esp32s3_devkit")
endif()
message(STATUS "[gpio_button] Board: ${ZIG_BOARD}")

idf_component_register(
    SRCS "src/main.c" ${I2C_C_SOURCES}
    INCLUDE_DIRS "."
    REQUIRES driver led_strip esp_driver_i2c
)

esp_zig_build(
    FORCE_LINK
        led_strip_refresh
        led_strip_new_rmt_device
        ${I2C_FORCE_LINK}
    ZIG_OPTIONS
        -Dboard=${ZIG_BOARD}
)
