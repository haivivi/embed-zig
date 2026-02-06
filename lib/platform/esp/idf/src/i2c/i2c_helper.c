// I2C helper - handles complex ESP-IDF types that Zig @cImport can't translate
// Uses new I2C Master Driver API (ESP-IDF 5.x)

#include "driver/i2c_master.h"
#include "esp_log.h"
#include <string.h>

static const char *TAG = "I2C_HELPER";

#define DEFAULT_I2C_TRANS_TIMEOUT  (200)   // default i2c transmit timeout (ms)
#define MAX_I2C_DEVICES            (16)    // max cached device handles

// Device handle cache entry
typedef struct {
    uint8_t addr;
    i2c_master_dev_handle_t handle;
} i2c_dev_cache_t;

// I2C state storage
static i2c_master_bus_handle_t s_bus_handle = NULL;
static i2c_dev_cache_t s_dev_cache[MAX_I2C_DEVICES];
static int s_dev_count = 0;
static uint32_t s_scl_freq_hz = 400000;

// Get or create device handle for address
static i2c_master_dev_handle_t get_device_handle(uint8_t addr) {
    // Check cache first
    for (int i = 0; i < s_dev_count; i++) {
        if (s_dev_cache[i].addr == addr) {
            return s_dev_cache[i].handle;
        }
    }
    
    // Create new device handle
    if (s_dev_count >= MAX_I2C_DEVICES) {
        ESP_LOGE(TAG, "Device cache full");
        return NULL;
    }
    
    i2c_device_config_t dev_cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = addr,  // 7-bit address
        .scl_speed_hz = s_scl_freq_hz,
    };
    
    i2c_master_dev_handle_t dev_handle;
    esp_err_t ret = i2c_master_bus_add_device(s_bus_handle, &dev_cfg, &dev_handle);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to add device 0x%02x: %d", addr, ret);
        return NULL;
    }
    
    // Cache the handle
    s_dev_cache[s_dev_count].addr = addr;
    s_dev_cache[s_dev_count].handle = dev_handle;
    s_dev_count++;
    
    return dev_handle;
}

// Initialize I2C master bus
int i2c_helper_init(int sda, int scl, uint32_t freq_hz, int port) {
    if (s_bus_handle != NULL) {
        // Already initialized
        return 0;
    }
    
    s_scl_freq_hz = freq_hz;
    
    ESP_LOGI(TAG, "Init I2C: SDA=%d, SCL=%d, freq=%lu, port=%d", sda, scl, freq_hz, port);
    
    i2c_master_bus_config_t bus_cfg = {
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .i2c_port = port,
        .scl_io_num = scl,
        .sda_io_num = sda,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    
    esp_err_t ret = i2c_new_master_bus(&bus_cfg, &s_bus_handle);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create I2C bus: %d", ret);
        return ret;
    }
    
    ESP_LOGI(TAG, "I2C bus created successfully");
    return ESP_OK;
}

// Deinitialize I2C bus
void i2c_helper_deinit(void) {
    // Remove all device handles
    for (int i = 0; i < s_dev_count; i++) {
        if (s_dev_cache[i].handle) {
            i2c_master_bus_rm_device(s_dev_cache[i].handle);
        }
    }
    s_dev_count = 0;
    memset(s_dev_cache, 0, sizeof(s_dev_cache));
    
    // Delete bus
    if (s_bus_handle) {
        i2c_del_master_bus(s_bus_handle);
        s_bus_handle = NULL;
    }
}

// Write then read (common I2C pattern)
int i2c_helper_write_read(uint8_t addr, const uint8_t *write_buf, size_t write_len,
                          uint8_t *read_buf, size_t read_len, uint32_t timeout_ms) {
    i2c_master_dev_handle_t dev = get_device_handle(addr);
    if (!dev) return -1;
    
    return i2c_master_transmit_receive(dev, write_buf, write_len, read_buf, read_len, 
                                       timeout_ms > 0 ? timeout_ms : DEFAULT_I2C_TRANS_TIMEOUT);
}

// Write only
int i2c_helper_write(uint8_t addr, const uint8_t *buf, size_t len, uint32_t timeout_ms) {
    i2c_master_dev_handle_t dev = get_device_handle(addr);
    if (!dev) return -1;
    
    return i2c_master_transmit(dev, buf, len, 
                               timeout_ms > 0 ? timeout_ms : DEFAULT_I2C_TRANS_TIMEOUT);
}

// Read only
int i2c_helper_read(uint8_t addr, uint8_t *buf, size_t len, uint32_t timeout_ms) {
    i2c_master_dev_handle_t dev = get_device_handle(addr);
    if (!dev) return -1;
    
    return i2c_master_receive(dev, buf, len, 
                              timeout_ms > 0 ? timeout_ms : DEFAULT_I2C_TRANS_TIMEOUT);
}

// Probe device at address
int i2c_helper_probe(uint8_t addr, uint32_t timeout_ms) {
    if (!s_bus_handle) return -1;
    
    return i2c_master_probe(s_bus_handle, addr, 
                            timeout_ms > 0 ? timeout_ms : DEFAULT_I2C_TRANS_TIMEOUT);
}
