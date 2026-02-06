# Microphone (AEC) module CMake configuration
# Defines required ESP-IDF components and force-link symbols for mic + AEC
#
# Note: I2S helpers are now in the i2s module (i2s/i2s.cmake)

# Include I2S module (provides TDM/STD helpers)
include(${CMAKE_CURRENT_LIST_DIR}/../i2s/i2s.cmake)

# Include SR module (provides AEC)
include(${CMAKE_CURRENT_LIST_DIR}/../sr/sr.cmake)

# Include runtime support (128-bit division etc.)
include(${CMAKE_CURRENT_LIST_DIR}/../runtime/runtime.cmake)

# C helper sources (I2S + SR + runtime)
set(MIC_C_SOURCES
    ${I2S_C_SOURCES}
    ${SR_C_SOURCES}
    ${RUNTIME_C_SOURCES}
)

# ESP-IDF components required
set(MIC_REQUIRES
    ${I2S_REQUIRES}
    ${SR_REQUIRES}
)

# Symbols to force-link
set(MIC_FORCE_LINK
    ${I2S_FORCE_LINK}
    ${SR_FORCE_LINK}
    ${RUNTIME_FORCE_LINK}
)
