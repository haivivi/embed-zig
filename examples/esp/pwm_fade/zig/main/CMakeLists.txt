# PWM Fade - Zig Version

# Board selection (default: esp32s3_devkit)
if(NOT DEFINED ZIG_BOARD)
    set(ZIG_BOARD "esp32s3_devkit")
endif()
message(STATUS "[pwm_fade] Board: ${ZIG_BOARD}")

# Include LEDC module CMake (path adjusted for Bazel build)
include(${CMAKE_CURRENT_LIST_DIR}/../../../../../lib/esp/src/ledc/ledc.cmake)

idf_component_register(
    SRCS "src/main.c" ${LEDC_C_SOURCES}
    INCLUDE_DIRS "."
    REQUIRES driver
)

esp_zig_build(
    FORCE_LINK ${LEDC_FORCE_LINK}
    ZIG_OPTIONS -Dboard=${ZIG_BOARD}
)
