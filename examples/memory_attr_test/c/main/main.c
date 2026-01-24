/**
 * Memory Attribute Test - C Version
 * 
 * This example tests various memory placement attributes:
 * - EXT_RAM_BSS_ATTR: Place variables in PSRAM
 * - DRAM_ATTR: Place variables in internal DRAM
 * - IRAM_ATTR: Place functions in internal IRAM
 */

#include <stdio.h>
#include <string.h>
#include "sdkconfig.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_attr.h"
#include "esp_heap_caps.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "mem_attr_test";
static const char *BUILD_TAG = "mem_attr_c_v1";

// ============================================================================
// Test 1: PSRAM (External RAM) - Using EXT_RAM_BSS_ATTR
// ============================================================================

/// Large array placed in PSRAM (.ext_ram.bss section)
EXT_RAM_BSS_ATTR static uint8_t psram_buffer[4096];

/// Another PSRAM variable for testing
EXT_RAM_BSS_ATTR static uint32_t psram_counter;

// ============================================================================
// Test 2: DRAM (Internal RAM) - Using DRAM_ATTR
// ============================================================================

/// Variable placed in internal DRAM (.dram1 section)
DRAM_ATTR static uint32_t dram_variable = 0;

/// DMA-capable buffer in DRAM (must be word-aligned)
DMA_ATTR static uint8_t dma_buffer[256];

// ============================================================================
// Test 3: IRAM (Internal RAM for code) - Using IRAM_ATTR
// ============================================================================

/// Function placed in IRAM - useful for ISR handlers
static void IRAM_ATTR iram_function(void) {
    // Simple operation to test IRAM execution
    dram_variable++;
}

/// Another IRAM function that does some computation
static uint32_t IRAM_ATTR iram_compute(uint32_t a, uint32_t b) {
    return a * b + dram_variable;
}

// ============================================================================
// Helper functions for address verification
// ============================================================================

static const char* get_memory_region_name(const void *ptr) {
    if (esp_ptr_external_ram(ptr)) {
        return "PSRAM (External)";
    } else if (esp_ptr_in_iram(ptr)) {
        return "IRAM (Internal)";
    } else if (esp_ptr_internal(ptr)) {
        return "DRAM (Internal)";
    } else {
        return "Unknown";
    }
}

// ============================================================================
// Test functions
// ============================================================================

static void test_psram_variables(void) {
    ESP_LOGI(TAG, "=== Testing PSRAM Variables ===");
    
    // Test psram_buffer
    const char *buffer_region = get_memory_region_name(psram_buffer);
    ESP_LOGI(TAG, "psram_buffer address: 0x%08X, region: %s", 
             (unsigned int)(uintptr_t)psram_buffer, buffer_region);
    
    if (esp_ptr_external_ram(psram_buffer)) {
        ESP_LOGI(TAG, "  ✓ psram_buffer is correctly in PSRAM");
    } else {
        ESP_LOGE(TAG, "  ✗ psram_buffer is NOT in PSRAM!");
    }
    
    // Test psram_counter
    const char *counter_region = get_memory_region_name(&psram_counter);
    ESP_LOGI(TAG, "psram_counter address: 0x%08X, region: %s",
             (unsigned int)(uintptr_t)&psram_counter, counter_region);
    
    if (esp_ptr_external_ram(&psram_counter)) {
        ESP_LOGI(TAG, "  ✓ psram_counter is correctly in PSRAM");
    } else {
        ESP_LOGE(TAG, "  ✗ psram_counter is NOT in PSRAM!");
    }
    
    // Test read/write
    psram_counter = 12345;
    psram_buffer[0] = 0xAA;
    psram_buffer[4095] = 0x55;
    ESP_LOGI(TAG, "PSRAM read/write test: counter=%lu, buf[0]=0x%02X, buf[4095]=0x%02X",
             (unsigned long)psram_counter, psram_buffer[0], psram_buffer[4095]);
}

static void test_dram_variables(void) {
    ESP_LOGI(TAG, "=== Testing DRAM Variables ===");
    
    // Test dram_variable
    const char *dram_region = get_memory_region_name(&dram_variable);
    ESP_LOGI(TAG, "dram_variable address: 0x%08X, region: %s",
             (unsigned int)(uintptr_t)&dram_variable, dram_region);
    
    if (esp_ptr_internal(&dram_variable) && !esp_ptr_in_iram(&dram_variable)) {
        ESP_LOGI(TAG, "  ✓ dram_variable is correctly in DRAM");
    } else {
        ESP_LOGE(TAG, "  ✗ dram_variable is NOT in DRAM!");
    }
    
    // Test dma_buffer
    const char *dma_region = get_memory_region_name(dma_buffer);
    ESP_LOGI(TAG, "dma_buffer address: 0x%08X, region: %s",
             (unsigned int)(uintptr_t)dma_buffer, dma_region);
    
    int is_aligned = (((uintptr_t)dma_buffer) % 4) == 0;
    ESP_LOGI(TAG, "  dma_buffer alignment: %s (required: 4-byte)",
             is_aligned ? "OK" : "FAIL");
    
    if (esp_ptr_internal(dma_buffer) && !esp_ptr_in_iram(dma_buffer) && is_aligned) {
        ESP_LOGI(TAG, "  ✓ dma_buffer is correctly in DRAM and aligned");
    } else {
        ESP_LOGE(TAG, "  ✗ dma_buffer check failed!");
    }
}

static void test_iram_functions(void) {
    ESP_LOGI(TAG, "=== Testing IRAM Functions ===");
    
    // Test iram_function location
    const char *func_region = get_memory_region_name((void*)iram_function);
    ESP_LOGI(TAG, "iram_function address: 0x%08X, region: %s",
             (unsigned int)(uintptr_t)iram_function, func_region);
    
    if (esp_ptr_in_iram((void*)iram_function)) {
        ESP_LOGI(TAG, "  ✓ iram_function is correctly in IRAM");
    } else {
        ESP_LOGE(TAG, "  ✗ iram_function is NOT in IRAM!");
    }
    
    // Test iram_compute location
    const char *compute_region = get_memory_region_name((void*)iram_compute);
    ESP_LOGI(TAG, "iram_compute address: 0x%08X, region: %s",
             (unsigned int)(uintptr_t)iram_compute, compute_region);
    
    if (esp_ptr_in_iram((void*)iram_compute)) {
        ESP_LOGI(TAG, "  ✓ iram_compute is correctly in IRAM");
    } else {
        ESP_LOGE(TAG, "  ✗ iram_compute is NOT in IRAM!");
    }
    
    // Test execution
    dram_variable = 0;
    iram_function();
    ESP_LOGI(TAG, "IRAM function test: dram_variable after call = %lu",
             (unsigned long)dram_variable);
    
    uint32_t result = iram_compute(10, 20);
    ESP_LOGI(TAG, "IRAM compute test: iram_compute(10, 20) = %lu (expected: 201)",
             (unsigned long)result);
}

static void print_memory_stats(void) {
    ESP_LOGI(TAG, "=== Heap Memory Statistics ===");
    
    // Internal DRAM
    size_t dram_free = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    size_t dram_total = heap_caps_get_total_size(MALLOC_CAP_INTERNAL);
    size_t dram_min_free = heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL);
    size_t dram_largest = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL);
    
    ESP_LOGI(TAG, "Internal DRAM:");
    ESP_LOGI(TAG, "  Total: %6u bytes", (unsigned int)dram_total);
    ESP_LOGI(TAG, "  Free:  %6u bytes", (unsigned int)dram_free);
    ESP_LOGI(TAG, "  Used:  %6u bytes", (unsigned int)(dram_total - dram_free));
    ESP_LOGI(TAG, "  Min free ever: %u bytes", (unsigned int)dram_min_free);
    ESP_LOGI(TAG, "  Largest block: %u bytes", (unsigned int)dram_largest);
    
    // External PSRAM
    size_t psram_free = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
    size_t psram_total = heap_caps_get_total_size(MALLOC_CAP_SPIRAM);
    size_t psram_min_free = heap_caps_get_minimum_free_size(MALLOC_CAP_SPIRAM);
    size_t psram_largest = heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM);
    
    ESP_LOGI(TAG, "External PSRAM:");
    ESP_LOGI(TAG, "  Total: %6u bytes", (unsigned int)psram_total);
    ESP_LOGI(TAG, "  Free:  %6u bytes", (unsigned int)psram_free);
    ESP_LOGI(TAG, "  Used:  %6u bytes", (unsigned int)(psram_total - psram_free));
    ESP_LOGI(TAG, "  Min free ever: %u bytes", (unsigned int)psram_min_free);
    ESP_LOGI(TAG, "  Largest block: %u bytes", (unsigned int)psram_largest);
    
    // DMA capable memory
    size_t dma_free = heap_caps_get_free_size(MALLOC_CAP_DMA);
    ESP_LOGI(TAG, "DMA capable free: %u bytes", (unsigned int)dma_free);
}

// ============================================================================
// Main entry point
// ============================================================================

void app_main(void) {
    ESP_LOGI(TAG, "==========================================");
    ESP_LOGI(TAG, "  Memory Attribute Test - C Version");
    ESP_LOGI(TAG, "  Build Tag: %s", BUILD_TAG);
    ESP_LOGI(TAG, "==========================================");
    
    print_memory_stats();
    
    test_psram_variables();
    test_dram_variables();
    test_iram_functions();
    
    ESP_LOGI(TAG, "=====================================");
    ESP_LOGI(TAG, "All tests completed!");
    
    // Keep running
    while (1) {
        vTaskDelay(1000 / portTICK_PERIOD_MS);
    }
}
