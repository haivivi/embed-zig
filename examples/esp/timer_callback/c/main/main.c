/**
 * Hardware Timer Callback Example - C Version
 *
 * Demonstrates hardware timer (GPTimer) with interrupt callback:
 * - Create 1 second periodic timer
 * - Toggle LED in timer callback
 * - Count timer ticks
 *
 * Uses GPTimer for precise timing independent of FreeRTOS tick.
 */

#include <stdio.h>
#include <stdbool.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gptimer.h"
#include "led_strip.h"
#include "esp_log.h"

static const char *TAG = "timer_callback";

#define LED_GPIO 48

static led_strip_handle_t led_strip = NULL;
static volatile uint32_t tick_count = 0;
static volatile bool led_state = false;
static volatile bool led_changed = false;

/**
 * Timer alarm callback - runs in ISR context
 * IMPORTANT: Only update flags here - no blocking calls!
 */
static bool IRAM_ATTR timer_alarm_callback(gptimer_handle_t timer,
                                           const gptimer_alarm_event_data_t *event,
                                           void *user_data)
{
    (void)timer;
    (void)event;
    (void)user_data;

    tick_count++;
    led_state = !led_state;
    led_changed = true;

    return false;  // Don't yield to higher priority task
}

void app_main(void)
{
    ESP_LOGI(TAG, "==========================================");
    ESP_LOGI(TAG, "Hardware Timer Example - C Version");
    ESP_LOGI(TAG, "==========================================");

    // Initialize LED strip
    led_strip_config_t strip_config = {
        .strip_gpio_num = LED_GPIO,
        .max_leds = 1,
        .led_model = LED_MODEL_WS2812,
        .color_component_format = LED_STRIP_COLOR_COMPONENT_FMT_GRB,
        .flags.invert_out = false,
    };

    led_strip_rmt_config_t rmt_config = {
        .resolution_hz = 10 * 1000 * 1000,
        .flags.with_dma = false,
    };

    ESP_ERROR_CHECK(led_strip_new_rmt_device(&strip_config, &rmt_config, &led_strip));
    led_strip_clear(led_strip);

    // Create hardware timer
    gptimer_handle_t timer = NULL;
    gptimer_config_t timer_config = {
        .clk_src = GPTIMER_CLK_SRC_DEFAULT,
        .direction = GPTIMER_COUNT_UP,
        .resolution_hz = 1000000,  // 1MHz = 1us per tick
    };
    ESP_ERROR_CHECK(gptimer_new_timer(&timer_config, &timer));

    // Set alarm for 1 second with auto-reload
    gptimer_alarm_config_t alarm_config = {
        .alarm_count = 1000000,  // 1 second
        .reload_count = 0,
        .flags.auto_reload_on_alarm = true,
    };
    ESP_ERROR_CHECK(gptimer_set_alarm_action(timer, &alarm_config));

    // Register callback
    gptimer_event_callbacks_t cbs = {
        .on_alarm = timer_alarm_callback,
    };
    ESP_ERROR_CHECK(gptimer_register_event_callbacks(timer, &cbs, NULL));

    // Enable and start timer
    ESP_ERROR_CHECK(gptimer_enable(timer));
    ESP_ERROR_CHECK(gptimer_start(timer));

    ESP_LOGI(TAG, "Timer started! LED toggles every 1 second");
    ESP_LOGI(TAG, "Timer resolution: 1MHz (1us per tick)");

    // Main loop - handle LED updates (not in ISR!)
    while (1) {
        if (led_changed) {
            led_changed = false;

            // Update LED - safe in main loop context
            if (led_state) {
                led_strip_set_pixel(led_strip, 0, 32, 0, 0);  // Red
                led_strip_refresh(led_strip);
            } else {
                led_strip_clear(led_strip);
            }

            ESP_LOGI(TAG, "Timer tick #%lu, LED=%s",
                     (unsigned long)tick_count, led_state ? "ON" : "OFF");
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
