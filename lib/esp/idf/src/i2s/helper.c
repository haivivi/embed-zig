/**
 * I2S Helper for Zig
 *
 * Provides C helper functions for I2S configuration since
 * the ESP-IDF structs contain complex anonymous types that
 * Zig's cImport cannot handle directly.
 *
 * Supports:
 * - TDM mode (multi-channel for microphone arrays)
 * - Full-duplex operation (simultaneous TX and RX on same port)
 */

#include "driver/i2s_tdm.h"
#include "driver/i2s_std.h"
#include "driver/i2s_common.h"
#include "driver/gpio.h"
#include "esp_log.h"

static const char *TAG = "i2s_helper";

// Maximum number of I2S ports
#define I2S_PORT_MAX 2

// Store channel handles per port for reuse
static i2s_chan_handle_t s_rx_handles[I2S_PORT_MAX] = {NULL, NULL};
static i2s_chan_handle_t s_tx_handles[I2S_PORT_MAX] = {NULL, NULL};

// Track if port is initialized
static bool s_port_initialized[I2S_PORT_MAX] = {false, false};

/**
 * Initialize I2S full-duplex (TX + RX) using STD mode (32-bit stereo)
 * 
 * This mode is used when ES7210 is configured with internal TDM mode.
 * ES7210 TDM output order: Ch1, Ch3, Ch2, Ch4 (interleaved per datasheet Fig.2e)
 * With I2S STD 32-bit stereo:
 *   L (32-bit) = [MIC1 (HI)] + [MIC3/REF (LO)]
 *   R (32-bit) = [MIC2 (HI)] + [MIC4 (LO)]
 */
esp_err_t i2s_helper_init_std_duplex(
    int port,
    uint32_t sample_rate,
    int bits_per_sample,
    int bclk_pin,
    int ws_pin,
    int din_pin,
    int dout_pin,
    int mclk_pin
) {
    if (port < 0 || port >= I2S_PORT_MAX) {
        ESP_LOGE(TAG, "Invalid port: %d", port);
        return ESP_ERR_INVALID_ARG;
    }

    if (s_port_initialized[port]) {
        ESP_LOGW(TAG, "Port %d already initialized", port);
        return ESP_OK;
    }

    ESP_LOGI(TAG, "Init I2S STD: port=%d, rate=%lu, bits=%d",
             port, sample_rate, bits_per_sample);
    ESP_LOGI(TAG, "  Pins: BCLK=%d, WS=%d, DIN=%d, DOUT=%d, MCLK=%d",
             bclk_pin, ws_pin, din_pin, dout_pin, mclk_pin);

    bool need_rx = (din_pin >= 0);
    bool need_tx = (dout_pin >= 0);

    // Channel configuration
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(port, I2S_ROLE_MASTER);
    chan_cfg.dma_desc_num = 6;
    chan_cfg.dma_frame_num = 240;

    // Allocate channels
    i2s_chan_handle_t tx_handle = NULL;
    i2s_chan_handle_t rx_handle = NULL;

    ESP_LOGI(TAG, "  [STD] Allocating channels...");
    esp_err_t ret = i2s_new_channel(&chan_cfg,
                                     need_tx ? &tx_handle : NULL,
                                     need_rx ? &rx_handle : NULL);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to allocate I2S channels: %s", esp_err_to_name(ret));
        return ret;
    }
    ESP_LOGI(TAG, "  [STD] Channels allocated: tx=%p, rx=%p", tx_handle, rx_handle);

    // Data bit width
    i2s_data_bit_width_t data_bit_width = I2S_DATA_BIT_WIDTH_16BIT;
    if (bits_per_sample == 24) data_bit_width = I2S_DATA_BIT_WIDTH_24BIT;
    else if (bits_per_sample == 32) data_bit_width = I2S_DATA_BIT_WIDTH_32BIT;

    ESP_LOGI(TAG, "  [STD] Initializing RX channel...");
    // Initialize RX channel (STD stereo mode)
    if (need_rx && rx_handle) {
        i2s_std_config_t rx_cfg = {
            .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(sample_rate),
            .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(data_bit_width, I2S_SLOT_MODE_STEREO),
            .gpio_cfg = {
                .mclk = (mclk_pin >= 0) ? mclk_pin : GPIO_NUM_NC,
                .bclk = bclk_pin,
                .ws = ws_pin,
                .dout = GPIO_NUM_NC,
                .din = din_pin,
            },
        };
        rx_cfg.clk_cfg.mclk_multiple = I2S_MCLK_MULTIPLE_256;

        ESP_LOGI(TAG, "  [STD] Calling i2s_channel_init_std_mode(rx)...");
        ret = i2s_channel_init_std_mode(rx_handle, &rx_cfg);
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "Failed to init RX STD mode: %s", esp_err_to_name(ret));
            goto cleanup;
        }
        ESP_LOGI(TAG, "RX channel initialized (STD stereo, %d-bit)", bits_per_sample);
    } else {
        ESP_LOGI(TAG, "  [STD] Skipping RX init (need_rx=%d, rx_handle=%p)", need_rx, rx_handle);
    }

    ESP_LOGI(TAG, "  [STD] Initializing TX channel...");
    // Initialize TX channel (STD stereo mode)
    if (need_tx && tx_handle) {
        i2s_std_config_t tx_cfg = {
            .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(sample_rate),
            .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(data_bit_width, I2S_SLOT_MODE_STEREO),
            .gpio_cfg = {
                .mclk = GPIO_NUM_NC,
                .bclk = GPIO_NUM_NC,
                .ws = GPIO_NUM_NC,
                .dout = dout_pin,
                .din = GPIO_NUM_NC,
            },
        };

        // If no RX, TX controls clock pins
        if (!need_rx) {
            tx_cfg.gpio_cfg.bclk = bclk_pin;
            tx_cfg.gpio_cfg.ws = ws_pin;
            tx_cfg.gpio_cfg.mclk = (mclk_pin >= 0) ? mclk_pin : GPIO_NUM_NC;
            tx_cfg.clk_cfg.mclk_multiple = I2S_MCLK_MULTIPLE_256;
        }

        ret = i2s_channel_init_std_mode(tx_handle, &tx_cfg);
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "Failed to init TX STD mode: %s", esp_err_to_name(ret));
            goto cleanup;
        }
        ESP_LOGI(TAG, "TX channel initialized (STD stereo, %d-bit)", bits_per_sample);
    }

    // Store handles
    s_rx_handles[port] = rx_handle;
    s_tx_handles[port] = tx_handle;
    s_port_initialized[port] = true;

    ESP_LOGI(TAG, "I2S port %d initialized successfully (STD full-duplex)", port);
    return ESP_OK;

cleanup:
    if (rx_handle) i2s_del_channel(rx_handle);
    if (tx_handle) i2s_del_channel(tx_handle);
    return ret;
}

/**
 * Initialize I2S full-duplex (TX + RX) using TDM mode
 */
esp_err_t i2s_helper_init_full_duplex(
    int port,
    uint32_t sample_rate,
    int rx_channels,
    int bits_per_sample,
    int bclk_pin,
    int ws_pin,
    int din_pin,
    int dout_pin,
    int mclk_pin
) {
    if (port < 0 || port >= I2S_PORT_MAX) {
        ESP_LOGE(TAG, "Invalid port: %d", port);
        return ESP_ERR_INVALID_ARG;
    }

    if (s_port_initialized[port]) {
        ESP_LOGW(TAG, "Port %d already initialized", port);
        return ESP_OK;
    }

    ESP_LOGI(TAG, "Init I2S TDM: port=%d, rate=%lu, rx_ch=%d, bits=%d",
             port, sample_rate, rx_channels, bits_per_sample);
    ESP_LOGI(TAG, "  Pins: BCLK=%d, WS=%d, DIN=%d, DOUT=%d, MCLK=%d",
             bclk_pin, ws_pin, din_pin, dout_pin, mclk_pin);

    bool need_rx = (din_pin >= 0);
    bool need_tx = (dout_pin >= 0);

    // Channel configuration
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(port, I2S_ROLE_MASTER);
    chan_cfg.dma_desc_num = 6;
    chan_cfg.dma_frame_num = 240;

    // Allocate channels
    i2s_chan_handle_t tx_handle = NULL;
    i2s_chan_handle_t rx_handle = NULL;

    esp_err_t ret = i2s_new_channel(&chan_cfg,
                                     need_tx ? &tx_handle : NULL,
                                     need_rx ? &rx_handle : NULL);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to allocate I2S channels: %s", esp_err_to_name(ret));
        return ret;
    }

    // Data bit width
    i2s_data_bit_width_t data_bit_width = I2S_DATA_BIT_WIDTH_16BIT;
    if (bits_per_sample == 24) data_bit_width = I2S_DATA_BIT_WIDTH_24BIT;
    else if (bits_per_sample == 32) data_bit_width = I2S_DATA_BIT_WIDTH_32BIT;

    // Build RX slot mask (for TDM multi-channel)
    i2s_tdm_slot_mask_t rx_slot_mask = I2S_TDM_SLOT0;
    if (rx_channels >= 2) rx_slot_mask |= I2S_TDM_SLOT1;
    if (rx_channels >= 3) rx_slot_mask |= I2S_TDM_SLOT2;
    if (rx_channels >= 4) rx_slot_mask |= I2S_TDM_SLOT3;

    // TX uses 2 slots (stereo)
    i2s_tdm_slot_mask_t tx_slot_mask = I2S_TDM_SLOT0 | I2S_TDM_SLOT1;

    // TDM clock configuration
    i2s_tdm_clk_config_t clk_cfg = I2S_TDM_CLK_DEFAULT_CONFIG(sample_rate);
    clk_cfg.mclk_multiple = I2S_MCLK_MULTIPLE_512;

    // Initialize RX channel (TDM mode)
    if (need_rx && rx_handle) {
        i2s_tdm_slot_config_t rx_slot_cfg = I2S_TDM_PHILIPS_SLOT_DEFAULT_CONFIG(
            data_bit_width,
            I2S_SLOT_MODE_STEREO,
            rx_slot_mask
        );

        i2s_tdm_gpio_config_t rx_gpio_cfg = {
            .bclk = bclk_pin,
            .ws = ws_pin,
            .din = din_pin,
            .dout = GPIO_NUM_NC,
            .mclk = (mclk_pin >= 0) ? mclk_pin : GPIO_NUM_NC,
        };

        i2s_tdm_config_t rx_tdm_cfg = {
            .slot_cfg = rx_slot_cfg,
            .clk_cfg = clk_cfg,
            .gpio_cfg = rx_gpio_cfg,
        };

        ret = i2s_channel_init_tdm_mode(rx_handle, &rx_tdm_cfg);
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "Failed to init RX TDM mode: %s", esp_err_to_name(ret));
            goto cleanup;
        }
        ESP_LOGI(TAG, "RX channel initialized (TDM, %d slots)", rx_channels);
    }

    // Initialize TX channel (TDM mode)
    if (need_tx && tx_handle) {
        i2s_tdm_slot_config_t tx_slot_cfg = I2S_TDM_PHILIPS_SLOT_DEFAULT_CONFIG(
            data_bit_width,
            I2S_SLOT_MODE_STEREO,
            tx_slot_mask
        );

        i2s_tdm_gpio_config_t tx_gpio_cfg = {
            .bclk = GPIO_NUM_NC,
            .ws = GPIO_NUM_NC,
            .din = GPIO_NUM_NC,
            .dout = dout_pin,
            .mclk = GPIO_NUM_NC,
        };

        if (!need_rx) {
            tx_gpio_cfg.bclk = bclk_pin;
            tx_gpio_cfg.ws = ws_pin;
            tx_gpio_cfg.mclk = (mclk_pin >= 0) ? mclk_pin : GPIO_NUM_NC;
        }

        i2s_tdm_config_t tx_tdm_cfg = {
            .slot_cfg = tx_slot_cfg,
            .clk_cfg = clk_cfg,
            .gpio_cfg = tx_gpio_cfg,
        };

        ret = i2s_channel_init_tdm_mode(tx_handle, &tx_tdm_cfg);
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "Failed to init TX TDM mode: %s", esp_err_to_name(ret));
            goto cleanup;
        }
        ESP_LOGI(TAG, "TX channel initialized (TDM, stereo)");
    }

    // Store handles
    s_rx_handles[port] = rx_handle;
    s_tx_handles[port] = tx_handle;
    s_port_initialized[port] = true;

    ESP_LOGI(TAG, "I2S port %d initialized successfully (TDM full-duplex)", port);
    return ESP_OK;

cleanup:
    if (rx_handle) i2s_del_channel(rx_handle);
    if (tx_handle) i2s_del_channel(tx_handle);
    return ret;
}

/**
 * Deinitialize I2S port
 */
esp_err_t i2s_helper_deinit(int port) {
    if (port < 0 || port >= I2S_PORT_MAX) return ESP_ERR_INVALID_ARG;
    if (!s_port_initialized[port]) return ESP_OK;

    esp_err_t ret = ESP_OK;

    if (s_rx_handles[port]) {
        ret = i2s_del_channel(s_rx_handles[port]);
        s_rx_handles[port] = NULL;
    }

    if (s_tx_handles[port]) {
        esp_err_t tx_ret = i2s_del_channel(s_tx_handles[port]);
        if (ret == ESP_OK) ret = tx_ret;
        s_tx_handles[port] = NULL;
    }

    s_port_initialized[port] = false;
    ESP_LOGI(TAG, "I2S port %d deinitialized", port);
    return ret;
}

/**
 * Get RX channel handle
 */
i2s_chan_handle_t i2s_helper_get_rx_handle(int port) {
    if (port < 0 || port >= I2S_PORT_MAX) return NULL;
    return s_rx_handles[port];
}

/**
 * Get TX channel handle
 */
i2s_chan_handle_t i2s_helper_get_tx_handle(int port) {
    if (port < 0 || port >= I2S_PORT_MAX) return NULL;
    return s_tx_handles[port];
}

/**
 * Enable RX channel
 */
esp_err_t i2s_helper_enable_rx(int port) {
    if (port < 0 || port >= I2S_PORT_MAX) return ESP_ERR_INVALID_ARG;
    if (!s_rx_handles[port]) return ESP_ERR_INVALID_STATE;
    return i2s_channel_enable(s_rx_handles[port]);
}

/**
 * Disable RX channel
 */
esp_err_t i2s_helper_disable_rx(int port) {
    if (port < 0 || port >= I2S_PORT_MAX) return ESP_ERR_INVALID_ARG;
    if (!s_rx_handles[port]) return ESP_ERR_INVALID_STATE;
    return i2s_channel_disable(s_rx_handles[port]);
}

/**
 * Enable TX channel
 */
esp_err_t i2s_helper_enable_tx(int port) {
    if (port < 0 || port >= I2S_PORT_MAX) return ESP_ERR_INVALID_ARG;
    if (!s_tx_handles[port]) return ESP_ERR_INVALID_STATE;
    return i2s_channel_enable(s_tx_handles[port]);
}

/**
 * Disable TX channel
 */
esp_err_t i2s_helper_disable_tx(int port) {
    if (port < 0 || port >= I2S_PORT_MAX) return ESP_ERR_INVALID_ARG;
    if (!s_tx_handles[port]) return ESP_ERR_INVALID_STATE;
    return i2s_channel_disable(s_tx_handles[port]);
}

/**
 * Read from RX channel
 */
esp_err_t i2s_helper_read(
    int port,
    void *buffer,
    size_t buffer_size,
    size_t *bytes_read,
    uint32_t timeout_ms
) {
    if (port < 0 || port >= I2S_PORT_MAX) return ESP_ERR_INVALID_ARG;
    if (!s_rx_handles[port]) return ESP_ERR_INVALID_STATE;
    return i2s_channel_read(s_rx_handles[port], buffer, buffer_size, bytes_read, timeout_ms);
}

/**
 * Write to TX channel
 */
esp_err_t i2s_helper_write(
    int port,
    const void *buffer,
    size_t buffer_size,
    size_t *bytes_written,
    uint32_t timeout_ms
) {
    if (port < 0 || port >= I2S_PORT_MAX) return ESP_ERR_INVALID_ARG;
    if (!s_tx_handles[port]) return ESP_ERR_INVALID_STATE;
    return i2s_channel_write(s_tx_handles[port], buffer, buffer_size, bytes_written, timeout_ms);
}

// Force link symbol
void i2s_helper_force_link(void) {
    (void)i2s_helper_init_std_duplex;
    (void)i2s_helper_init_full_duplex;
    (void)i2s_helper_deinit;
    (void)i2s_helper_get_rx_handle;
    (void)i2s_helper_get_tx_handle;
    (void)i2s_helper_enable_rx;
    (void)i2s_helper_disable_rx;
    (void)i2s_helper_enable_tx;
    (void)i2s_helper_disable_tx;
    (void)i2s_helper_read;
    (void)i2s_helper_write;
}
