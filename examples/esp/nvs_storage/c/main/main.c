/**
 * NVS Storage Example - C Version
 *
 * Demonstrates NVS (Non-Volatile Storage) operations:
 * - Integer read/write (boot counter)
 * - String read/write (device name)
 * - Blob read/write (binary data)
 * - Data persistence across reboots
 */

#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "nvs.h"

static const char *TAG = "nvs_example";
#define NAMESPACE "storage"

void app_main(void)
{
    ESP_LOGI(TAG, "==========================================");
    ESP_LOGI(TAG, "NVS Storage Example - C Version");
    ESP_LOGI(TAG, "==========================================");

    // Initialize NVS
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
    ESP_LOGI(TAG, "NVS initialized");

    // Open NVS namespace
    nvs_handle_t nvs_handle;
    err = nvs_open(NAMESPACE, NVS_READWRITE, &nvs_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to open NVS namespace: %s", esp_err_to_name(err));
        return;
    }

    // ===== Boot Counter (u32) =====
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "=== Boot Counter ===");

    uint32_t boot_count = 0;
    err = nvs_get_u32(nvs_handle, "boot_count", &boot_count);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGI(TAG, "boot_count not found, starting from 0");
        boot_count = 0;
    } else if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to read boot_count: %s", esp_err_to_name(err));
    }

    boot_count++;
    ESP_LOGI(TAG, "Boot count: %lu", (unsigned long)boot_count);

    err = nvs_set_u32(nvs_handle, "boot_count", boot_count);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to write boot_count: %s", esp_err_to_name(err));
    }

    // ===== Device Name (String) =====
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "=== Device Name ===");

    char device_name[64] = {0};
    size_t name_len = sizeof(device_name);
    err = nvs_get_str(nvs_handle, "device_name", device_name, &name_len);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGI(TAG, "device_name not found, setting default");
        strcpy(device_name, "ESP32-C-Device");
        err = nvs_set_str(nvs_handle, "device_name", device_name);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "Failed to write device_name: %s", esp_err_to_name(err));
        }
    } else if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to read device_name: %s", esp_err_to_name(err));
        strcpy(device_name, "unknown");
    }
    ESP_LOGI(TAG, "Device name: %s", device_name);

    // ===== Blob (Binary Data) =====
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "=== Blob Data ===");

    // Store some binary data
    uint8_t test_data[] = {0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE};
    err = nvs_set_blob(nvs_handle, "test_blob", test_data, sizeof(test_data));
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to write blob: %s", esp_err_to_name(err));
    }

    // Read it back
    uint8_t blob_buf[16] = {0};
    size_t blob_len = sizeof(blob_buf);
    err = nvs_get_blob(nvs_handle, "test_blob", blob_buf, &blob_len);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to read blob: %s", esp_err_to_name(err));
        blob_len = 0;
    }

    // Print blob as hex
    char hex_str[64] = {0};
    for (size_t i = 0; i < blob_len; i++) {
        sprintf(hex_str + i * 2, "%02x", blob_buf[i]);
    }
    ESP_LOGI(TAG, "Blob data (%d bytes): %s", (int)blob_len, hex_str);

    // ===== Commit Changes =====
    err = nvs_commit(nvs_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to commit NVS: %s", esp_err_to_name(err));
    }
    ESP_LOGI(TAG, "NVS committed to flash");

    // Close NVS handle
    nvs_close(nvs_handle);

    // ===== Summary =====
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "=== Summary ===");
    ESP_LOGI(TAG, "Boot count: %lu (will increment on next boot)", (unsigned long)boot_count);
    ESP_LOGI(TAG, "Device name: %s", device_name);
    ESP_LOGI(TAG, "Blob stored: %d bytes", (int)blob_len);
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "Reboot the device to see boot_count increment!");

    // Keep running
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(10000));
        ESP_LOGI(TAG, "Still running... boot_count=%lu", (unsigned long)boot_count);
    }
}
