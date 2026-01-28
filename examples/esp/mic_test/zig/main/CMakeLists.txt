# Mic Test - Zig Version

# ESP lib path: use ESP_LIB_PATH env var (Bazel) or relative path (local dev)
if(DEFINED ENV{ESP_LIB_PATH})
    set(_ESP_LIB $ENV{ESP_LIB_PATH})
else()
    set(_ESP_LIB ${CMAKE_CURRENT_LIST_DIR}/../../../../../lib)
endif()

# Include mic.cmake for I2S TDM dependencies
include(${_ESP_LIB}/esp/src/mic/mic.cmake)

# Include I2C cmake for ES7210 communication
include(${_ESP_LIB}/esp/src/sal/i2c.cmake)

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
