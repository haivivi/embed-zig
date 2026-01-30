# Main component - Pure Zig implementation
# No C code here! All C helpers are in lib/esp/src/

# Path to lib/esp/src and cmake
get_filename_component(_ESP_LIB "${CMAKE_CURRENT_SOURCE_DIR}/../../../../lib/esp/src" ABSOLUTE)
get_filename_component(_CMAKE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../cmake" ABSOLUTE)

# Include Zig install helper
include(${_CMAKE_DIR}/zig_install.cmake)

# Include C helper modules from lib/esp/src
include(${_ESP_LIB}/entry/entry.cmake)
include(${_ESP_LIB}/i2c/i2c.cmake)
include(${_ESP_LIB}/i2s/i2s.cmake)
include(${_ESP_LIB}/sr/sr.cmake)

# Register component with ESP-IDF
# SRCS only includes C files from lib/esp/src modules
idf_component_register(
    SRCS 
        ${ENTRY_C_SOURCES}
        ${I2C_C_SOURCES}
        ${I2S_C_SOURCES}
        ${SR_C_SOURCES}
    INCLUDE_DIRS "."
    REQUIRES driver esp_driver_i2s esp_driver_gpio esp_driver_i2c esp_timer freertos
    PRIV_REQUIRES esp-sr heap
)

# Build Zig code using esp_zig_build function
esp_zig_build(
    FORCE_LINK 
        app_main
        ${I2C_FORCE_LINK}
        ${I2S_FORCE_LINK}
        ${SR_FORCE_LINK}
)
