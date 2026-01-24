# Timer Callback - Zig Version

# Include timer module CMake
include(${CMAKE_CURRENT_LIST_DIR}/../../../../esp/src/timer/timer.cmake)

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
