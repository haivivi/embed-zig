# PWM Fade - Zig Version

# Include LEDC module CMake
include(${CMAKE_CURRENT_LIST_DIR}/../../../../../lib/esp/src/ledc/ledc.cmake)

idf_component_register(
    SRCS "src/main.c" ${LEDC_C_SOURCES}
    INCLUDE_DIRS "."
    REQUIRES driver
)

esp_zig_build(
    FORCE_LINK ${LEDC_FORCE_LINK}
)
