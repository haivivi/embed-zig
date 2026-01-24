/**
 * GPIO Button Example - C Version
 *
 * Demonstrates GPIO input/output:
 * - Read Boot button state (GPIO0, active low)
 * - Control onboard RGB LED (GPIO48)
 * - Button press toggles LED state
 *
 * Hardware:
 * - Boot button on GPIO0 (active low, has internal pull-up)
 * - WS2812 RGB LED on GPIO48
 */

#include <stdio.h>
#include <stdbool.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "led_strip.h"
#include "esp_log.h"

static const char *TAG = "gpio_button";

#define BOOT_BUTTON_GPIO    0
#define LED_GPIO            48

static led_strip_handle_t led_strip = NULL;
static bool led_state = false;

void app_main(void)
{
    ESP_LOGI(TAG, "==========================================");
    ESP_LOGI(TAG, "GPIO Button Example - C Version");
    ESP_LOGI(TAG, "==========================================");
    ESP_LOGI(TAG, "Press Boot button to toggle LED");

    // Configure Boot button as input with pull-up
    gpio_reset_pin(BOOT_BUTTON_GPIO);
    gpio_set_direction(BOOT_BUTTON_GPIO, GPIO_MODE_INPUT);
    gpio_set_pull_mode(BOOT_BUTTON_GPIO, GPIO_PULLUP_ONLY);

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

    ESP_LOGI(TAG, "GPIO initialized. Button=GPIO%d, LED=GPIO%d", BOOT_BUTTON_GPIO, LED_GPIO);

    int last_button_state = 1;  // Button is active low
    uint32_t press_count = 0;

    while (1) {
        // Read button state (active low)
        int button_state = gpio_get_level(BOOT_BUTTON_GPIO);

        // Detect button press (falling edge)
        if (last_button_state == 1 && button_state == 0) {
            press_count++;
            led_state = !led_state;

            ESP_LOGI(TAG, "Button pressed! Count=%lu, LED=%s",
                     (unsigned long)press_count, led_state ? "ON" : "OFF");

            if (led_state) {
                // LED on: white color
                led_strip_set_pixel(led_strip, 0, 32, 32, 32);
                led_strip_refresh(led_strip);
            } else {
                // LED off
                led_strip_clear(led_strip);
            }

            // Simple debounce
            vTaskDelay(pdMS_TO_TICKS(50));
        }

        last_button_state = button_state;
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
