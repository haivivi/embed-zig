/**
 * Internal Temperature Sensor Example - C Version
 *
 * Demonstrates the internal temperature sensor:
 * - Initialize temperature sensor with default range
 * - Read chip temperature periodically
 * - Display temperature in Celsius
 *
 * Note: This reads the chip's internal temperature, not ambient temperature.
 * The reading is affected by chip operation and may be 10-20°C higher than ambient.
 */

#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/temperature_sensor.h"
#include "esp_log.h"

static const char *TAG = "temp_sensor";

void app_main(void)
{
    ESP_LOGI(TAG, "==========================================");
    ESP_LOGI(TAG, "Temperature Sensor Example - C Version");
    ESP_LOGI(TAG, "==========================================");

    // Initialize temperature sensor
    temperature_sensor_handle_t temp_sensor = NULL;
    temperature_sensor_config_t temp_config = {
        .range_min = -10,
        .range_max = 80,
        .clk_src = 0,  // Default clock source
    };

    ESP_ERROR_CHECK(temperature_sensor_install(&temp_config, &temp_sensor));
    ESP_ERROR_CHECK(temperature_sensor_enable(temp_sensor));

    ESP_LOGI(TAG, "Temperature sensor initialized (range: -10 to 80°C)");
    ESP_LOGI(TAG, "Note: This is chip internal temperature, not ambient!");
    ESP_LOGI(TAG, "");

    uint32_t reading_count = 0;
    float min_temp = 100.0f;
    float max_temp = -100.0f;
    float sum_temp = 0.0f;

    while (1) {
        reading_count++;

        // Read temperature
        float temp = 0.0f;
        esp_err_t err = temperature_sensor_get_celsius(temp_sensor, &temp);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "Failed to read temperature: %s", esp_err_to_name(err));
            vTaskDelay(pdMS_TO_TICKS(1000));
            continue;
        }

        // Update statistics
        if (temp < min_temp) min_temp = temp;
        if (temp > max_temp) max_temp = temp;
        sum_temp += temp;
        float avg_temp = sum_temp / (float)reading_count;

        // Display reading
        ESP_LOGI(TAG, "Reading #%lu: %.1f°C (min: %.1f, max: %.1f, avg: %.1f)",
                 (unsigned long)reading_count, temp, min_temp, max_temp, avg_temp);

        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}
