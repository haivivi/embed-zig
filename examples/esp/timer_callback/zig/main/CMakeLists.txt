# Timer Callback - Zig HAL v5

# ESP lib path: use ESP_LIB_PATH env var (Bazel) or relative path (local dev)
if(DEFINED ENV{ESP_LIB_PATH})
    set(_ESP_LIB $ENV{ESP_LIB_PATH})
else()
    set(_ESP_LIB ${CMAKE_CURRENT_LIST_DIR}/../../../../../lib)
endif()

# Include timer module CMake
include(${_ESP_LIB}/esp/src/timer/timer.cmake)

idf_component_register(
    SRCS "src/main.c" ${TIMER_C_SOURCES}
    INCLUDE_DIRS "."
    REQUIRES driver esp_timer led_strip
)

esp_zig_build(
    FORCE_LINK
        ${TIMER_FORCE_LINK}
        led_strip_refresh
        led_strip_new_rmt_device
)
