/**
 * I2S TDM Helper for Zig
 *
 * Provides C helper functions for I2S TDM configuration since
 * the ESP-IDF structs contain complex anonymous types that
 * Zig's cImport cannot handle directly.
 */

#include "driver/i2s_tdm.h"
#include "driver/i2s_common.h"
#include "driver/gpio.h"
#include "esp_log.h"

static const char *TAG = "i2s_tdm_helper";

/**
 * Initialize I2S TDM RX channel for microphone input
 *
 * @param port I2S port number (0 or 1)
 * @param sample_rate Sample rate in Hz
 * @param channels Number of channels (1-4)
 * @param bits_per_sample Bits per sample (16, 24, or 32)
 * @param bclk_pin Bit clock GPIO pin
 * @param ws_pin Word select (LRCK) GPIO pin
 * @param din_pin Data input GPIO pin
 * @param mclk_pin Master clock GPIO pin (-1 if unused)
 * @param[out] rx_handle Pointer to store the RX channel handle
 * @return ESP_OK on success, error code otherwise
 */
esp_err_t i2s_tdm_helper_init_rx(
    int port,
    uint32_t sample_rate,
    int channels,
    int bits_per_sample,
    int bclk_pin,
    int ws_pin,
    int din_pin,
    int mclk_pin,
    i2s_chan_handle_t *rx_handle
) {
    ESP_LOGI(TAG, "Init I2S TDM RX: port=%d, rate=%lu, ch=%d, bits=%d",
             port, sample_rate, channels, bits_per_sample);
    ESP_LOGI(TAG, "  Pins: BCLK=%d, WS=%d, DIN=%d, MCLK=%d",
             bclk_pin, ws_pin, din_pin, mclk_pin);

    // Channel configuration
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(port, I2S_ROLE_MASTER);
    // DMA buffer: 6 descriptors * 240 frames = 1440 frames total (~90ms at 16kHz)
    // This provides enough buffering to handle OS scheduling jitter
    chan_cfg.dma_desc_num = 6;    // Number of DMA descriptors (buffers)
    chan_cfg.dma_frame_num = 240; // Frames per descriptor (~15ms at 16kHz)

    // Allocate RX channel only
    esp_err_t ret = i2s_new_channel(&chan_cfg, NULL, rx_handle);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to allocate I2S channel: %s", esp_err_to_name(ret));
        return ret;
    }

    // Build slot mask
    i2s_tdm_slot_mask_t slot_mask = I2S_TDM_SLOT0;
    if (channels >= 2) slot_mask |= I2S_TDM_SLOT1;
    if (channels >= 3) slot_mask |= I2S_TDM_SLOT2;
    if (channels >= 4) slot_mask |= I2S_TDM_SLOT3;

    // Data bit width
    i2s_data_bit_width_t data_bit_width = I2S_DATA_BIT_WIDTH_16BIT;
    if (bits_per_sample == 24) data_bit_width = I2S_DATA_BIT_WIDTH_24BIT;
    else if (bits_per_sample == 32) data_bit_width = I2S_DATA_BIT_WIDTH_32BIT;

    // TDM slot configuration (Philips format for ES7210)
    i2s_tdm_slot_config_t slot_cfg = I2S_TDM_PHILIPS_SLOT_DEFAULT_CONFIG(
        data_bit_width,
        I2S_SLOT_MODE_STEREO,
        slot_mask
    );

    // TDM clock configuration
    i2s_tdm_clk_config_t clk_cfg = I2S_TDM_CLK_DEFAULT_CONFIG(sample_rate);

    // GPIO configuration
    i2s_tdm_gpio_config_t gpio_cfg = {
        .bclk = bclk_pin,
        .ws = ws_pin,
        .din = din_pin,
        .dout = GPIO_NUM_NC,
        .mclk = (mclk_pin >= 0) ? mclk_pin : GPIO_NUM_NC,
    };

    // TDM configuration
    i2s_tdm_config_t tdm_cfg = {
        .slot_cfg = slot_cfg,
        .clk_cfg = clk_cfg,
        .gpio_cfg = gpio_cfg,
    };

    ret = i2s_channel_init_tdm_mode(*rx_handle, &tdm_cfg);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to init TDM mode: %s", esp_err_to_name(ret));
        i2s_del_channel(*rx_handle);
        *rx_handle = NULL;
        return ret;
    }

    ESP_LOGI(TAG, "I2S TDM RX initialized successfully");
    return ESP_OK;
}

/**
 * Deinitialize I2S TDM channel
 */
esp_err_t i2s_tdm_helper_deinit(i2s_chan_handle_t handle) {
    if (handle == NULL) return ESP_OK;
    return i2s_del_channel(handle);
}

/**
 * Enable I2S channel
 */
esp_err_t i2s_tdm_helper_enable(i2s_chan_handle_t handle) {
    if (handle == NULL) return ESP_ERR_INVALID_ARG;
    return i2s_channel_enable(handle);
}

/**
 * Disable I2S channel
 */
esp_err_t i2s_tdm_helper_disable(i2s_chan_handle_t handle) {
    if (handle == NULL) return ESP_ERR_INVALID_ARG;
    return i2s_channel_disable(handle);
}

/**
 * Read from I2S channel
 */
esp_err_t i2s_tdm_helper_read(
    i2s_chan_handle_t handle,
    void *buffer,
    size_t buffer_size,
    size_t *bytes_read,
    uint32_t timeout_ms
) {
    if (handle == NULL) return ESP_ERR_INVALID_ARG;
    return i2s_channel_read(handle, buffer, buffer_size, bytes_read, timeout_ms);
}
