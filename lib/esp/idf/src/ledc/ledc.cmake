# LEDC module CMake configuration
# Defines C sources and force-link symbols for LEDC PWM

set(LEDC_C_SOURCES
    "${CMAKE_CURRENT_LIST_DIR}/helper.c"
)

set(LEDC_FORCE_LINK
    ledc_init_simple
)
