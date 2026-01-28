# Mic Test - Zig Version

# Set the path to lib/esp/src for cmake includes
set(_ESP_PKG "${CMAKE_CURRENT_LIST_DIR}/../../../../../lib/esp/src")

# Include mic.cmake for I2S TDM dependencies
include(${_ESP_PKG}/mic/mic.cmake)

# Include I2C cmake for ES7210 communication
include(${_ESP_PKG}/sal/i2c.cmake)

idf_component_register(
    SRCS "src/main.c" ${I2C_C_SOURCES} ${MIC_C_SOURCES}
    INCLUDE_DIRS "."
    REQUIRES driver ${MIC_REQUIRES} esp_driver_gpio
)

esp_zig_build(
    FORCE_LINK
        ${MIC_FORCE_LINK}
        ${I2C_FORCE_LINK}
)
