/**
 * LEDC helper functions for Zig
 * Wraps complex ESP-IDF structures that are difficult for @cImport
 */

#include "driver/ledc.h"
#include "esp_err.h"

/**
 * Initialize LEDC with simple configuration
 * Uses low speed mode, timer 0, channel 0
 */
esp_err_t ledc_init_simple(int gpio_num, uint32_t freq_hz, uint8_t duty_resolution_bits)
{
    // Configure timer
    ledc_timer_config_t timer_conf = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .timer_num = LEDC_TIMER_0,
        .duty_resolution = duty_resolution_bits,
        .freq_hz = freq_hz,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    esp_err_t err = ledc_timer_config(&timer_conf);
    if (err != ESP_OK) return err;

    // Configure channel
    ledc_channel_config_t channel_conf = {
        .gpio_num = gpio_num,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel = LEDC_CHANNEL_0,
        .timer_sel = LEDC_TIMER_0,
        .duty = 0,
        .hpoint = 0,
        .intr_type = LEDC_INTR_DISABLE,
    };
    err = ledc_channel_config(&channel_conf);
    if (err != ESP_OK) return err;

    // Install fade service
    err = ledc_fade_func_install(0);
    // Ignore error if already installed
    if (err == ESP_ERR_INVALID_STATE) {
        err = ESP_OK;
    }

    return err;
}

/**
 * Fade to target duty with blocking wait
 */
esp_err_t ledc_fade_simple(ledc_mode_t speed_mode, ledc_channel_t channel,
                           uint32_t target_duty, int fade_time_ms)
{
    esp_err_t err = ledc_set_fade_with_time(speed_mode, channel, target_duty, fade_time_ms);
    if (err != ESP_OK) return err;

    return ledc_fade_start(speed_mode, channel, LEDC_FADE_WAIT_DONE);
}
