/**
 * I2S STD Helper for Zig
 *
 * Provides C helper functions for I2S Standard mode configuration since
 * the ESP-IDF structs contain complex anonymous types that
 * Zig's cImport cannot handle directly.
 *
 * Uses I2S Standard mode (Philips format) for codecs like ES8311 (DAC) and ES7210 (ADC).
 * Supports both RX (microphone input) and TX (speaker output).
 */

#include "driver/i2s_std.h"
#include "driver/i2s_common.h"
#include "driver/gpio.h"
#include "esp_log.h"

static const char *TAG = "i2s_std_helper";

/**
 * Initialize I2S STD RX channel for microphone input
 *
 * @param port I2S port number (0 or 1)
 * @param sample_rate Sample rate in Hz
 * @param bits_per_sample Bits per sample (16, 24, or 32)
 * @param bclk_pin Bit clock GPIO pin
 * @param ws_pin Word select (LRCK) GPIO pin
 * @param din_pin Data input GPIO pin
 * @param mclk_pin Master clock GPIO pin (-1 if unused)
 * @param[out] rx_handle Pointer to store the RX channel handle
 * @return ESP_OK on success, error code otherwise
 */
esp_err_t i2s_std_helper_init_rx(
    int port,
    uint32_t sample_rate,
    int bits_per_sample,
    int bclk_pin,
    int ws_pin,
    int din_pin,
    int mclk_pin,
    i2s_chan_handle_t *rx_handle
) {
    ESP_LOGI(TAG, "Init I2S STD RX: port=%d, rate=%lu, bits=%d",
             port, sample_rate, bits_per_sample);
    ESP_LOGI(TAG, "  Pins: BCLK=%d, WS=%d, DIN=%d, MCLK=%d",
             bclk_pin, ws_pin, din_pin, mclk_pin);

    // Channel configuration
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(port, I2S_ROLE_MASTER);
    // DMA buffer configuration for smooth audio capture
    chan_cfg.dma_desc_num = 6;    // Number of DMA descriptors (buffers)
    chan_cfg.dma_frame_num = 240; // Frames per descriptor (~15ms at 16kHz)

    // Allocate RX channel only
    esp_err_t ret = i2s_new_channel(&chan_cfg, NULL, rx_handle);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to allocate I2S RX channel: %s", esp_err_to_name(ret));
        return ret;
    }

    // Data bit width
    i2s_data_bit_width_t data_bit_width = I2S_DATA_BIT_WIDTH_16BIT;
    if (bits_per_sample == 24) data_bit_width = I2S_DATA_BIT_WIDTH_24BIT;
    else if (bits_per_sample == 32) data_bit_width = I2S_DATA_BIT_WIDTH_32BIT;

    // Standard I2S configuration (Philips format)
    i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(sample_rate),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(data_bit_width, I2S_SLOT_MODE_STEREO),
        .gpio_cfg = {
            .mclk = (mclk_pin >= 0) ? mclk_pin : I2S_GPIO_UNUSED,
            .bclk = bclk_pin,
            .ws = ws_pin,
            .dout = I2S_GPIO_UNUSED,
            .din = din_pin,
            .invert_flags = {
                .mclk_inv = false,
                .bclk_inv = false,
                .ws_inv = false,
            },
        },
    };

    // Set MCLK multiple to 256 (standard for most codecs)
    std_cfg.clk_cfg.mclk_multiple = I2S_MCLK_MULTIPLE_256;

    ret = i2s_channel_init_std_mode(*rx_handle, &std_cfg);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to init STD RX mode: %s", esp_err_to_name(ret));
        i2s_del_channel(*rx_handle);
        *rx_handle = NULL;
        return ret;
    }

    ESP_LOGI(TAG, "I2S STD RX initialized successfully");
    return ESP_OK;
}

/**
 * Initialize I2S STD TX channel for speaker output
 *
 * @param port I2S port number (0 or 1)
 * @param sample_rate Sample rate in Hz
 * @param bits_per_sample Bits per sample (16, 24, or 32)
 * @param bclk_pin Bit clock GPIO pin
 * @param ws_pin Word select (LRCK) GPIO pin
 * @param dout_pin Data output GPIO pin
 * @param mclk_pin Master clock GPIO pin (-1 if unused)
 * @param[out] tx_handle Pointer to store the TX channel handle
 * @return ESP_OK on success, error code otherwise
 */
esp_err_t i2s_std_helper_init_tx(
    int port,
    uint32_t sample_rate,
    int bits_per_sample,
    int bclk_pin,
    int ws_pin,
    int dout_pin,
    int mclk_pin,
    i2s_chan_handle_t *tx_handle
) {
    ESP_LOGI(TAG, "Init I2S STD TX: port=%d, rate=%lu, bits=%d",
             port, sample_rate, bits_per_sample);
    ESP_LOGI(TAG, "  Pins: BCLK=%d, WS=%d, DOUT=%d, MCLK=%d",
             bclk_pin, ws_pin, dout_pin, mclk_pin);

    // Channel configuration
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(port, I2S_ROLE_MASTER);
    // DMA buffer configuration for smooth audio playback
    chan_cfg.dma_desc_num = 6;    // Number of DMA descriptors (buffers)
    chan_cfg.dma_frame_num = 240; // Frames per descriptor (~15ms at 16kHz)
    chan_cfg.auto_clear = true;   // Auto clear the legacy data in the DMA buffer

    // Allocate TX channel only
    esp_err_t ret = i2s_new_channel(&chan_cfg, tx_handle, NULL);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to allocate I2S TX channel: %s", esp_err_to_name(ret));
        return ret;
    }

    // Data bit width
    i2s_data_bit_width_t data_bit_width = I2S_DATA_BIT_WIDTH_16BIT;
    if (bits_per_sample == 24) data_bit_width = I2S_DATA_BIT_WIDTH_24BIT;
    else if (bits_per_sample == 32) data_bit_width = I2S_DATA_BIT_WIDTH_32BIT;

    // Standard I2S configuration (Philips format for ES8311)
    i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(sample_rate),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(data_bit_width, I2S_SLOT_MODE_STEREO),
        .gpio_cfg = {
            .mclk = (mclk_pin >= 0) ? mclk_pin : I2S_GPIO_UNUSED,
            .bclk = bclk_pin,
            .ws = ws_pin,
            .dout = dout_pin,
            .din = I2S_GPIO_UNUSED,
            .invert_flags = {
                .mclk_inv = false,
                .bclk_inv = false,
                .ws_inv = false,
            },
        },
    };

    // Set MCLK multiple to 256 (standard for most codecs)
    std_cfg.clk_cfg.mclk_multiple = I2S_MCLK_MULTIPLE_256;

    ret = i2s_channel_init_std_mode(*tx_handle, &std_cfg);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to init STD TX mode: %s", esp_err_to_name(ret));
        i2s_del_channel(*tx_handle);
        *tx_handle = NULL;
        return ret;
    }

    ESP_LOGI(TAG, "I2S STD TX initialized successfully");
    return ESP_OK;
}

/**
 * Deinitialize I2S STD channel
 */
esp_err_t i2s_std_helper_deinit(i2s_chan_handle_t handle) {
    if (handle == NULL) return ESP_OK;
    return i2s_del_channel(handle);
}

/**
 * Enable I2S channel
 */
esp_err_t i2s_std_helper_enable(i2s_chan_handle_t handle) {
    if (handle == NULL) return ESP_ERR_INVALID_ARG;
    return i2s_channel_enable(handle);
}

/**
 * Disable I2S channel
 */
esp_err_t i2s_std_helper_disable(i2s_chan_handle_t handle) {
    if (handle == NULL) return ESP_ERR_INVALID_ARG;
    return i2s_channel_disable(handle);
}

/**
 * Read from I2S RX channel
 */
esp_err_t i2s_std_helper_read(
    i2s_chan_handle_t handle,
    void *buffer,
    size_t buffer_size,
    size_t *bytes_read,
    uint32_t timeout_ms
) {
    if (handle == NULL) return ESP_ERR_INVALID_ARG;
    return i2s_channel_read(handle, buffer, buffer_size, bytes_read, timeout_ms);
}

/**
 * Write to I2S TX channel
 */
esp_err_t i2s_std_helper_write(
    i2s_chan_handle_t handle,
    const void *buffer,
    size_t buffer_size,
    size_t *bytes_written,
    uint32_t timeout_ms
) {
    if (handle == NULL) return ESP_ERR_INVALID_ARG;
    return i2s_channel_write(handle, buffer, buffer_size, bytes_written, timeout_ms);
}

// Force link symbol
void i2s_std_helper_force_link(void) {
    (void)i2s_std_helper_init_rx;
    (void)i2s_std_helper_init_tx;
    (void)i2s_std_helper_deinit;
    (void)i2s_std_helper_enable;
    (void)i2s_std_helper_disable;
    (void)i2s_std_helper_read;
    (void)i2s_std_helper_write;
}
