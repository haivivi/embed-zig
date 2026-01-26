// I2C helper - handles complex ESP-IDF types that Zig @cImport can't translate
// This file is bundled with the esp Zig package

#include "driver/i2c_master.h"
#include <string.h>

// I2C bus handle storage
static i2c_master_bus_handle_t s_bus_handle = NULL;

// Initialize I2C master bus
int i2c_helper_init(int sda, int scl, uint32_t freq_hz, int port) {
    i2c_master_bus_config_t bus_config = {
        .i2c_port = port,
        .sda_io_num = sda,
        .scl_io_num = scl,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .intr_priority = 0,
        .trans_queue_depth = 0,
        .flags = {
            .enable_internal_pullup = 1,
            .allow_pd = 0,
        },
    };

    return i2c_new_master_bus(&bus_config, &s_bus_handle);
}

// Deinitialize I2C bus
void i2c_helper_deinit(void) {
    if (s_bus_handle) {
        i2c_del_master_bus(s_bus_handle);
        s_bus_handle = NULL;
    }
}

// Write then read (common I2C pattern)
int i2c_helper_write_read(uint8_t addr, const uint8_t *write_buf, size_t write_len,
                          uint8_t *read_buf, size_t read_len, uint32_t timeout_ms) {
    if (!s_bus_handle) return -1;

    i2c_device_config_t dev_config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = addr,
        .scl_speed_hz = 400000,
        .scl_wait_us = 0,
        .flags = {
            .disable_ack_check = 0,
        },
    };

    i2c_master_dev_handle_t dev_handle = NULL;
    esp_err_t ret = i2c_master_bus_add_device(s_bus_handle, &dev_config, &dev_handle);
    if (ret != ESP_OK) return ret;

    ret = i2c_master_transmit_receive(dev_handle, write_buf, write_len,
                                       read_buf, read_len, timeout_ms);

    i2c_master_bus_rm_device(dev_handle);
    return ret;
}

// Write only
int i2c_helper_write(uint8_t addr, const uint8_t *buf, size_t len, uint32_t timeout_ms) {
    if (!s_bus_handle) return -1;

    i2c_device_config_t dev_config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = addr,
        .scl_speed_hz = 400000,
        .scl_wait_us = 0,
        .flags = {
            .disable_ack_check = 0,
        },
    };

    i2c_master_dev_handle_t dev_handle = NULL;
    esp_err_t ret = i2c_master_bus_add_device(s_bus_handle, &dev_config, &dev_handle);
    if (ret != ESP_OK) return ret;

    ret = i2c_master_transmit(dev_handle, buf, len, timeout_ms);

    i2c_master_bus_rm_device(dev_handle);
    return ret;
}

// Read only
int i2c_helper_read(uint8_t addr, uint8_t *buf, size_t len, uint32_t timeout_ms) {
    if (!s_bus_handle) return -1;

    i2c_device_config_t dev_config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = addr,
        .scl_speed_hz = 400000,
        .scl_wait_us = 0,
        .flags = {
            .disable_ack_check = 0,
        },
    };

    i2c_master_dev_handle_t dev_handle = NULL;
    esp_err_t ret = i2c_master_bus_add_device(s_bus_handle, &dev_config, &dev_handle);
    if (ret != ESP_OK) return ret;

    ret = i2c_master_receive(dev_handle, buf, len, timeout_ms);

    i2c_master_bus_rm_device(dev_handle);
    return ret;
}
