# Microphone (I2S TDM) module CMake configuration
# Defines required ESP-IDF components and force-link symbols for mic/I2S TDM

# C helper sources for I2S TDM
file(GLOB MIC_C_SOURCES "${CMAKE_CURRENT_LIST_DIR}/i2s_tdm_helper.c")

# ESP-IDF components required for I2S TDM microphone
set(MIC_REQUIRES
    esp_driver_i2s
    driver
)

# Symbols to force-link for I2S TDM functionality
set(MIC_FORCE_LINK
    i2s_tdm_helper_init_rx
    i2s_tdm_helper_deinit
    i2s_tdm_helper_enable
    i2s_tdm_helper_disable
    i2s_tdm_helper_read
)
