# I2S module CMake configuration
# Provides I2S bus abstraction (TDM + STD, full-duplex)
#
# Includes:
# - helper.c: Port-based unified API (STD/TDM duplex)
# - std_helper.c: Handle-based STD mode API (RX + TX)
# - tdm_helper.c: Handle-based TDM mode API (RX + TX)

set(I2S_C_SOURCES
    ${CMAKE_CURRENT_LIST_DIR}/helper.c
    ${CMAKE_CURRENT_LIST_DIR}/std_helper.c
    ${CMAKE_CURRENT_LIST_DIR}/tdm_helper.c
)

set(I2S_REQUIRES
    esp_driver_i2s
    esp_driver_gpio
    driver
)

set(I2S_FORCE_LINK
    i2s_helper_force_link
    # STD helper (handle-based)
    i2s_std_helper_force_link
    i2s_std_helper_init_rx
    i2s_std_helper_init_tx
    i2s_std_helper_deinit
    i2s_std_helper_enable
    i2s_std_helper_disable
    i2s_std_helper_read
    i2s_std_helper_write
    # TDM helper (handle-based)
    i2s_tdm_helper_init_rx
    i2s_tdm_helper_init_tx
    i2s_tdm_helper_get_tx_handle
    i2s_tdm_helper_deinit
    i2s_tdm_helper_enable
    i2s_tdm_helper_disable
    i2s_tdm_helper_read
)
