/**
 * PWM Fade (Breathing LED) Example - C Version
 *
 * Demonstrates LEDC PWM control with hardware fade:
 * - Configure LEDC timer and channel
 * - Use hardware fade function for smooth transitions
 * - Create breathing LED effect
 *
 * Note: This uses a simple GPIO for PWM output.
 * The WS2812 RGB LED requires specific timing and can't use LEDC directly.
 * Connect an external LED to GPIO2 for this demo, or just observe PWM output.
 */

#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/ledc.h"
#include "esp_log.h"

static const char *TAG = "pwm_fade";

// Use GPIO2 for PWM output (external LED or oscilloscope)
#define PWM_GPIO            2
#define PWM_FREQ_HZ         5000
#define PWM_RESOLUTION      LEDC_TIMER_13_BIT
#define MAX_DUTY            8191    // 2^13 - 1
#define FADE_TIME_MS        2000

void app_main(void)
{
    ESP_LOGI(TAG, "==========================================");
    ESP_LOGI(TAG, "PWM Fade Example - C Version");
    ESP_LOGI(TAG, "==========================================");
    ESP_LOGI(TAG, "PWM output on GPIO%d", PWM_GPIO);
    ESP_LOGI(TAG, "Frequency: %d Hz, Resolution: 13-bit", PWM_FREQ_HZ);

    // Configure LEDC timer
    ledc_timer_config_t timer_conf = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .timer_num = LEDC_TIMER_0,
        .duty_resolution = PWM_RESOLUTION,
        .freq_hz = PWM_FREQ_HZ,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ESP_ERROR_CHECK(ledc_timer_config(&timer_conf));

    // Configure LEDC channel
    ledc_channel_config_t channel_conf = {
        .gpio_num = PWM_GPIO,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel = LEDC_CHANNEL_0,
        .timer_sel = LEDC_TIMER_0,
        .duty = 0,
        .hpoint = 0,
        .intr_type = LEDC_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(ledc_channel_config(&channel_conf));

    // Install fade service
    ESP_ERROR_CHECK(ledc_fade_func_install(0));

    ESP_LOGI(TAG, "LEDC initialized. Starting breathing effect...");

    uint32_t cycle = 0;

    while (1) {
        cycle++;

        // Fade up to max duty
        ESP_LOGI(TAG, "Cycle %lu: Fading UP (0 -> %d)", (unsigned long)cycle, MAX_DUTY);
        ESP_ERROR_CHECK(ledc_set_fade_with_time(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0,
                                                 MAX_DUTY, FADE_TIME_MS));
        ESP_ERROR_CHECK(ledc_fade_start(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0,
                                        LEDC_FADE_WAIT_DONE));

        // Fade down to 0
        ESP_LOGI(TAG, "Cycle %lu: Fading DOWN (%d -> 0)", (unsigned long)cycle, MAX_DUTY);
        ESP_ERROR_CHECK(ledc_set_fade_with_time(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0,
                                                 0, FADE_TIME_MS));
        ESP_ERROR_CHECK(ledc_fade_start(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0,
                                        LEDC_FADE_WAIT_DONE));

        // Small pause between cycles
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}
