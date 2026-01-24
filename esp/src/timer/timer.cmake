# Timer module CMake configuration
# Defines C sources and force-link symbols for GPTimer

set(TIMER_C_SOURCES
    "${CMAKE_CURRENT_LIST_DIR}/helper.c"
)

set(TIMER_FORCE_LINK
    gptimer_new_timer_simple
)
