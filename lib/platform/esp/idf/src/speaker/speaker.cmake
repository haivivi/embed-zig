# Speaker module CMake configuration
# Defines required ESP-IDF components and force-link symbols for speaker
#
# Note: I2S helpers are now in the i2s module (i2s/i2s.cmake)

# Include I2S module (provides STD/TDM helpers)
include(${CMAKE_CURRENT_LIST_DIR}/../i2s/i2s.cmake)

# C helper sources (from I2S module)
set(SPEAKER_C_SOURCES
    ${I2S_C_SOURCES}
)

# ESP-IDF components required
set(SPEAKER_REQUIRES
    ${I2S_REQUIRES}
)

# Symbols to force-link
set(SPEAKER_FORCE_LINK
    ${I2S_FORCE_LINK}
)
