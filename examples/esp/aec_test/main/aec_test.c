/**
 * AEC Test - C version matching Zig implementation exactly
 * 
 * Only uses: esp-idf I2S TDM + I2C + esp-sr AEC
 * No ESP-ADF components
 */

#include <string.h>
#include <math.h>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_err.h"
#include "esp_heap_caps.h"
#include "driver/i2s_tdm.h"
#include "driver/i2s_std.h"
#include "driver/i2c_master.h"
#include "driver/gpio.h"
#include "esp_afe_aec.h"

static const char *TAG = "AEC_TEST";

// ============================================================================
// Hardware Configuration (Korvo2-V3) - Same as Zig
// ============================================================================
#define I2S_PORT            0
#define I2S_MCLK_PIN        16
#define I2S_BCLK_PIN        9
#define I2S_WS_PIN          45
#define I2S_DIN_PIN         10
#define I2S_DOUT_PIN        8

#define I2C_SDA_PIN         17
#define I2C_SCL_PIN         18
#define ES8311_ADDR         0x18
#define ES7210_ADDR         0x40

#define SAMPLE_RATE         16000
#define BITS_PER_SAMPLE     32
#define RX_CHANNELS         4       // 4 channels for TDM
#define TX_CHANNELS         4

#define DMA_DESC_NUM        6
#define DMA_FRAME_NUM       240

// ES7210 TDM output order: Ch1, Ch3, Ch2, Ch4 (interleaved per datasheet)
// With I2S STD 32-bit stereo:
//   L (32-bit) = [MIC1 (HI)] + [MIC3/REF (LO)]
//   R (32-bit) = [MIC2 (HI)] + [MIC4/OFF (LO)]
// We use "MR" format: interleaved [Mic, Ref] for AEC
#define AEC_INPUT_FORMAT    "MR"
#define AEC_FILTER_LENGTH   4

// ============================================================================
// ES8311 Registers (from Zig es8311.zig)
// ============================================================================
#define ES8311_RESET        0x00
#define ES8311_CLK_MGR_01   0x01
#define ES8311_CLK_MGR_02   0x02
#define ES8311_CLK_MGR_03   0x03
#define ES8311_CLK_MGR_04   0x04
#define ES8311_CLK_MGR_05   0x05
#define ES8311_CLK_MGR_06   0x06
#define ES8311_CLK_MGR_07   0x07
#define ES8311_CLK_MGR_08   0x08
#define ES8311_SDP_IN       0x09
#define ES8311_SDP_OUT      0x0A
#define ES8311_SYS_0B       0x0B
#define ES8311_SYS_0C       0x0C
#define ES8311_SYS_0D       0x0D
#define ES8311_SYS_0E       0x0E
#define ES8311_SYS_10       0x10
#define ES8311_SYS_11       0x11
#define ES8311_SYS_12       0x12
#define ES8311_SYS_13       0x13
#define ES8311_SYS_14       0x14
#define ES8311_ADC_15       0x15
#define ES8311_ADC_16       0x16
#define ES8311_ADC_17       0x17
#define ES8311_ADC_1B       0x1B
#define ES8311_ADC_1C       0x1C
#define ES8311_DAC_31       0x31
#define ES8311_DAC_32       0x32
#define ES8311_DAC_37       0x37
#define ES8311_GPIO_44      0x44
#define ES8311_GP_45        0x45

// ============================================================================
// ES7210 Registers (from Zig es7210.zig)
// ============================================================================
#define ES7210_RESET        0x00
#define ES7210_CLK_OFF      0x01
#define ES7210_MAIN_CLK     0x02
#define ES7210_MASTER_CLK   0x03
#define ES7210_LRCK_DIV_H   0x04
#define ES7210_LRCK_DIV_L   0x05
#define ES7210_POWER_DOWN   0x06
#define ES7210_OSR          0x07
#define ES7210_MODE_CFG     0x08
#define ES7210_TIME_CTL0    0x09
#define ES7210_TIME_CTL1    0x0A
#define ES7210_SDP_IF1      0x11
#define ES7210_SDP_IF2      0x12
// HPF registers (correct addresses from ESP-ADF)
#define ES7210_ADC34_HPF2   0x20
#define ES7210_ADC34_HPF1   0x21
#define ES7210_ADC12_HPF1   0x22
#define ES7210_ADC12_HPF2   0x23
// MUTE registers
#define ES7210_ADC34_MUTE   0x14
#define ES7210_ADC12_MUTE   0x15
#define ES7210_ANALOG       0x40
#define ES7210_MIC12_BIAS   0x41
#define ES7210_MIC34_BIAS   0x42
#define ES7210_MIC1_GAIN    0x43
#define ES7210_MIC2_GAIN    0x44
#define ES7210_MIC3_GAIN    0x45
#define ES7210_MIC4_GAIN    0x46
#define ES7210_MIC1_PWR     0x47
#define ES7210_MIC2_PWR     0x48
#define ES7210_MIC3_PWR     0x49
#define ES7210_MIC4_PWR     0x4A
#define ES7210_MIC12_PWR    0x4B
#define ES7210_MIC34_PWR    0x4C

// PA (Power Amplifier) GPIO
#define PA_ENABLE_GPIO      48

// ============================================================================
// Globals
// ============================================================================
static i2s_chan_handle_t rx_handle = NULL;
static i2s_chan_handle_t tx_handle = NULL;
static i2c_master_bus_handle_t i2c_bus = NULL;
static i2c_master_dev_handle_t es8311_dev = NULL;
static i2c_master_dev_handle_t es7210_dev = NULL;
static afe_aec_handle_t *aec_handle = NULL;

static int32_t *raw_buffer_32 = NULL;
static int16_t *raw_buffer_16 = NULL;
static int16_t *aec_output = NULL;
static int32_t *tx_buffer_32 = NULL;
static int aec_frame_size = 0;

// ============================================================================
// I2C helpers
// ============================================================================
static esp_err_t es8311_write(uint8_t reg, uint8_t val) {
    uint8_t data[2] = {reg, val};
    return i2c_master_transmit(es8311_dev, data, 2, 100);
}

static esp_err_t es8311_read(uint8_t reg, uint8_t *val) {
    return i2c_master_transmit_receive(es8311_dev, &reg, 1, val, 1, 100);
}

static esp_err_t es7210_write(uint8_t reg, uint8_t val) {
    uint8_t data[2] = {reg, val};
    return i2c_master_transmit(es7210_dev, data, 2, 100);
}

static esp_err_t es7210_read(uint8_t reg, uint8_t *val) {
    return i2c_master_transmit_receive(es7210_dev, &reg, 1, val, 1, 100);
}

static esp_err_t es7210_update(uint8_t reg, uint8_t mask, uint8_t val) {
    uint8_t regv;
    es7210_read(reg, &regv);
    regv = (regv & ~mask) | (val & mask);
    return es7210_write(reg, regv);
}

// ============================================================================
// ES8311 Init (from Zig es8311.zig open())
// ============================================================================
static esp_err_t es8311_init(void) {
    ESP_LOGI(TAG, "ES8311 init...");
    
    // Enhance I2C noise immunity
    es8311_write(ES8311_GPIO_44, 0x08);
    es8311_write(ES8311_GPIO_44, 0x08);
    
    // Initial register setup (from Zig)
    es8311_write(ES8311_CLK_MGR_01, 0x30);
    es8311_write(ES8311_CLK_MGR_02, 0x00);
    es8311_write(ES8311_CLK_MGR_03, 0x10);
    es8311_write(ES8311_ADC_16, 0x24);
    es8311_write(ES8311_CLK_MGR_04, 0x10);
    es8311_write(ES8311_CLK_MGR_05, 0x00);
    es8311_write(ES8311_SYS_0B, 0x00);
    es8311_write(ES8311_SYS_0C, 0x00);
    es8311_write(ES8311_SYS_10, 0x1F);
    es8311_write(ES8311_SYS_11, 0x7F);
    es8311_write(ES8311_RESET, 0x80);
    
    // Slave mode (master_mode = false in Zig)
    uint8_t regv;
    es8311_read(ES8311_RESET, &regv);
    regv &= 0xBF;  // Clear master bit
    es8311_write(ES8311_RESET, regv);
    
    // MCLK source (use_mclk = true, invert_mclk = false)
    regv = 0x3F & 0x7F;  // use_mclk=true -> clear bit7
    es8311_write(ES8311_CLK_MGR_01, regv);
    
    // SCLK (invert_sclk = false)
    es8311_read(ES8311_CLK_MGR_06, &regv);
    regv &= ~0x20;
    es8311_write(ES8311_CLK_MGR_06, regv);
    
    // Additional init
    es8311_write(ES8311_SYS_13, 0x10);
    es8311_write(ES8311_ADC_1B, 0x0A);
    es8311_write(ES8311_ADC_1C, 0x6A);
    
    // DAC reference for AEC (no_dac_ref = false)
    es8311_write(ES8311_GPIO_44, 0x58);
    
    ESP_LOGI(TAG, "ES8311 init done");
    return ESP_OK;
}

// ============================================================================
// ES8311 Start (from Zig es8311.zig start())
// ============================================================================
static esp_err_t es8311_start(void) {
    uint8_t regv = 0x80;  // master_mode = false
    es8311_write(ES8311_RESET, regv);
    
    regv = 0x3F & 0x7F;  // use_mclk = true
    es8311_write(ES8311_CLK_MGR_01, regv);
    
    // Configure SDP (both mode)
    uint8_t dac_iface, adc_iface;
    es8311_read(ES8311_SDP_IN, &dac_iface);
    es8311_read(ES8311_SDP_OUT, &adc_iface);
    dac_iface &= 0xBF;
    adc_iface &= 0xBF;
    dac_iface &= ~0x40;
    adc_iface &= ~0x40;
    es8311_write(ES8311_SDP_IN, dac_iface);
    es8311_write(ES8311_SDP_OUT, adc_iface);
    
    es8311_write(ES8311_ADC_17, 0xBF);
    es8311_write(ES8311_SYS_0E, 0x02);
    es8311_write(ES8311_SYS_12, 0x00);  // DAC mode
    es8311_write(ES8311_SYS_14, 0x1A);
    
    // digital_mic = false
    es8311_read(ES8311_SYS_14, &regv);
    regv &= ~0x40;
    es8311_write(ES8311_SYS_14, regv);
    
    es8311_write(ES8311_SYS_0D, 0x01);
    es8311_write(ES8311_ADC_15, 0x40);
    es8311_write(ES8311_DAC_37, 0x08);
    es8311_write(ES8311_GP_45, 0x00);
    
    return ESP_OK;
}

// ============================================================================
// ES8311 Set Volume
// ============================================================================
static esp_err_t es8311_set_volume(uint8_t vol) {
    return es8311_write(ES8311_DAC_32, vol);
}

// ============================================================================
// ES7210 Init (from Zig es7210.zig open())
// ============================================================================
static esp_err_t es7210_init(void) {
    ESP_LOGI(TAG, "ES7210 init...");
    
    // Reset
    es7210_write(ES7210_RESET, 0xFF);
    vTaskDelay(pdMS_TO_TICKS(10));
    es7210_write(ES7210_RESET, 0x41);
    
    // Clock setup
    es7210_write(ES7210_CLK_OFF, 0x3F);
    es7210_write(ES7210_TIME_CTL0, 0x30);
    es7210_write(ES7210_TIME_CTL1, 0x30);
    
    // HPF setup (matching ESP-ADF exactly)
    es7210_write(ES7210_ADC12_HPF2, 0x2A);  // 0x23 = 0x2A
    es7210_write(ES7210_ADC12_HPF1, 0x0A);  // 0x22 = 0x0A
    es7210_write(ES7210_ADC34_HPF2, 0x0A);  // 0x20 = 0x0A
    es7210_write(ES7210_ADC34_HPF1, 0x2A);  // 0x21 = 0x2A
    
    // Unmute all ADCs
    es7210_write(ES7210_ADC12_MUTE, 0x00);  // 0x15 = unmute ADC1/2
    es7210_write(ES7210_ADC34_MUTE, 0x00);  // 0x14 = unmute ADC3/4
    
    // Slave mode
    es7210_update(ES7210_MODE_CFG, 0x01, 0x00);
    
    // Analog power and bias
    es7210_write(ES7210_ANALOG, 0x43);
    es7210_write(ES7210_MIC12_BIAS, 0x70);
    es7210_write(ES7210_MIC34_BIAS, 0x70);
    es7210_write(ES7210_OSR, 0x20);
    
    // Clock divider with DLL
    es7210_write(ES7210_MAIN_CLK, 0xC1);
    
    // LRCK divider for 16kHz with MCLK=8.192MHz (512x)
    // LRCK_DIV = 8192000 / 16000 = 512 = 0x0200
    es7210_write(0x04, 0x02);  // ES7210_LRCK_DIVH
    es7210_write(0x05, 0x00);  // ES7210_LRCK_DIVL
    
    // ========================================================
    // EXACTLY following ESP-ADF es7210_mic_select() function
    // for ES7210_INPUT_MIC1 | ES7210_INPUT_MIC2 | ES7210_INPUT_MIC3
    // ========================================================
    
    // Step 1: Disable all MIC gain first (clear bit 4)
    for (int i = 0; i < 4; i++) {
        es7210_update(ES7210_MIC1_GAIN + i, 0x10, 0x00);
    }
    
    // Step 2: Power down all MICs
    es7210_write(ES7210_MIC12_PWR, 0xFF);
    es7210_write(ES7210_MIC34_PWR, 0xFF);
    
    // Step 3: Enable MIC1 (30dB gain for better sensitivity)
    ESP_LOGI(TAG, "Enable ES7210_INPUT_MIC1");
    es7210_update(ES7210_CLK_OFF, 0x0B, 0x00);  // Clear bits 0,1,3
    es7210_write(ES7210_MIC12_PWR, 0x00);       // Power up
    es7210_update(ES7210_MIC1_GAIN, 0x10, 0x10); // Enable PGA
    es7210_update(ES7210_MIC1_GAIN, 0x0F, 0x0A); // GAIN_30DB = 10
    
    // Step 4: Enable MIC2 (30dB gain)
    ESP_LOGI(TAG, "Enable ES7210_INPUT_MIC2");
    es7210_update(ES7210_CLK_OFF, 0x0B, 0x00);
    es7210_write(ES7210_MIC12_PWR, 0x00);
    es7210_update(ES7210_MIC2_GAIN, 0x10, 0x10); // Enable PGA
    es7210_update(ES7210_MIC2_GAIN, 0x0F, 0x0A); // GAIN_30DB = 10
    
    // Step 5: Enable MIC3/REF (30dB gain)
    ESP_LOGI(TAG, "Enable ES7210_INPUT_MIC3");
    es7210_update(ES7210_CLK_OFF, 0x15, 0x00);
    es7210_write(ES7210_MIC34_PWR, 0x00);
    es7210_update(ES7210_MIC3_GAIN, 0x10, 0x10); // Enable PGA
    es7210_update(ES7210_MIC3_GAIN, 0x0F, 0x0A); // GAIN_30DB = 10
    
    // Step 6: Enable TDM mode (ES7210 internal, but I2S uses STD mode!)
    es7210_write(ES7210_SDP_IF2, 0x02);
    ESP_LOGW(TAG, "ES7210 TDM enabled (0x02), but I2S uses STD mode");
    
    // Set I2S format AND force 16-bit width
    uint8_t adc_iface;
    es7210_read(ES7210_SDP_IF1, &adc_iface);
    ESP_LOGI(TAG, "ES7210 SDP_IF1 before = 0x%02X", adc_iface);
    adc_iface &= 0x1C;  // Clear format (bits 0-1) and width (bits 5-7)
    adc_iface |= 0x00;  // I2S Philips format (bits 0-1)
    adc_iface |= 0x60;  // 16-bit word length (bits 5-7 = 011)
    es7210_write(ES7210_SDP_IF1, adc_iface);
    ESP_LOGI(TAG, "ES7210 SDP_IF1 set to 0x%02X (16-bit, I2S)", adc_iface);
    
    // Final analog
    es7210_write(ES7210_ANALOG, 0x43);
    
    // Start sequence (critical!)
    es7210_write(ES7210_RESET, 0x71);
    es7210_write(ES7210_RESET, 0x41);
    
    ESP_LOGI(TAG, "ES7210 init done");
    return ESP_OK;
}

// ============================================================================
// PA Init (Power Amplifier enable)
// ============================================================================
static esp_err_t pa_init(void) {
    gpio_config_t io_conf = {
        .pin_bit_mask = (1ULL << PA_ENABLE_GPIO),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&io_conf));
    gpio_set_level(PA_ENABLE_GPIO, 1);  // Enable PA
    ESP_LOGI(TAG, "PA enabled (GPIO %d)", PA_ENABLE_GPIO);
    return ESP_OK;
}

// ============================================================================
// ES7210 Start (from Zig es7210.zig start())
// ============================================================================
static esp_err_t es7210_start(void) {
    uint8_t clock_off_reg;
    es7210_read(ES7210_CLK_OFF, &clock_off_reg);
    
    es7210_write(ES7210_CLK_OFF, clock_off_reg);
    es7210_write(ES7210_POWER_DOWN, 0x00);
    es7210_write(ES7210_ANALOG, 0x43);
    es7210_write(ES7210_MIC1_PWR, 0x08);
    es7210_write(ES7210_MIC2_PWR, 0x08);
    es7210_write(ES7210_MIC3_PWR, 0x08);
    es7210_write(ES7210_MIC4_PWR, 0x08);
    
    // ========================================================
    // EXACTLY following ESP-ADF es7210_start() function
    // ========================================================
    
    // Note: clock_reg_value from es7210_mic_select when enabling MIC1+MIC2+MIC3
    // After clearing 0x0B for MIC1/MIC2 and 0x15 for MIC3:
    // Initial 0x3F, clear 0x0B -> 0x34, clear 0x15 -> 0x20
    uint8_t clock_reg_value = 0x20;
    
    es7210_write(ES7210_CLK_OFF, clock_reg_value);
    es7210_write(ES7210_POWER_DOWN, 0x00);
    es7210_write(ES7210_ANALOG, 0x43);
    es7210_write(ES7210_MIC1_PWR, 0x08);
    es7210_write(ES7210_MIC2_PWR, 0x08);
    es7210_write(ES7210_MIC3_PWR, 0x08);
    es7210_write(ES7210_MIC4_PWR, 0x08);
    
    // Re-call mic_select logic (same as in init)
    for (int i = 0; i < 4; i++) {
        es7210_update(ES7210_MIC1_GAIN + i, 0x10, 0x00);
    }
    es7210_write(ES7210_MIC12_PWR, 0xFF);
    es7210_write(ES7210_MIC34_PWR, 0xFF);
    
    // MIC1 (30dB)
    es7210_update(ES7210_CLK_OFF, 0x0B, 0x00);
    es7210_write(ES7210_MIC12_PWR, 0x00);
    es7210_update(ES7210_MIC1_GAIN, 0x10, 0x10);
    es7210_update(ES7210_MIC1_GAIN, 0x0F, 0x0A);  // 30dB
    
    // MIC2 (30dB)
    es7210_update(ES7210_CLK_OFF, 0x0B, 0x00);
    es7210_write(ES7210_MIC12_PWR, 0x00);
    es7210_update(ES7210_MIC2_GAIN, 0x10, 0x10);
    es7210_update(ES7210_MIC2_GAIN, 0x0F, 0x0A);  // 30dB
    
    // MIC3/REF (30dB)
    es7210_update(ES7210_CLK_OFF, 0x15, 0x00);
    es7210_write(ES7210_MIC34_PWR, 0x00);
    es7210_update(ES7210_MIC3_GAIN, 0x10, 0x10);
    es7210_update(ES7210_MIC3_GAIN, 0x0F, 0x0A);  // 30dB
    
    // Enable TDM mode
    es7210_write(ES7210_SDP_IF2, 0x02);
    
    ESP_LOGI(TAG, "ES7210 started (MIC1+MIC2+MIC3, TDM, gain=30dB)");
    return ESP_OK;
}

// ============================================================================
// I2C Init
// ============================================================================
static esp_err_t i2c_init(void) {
    i2c_master_bus_config_t bus_cfg = {
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .i2c_port = I2C_NUM_0,
        .scl_io_num = I2C_SCL_PIN,
        .sda_io_num = I2C_SDA_PIN,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    ESP_ERROR_CHECK(i2c_new_master_bus(&bus_cfg, &i2c_bus));
    
    i2c_device_config_t dev_cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ES8311_ADDR,
        .scl_speed_hz = 100000,
    };
    ESP_ERROR_CHECK(i2c_master_bus_add_device(i2c_bus, &dev_cfg, &es8311_dev));
    
    dev_cfg.device_address = ES7210_ADDR;
    ESP_ERROR_CHECK(i2c_master_bus_add_device(i2c_bus, &dev_cfg, &es7210_dev));
    
    ESP_LOGI(TAG, "I2C init done");
    return ESP_OK;
}

// ============================================================================
// I2S Standard Init - Stereo 32-bit (like ESP-ADF does!)
// ES7210 TDM enabled internally, but I2S controller uses standard mode
// ============================================================================
static esp_err_t i2s_init(void) {
    ESP_LOGI(TAG, "I2S STD init: port=%d, rate=%d, stereo 32-bit",
             I2S_PORT, SAMPLE_RATE);
    
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_PORT, I2S_ROLE_MASTER);
    chan_cfg.dma_desc_num = DMA_DESC_NUM;
    chan_cfg.dma_frame_num = DMA_FRAME_NUM;
    
    ESP_ERROR_CHECK(i2s_new_channel(&chan_cfg, &tx_handle, &rx_handle));
    
    // RX - Standard stereo 32-bit (RMNM format: 4x16bit in 2x32bit)
    i2s_std_config_t rx_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(SAMPLE_RATE),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_32BIT, I2S_SLOT_MODE_STEREO),
        .gpio_cfg = {
            .mclk = I2S_MCLK_PIN,
            .bclk = I2S_BCLK_PIN,
            .ws = I2S_WS_PIN,
            .dout = GPIO_NUM_NC,
            .din = I2S_DIN_PIN,
        },
    };
    rx_cfg.clk_cfg.mclk_multiple = I2S_MCLK_MULTIPLE_256;
    ESP_ERROR_CHECK(i2s_channel_init_std_mode(rx_handle, &rx_cfg));
    
    // TX - Standard stereo 32-bit
    i2s_std_config_t tx_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(SAMPLE_RATE),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_32BIT, I2S_SLOT_MODE_STEREO),
        .gpio_cfg = {
            .mclk = GPIO_NUM_NC,
            .bclk = GPIO_NUM_NC,
            .ws = GPIO_NUM_NC,
            .dout = I2S_DOUT_PIN,
            .din = GPIO_NUM_NC,
        },
    };
    ESP_ERROR_CHECK(i2s_channel_init_std_mode(tx_handle, &tx_cfg));
    
    ESP_ERROR_CHECK(i2s_channel_enable(rx_handle));
    ESP_ERROR_CHECK(i2s_channel_enable(tx_handle));
    
    ESP_LOGI(TAG, "I2S STD stereo 32-bit init done (for RMNM format)");
    return ESP_OK;
}

// ============================================================================
// AEC Init
// ============================================================================
static esp_err_t aec_init(void) {
    ESP_LOGI(TAG, "AEC init: format=%s, filter=%d", AEC_INPUT_FORMAT, AEC_FILTER_LENGTH);
    
    aec_handle = afe_aec_create(AEC_INPUT_FORMAT, AEC_FILTER_LENGTH, AFE_TYPE_VC, AFE_MODE_LOW_COST);
    if (!aec_handle) {
        ESP_LOGE(TAG, "AEC create failed");
        return ESP_FAIL;
    }
    
    aec_frame_size = aec_handle->frame_size;
    int total_ch = aec_handle->pcm_config.total_ch_num;
    
    ESP_LOGI(TAG, "AEC: frame=%d, ch=%d, mic=%d, ref=%d",
             aec_frame_size, total_ch,
             aec_handle->pcm_config.mic_num,
             aec_handle->pcm_config.ref_num);
    
    raw_buffer_32 = heap_caps_malloc(aec_frame_size * total_ch * sizeof(int32_t), MALLOC_CAP_SPIRAM);
    raw_buffer_16 = heap_caps_malloc(aec_frame_size * total_ch * sizeof(int16_t), MALLOC_CAP_SPIRAM);
    aec_output = heap_caps_aligned_alloc(16, aec_frame_size * sizeof(int16_t), MALLOC_CAP_SPIRAM);
    tx_buffer_32 = heap_caps_malloc(aec_frame_size * TX_CHANNELS * sizeof(int32_t), MALLOC_CAP_SPIRAM);
    
    if (!raw_buffer_32 || !raw_buffer_16 || !aec_output || !tx_buffer_32) {
        ESP_LOGE(TAG, "Buffer alloc failed");
        return ESP_ERR_NO_MEM;
    }
    
    ESP_LOGI(TAG, "Buffers: raw32=%p raw16=%p aec=%p tx32=%p",
             raw_buffer_32, raw_buffer_16, aec_output, tx_buffer_32);
    return ESP_OK;
}

// ============================================================================
// Audio Task - AEC Processing with Sine Wave Test
// ============================================================================

// Test mode: 0=passthrough, 1=sine+AEC
#define TEST_MODE 1
#define SINE_FREQ 500       // Hz
#define SINE_AMP  8000      // amplitude (max 32767)

static void audio_task(void *arg) {
    ESP_LOGI(TAG, "Audio task: AEC + SINE TEST (freq=%dHz)", SINE_FREQ);
    
    // Print ES7210 register status
    uint8_t reg_val;
    es7210_read(ES7210_SDP_IF2, &reg_val);
    ESP_LOGW(TAG, "ES7210 TDM=%s", (reg_val & 0x02) ? "ON" : "OFF");
    
    // Allocate AEC input buffer
    int16_t *aec_input = heap_caps_malloc(aec_frame_size * 2 * sizeof(int16_t), MALLOC_CAP_SPIRAM);
    if (!aec_input) {
        ESP_LOGE(TAG, "AEC input buffer alloc failed");
        vTaskDelete(NULL);
        return;
    }
    
    // Pre-calculate sine wave table (one period)
    const int sine_period = SAMPLE_RATE / SINE_FREQ;
    int16_t *sine_table = malloc(sine_period * sizeof(int16_t));
    for (int i = 0; i < sine_period; i++) {
        sine_table[i] = (int16_t)(SINE_AMP * sin(2.0 * M_PI * i / sine_period));
    }
    ESP_LOGI(TAG, "Sine table: period=%d samples", sine_period);
    
    size_t bytes_read, bytes_written;
    int frame_count = 0;
    int sine_idx = 0;
    
    while (1) {
        // Read stereo 32-bit from I2S
        size_t to_read = aec_frame_size * 2 * sizeof(int32_t);
        esp_err_t ret = i2s_channel_read(rx_handle, raw_buffer_32, to_read, &bytes_read, pdMS_TO_TICKS(1000));
        
        if (ret == ESP_ERR_TIMEOUT) {
            ESP_LOGW(TAG, "I2S read timeout");
            continue;
        }
        if (ret != ESP_OK || bytes_read == 0) continue;
        
        // ========== Extract MIC1 and REF from TDM data ==========
        int64_t mic_energy = 0, ref_energy = 0;
        
        for (int i = 0; i < aec_frame_size; i++) {
            int32_t L = raw_buffer_32[i * 2 + 0];
            int16_t mic1 = (int16_t)(L >> 16);      // MIC1 = L_HI
            int16_t ref  = (int16_t)(L & 0xFFFF);   // REF  = L_LO (MIC3)
            
            // Pack into "MR" format
            aec_input[i * 2 + 0] = mic1;
            aec_input[i * 2 + 1] = ref;
            
            mic_energy += (int64_t)mic1 * mic1;
            ref_energy += (int64_t)ref * ref;
        }
        
        // ========== Run AEC ==========
        afe_aec_process(aec_handle, aec_input, aec_output);
        
        // ========== Calculate output energy ==========
        int64_t out_energy = 0;
        for (int i = 0; i < aec_frame_size; i++) {
            out_energy += (int64_t)aec_output[i] * aec_output[i];
        }
        
        // ========== Generate output: Sine + AEC ==========
        for (int i = 0; i < aec_frame_size; i++) {
            int16_t sine_sample = sine_table[sine_idx];
            sine_idx = (sine_idx + 1) % sine_period;
            
            #if TEST_MODE == 1
            // Mix sine wave with AEC output (boost mic by 4x)
            int32_t mixed = (sine_sample / 2) + (aec_output[i] * 4);
            if (mixed > 32767) mixed = 32767;
            if (mixed < -32768) mixed = -32768;
            int32_t sample32 = ((int32_t)mixed) << 16;
            #else
            // Pure AEC output
            int32_t sample32 = ((int32_t)aec_output[i]) << 16;
            #endif
            
            tx_buffer_32[i * 2 + 0] = sample32;
            tx_buffer_32[i * 2 + 1] = sample32;
        }
        
        // Log every 50 frames
        if (frame_count % 50 == 0) {
            int mic_rms = (int)sqrt((double)mic_energy / aec_frame_size);
            int ref_rms = (int)sqrt((double)ref_energy / aec_frame_size);
            int out_rms = (int)sqrt((double)out_energy / aec_frame_size);
            ESP_LOGI(TAG, "AEC: MIC=%d REF=%d OUT=%d (sine=%dHz)", 
                     mic_rms, ref_rms, out_rms, SINE_FREQ);
        }
        
        i2s_channel_write(tx_handle, tx_buffer_32, aec_frame_size * 2 * sizeof(int32_t), &bytes_written, portMAX_DELAY);
        frame_count++;
    }
    
    free(aec_input);
    free(sine_table);
}

// ============================================================================
// Main
// ============================================================================
void app_main(void) {
    ESP_LOGI(TAG, "=== AEC Test (C) - Matching Zig ===");
    
    ESP_ERROR_CHECK(i2c_init());
    ESP_ERROR_CHECK(es8311_init());
    ESP_ERROR_CHECK(es7210_init());
    ESP_ERROR_CHECK(i2s_init());
    
    // Start ES8311 and set volume
    ESP_ERROR_CHECK(es8311_start());
    es8311_set_volume(150);  // Medium volume
    
    // Enable PA (Power Amplifier) - CRITICAL!
    ESP_ERROR_CHECK(pa_init());
    
    // Small delay for clocks to stabilize
    vTaskDelay(pdMS_TO_TICKS(10));
    
    // Start ES7210 ADC
    ESP_ERROR_CHECK(es7210_start());
    
    // Debug: Read ES7210 registers after start
    uint8_t reg_val;
    ESP_LOGW(TAG, "=== ES7210 Register Dump ===");
    es7210_read(ES7210_CLK_OFF, &reg_val);
    ESP_LOGW(TAG, "CLK_OFF (0x01): 0x%02X", reg_val);
    es7210_read(ES7210_SDP_IF1, &reg_val);
    ESP_LOGW(TAG, "SDP_IF1 (0x11): 0x%02X", reg_val);
    es7210_read(ES7210_SDP_IF2, &reg_val);
    ESP_LOGW(TAG, "SDP_IF2 (0x12): 0x%02X (TDM=%s)", reg_val, (reg_val & 0x02) ? "ON" : "OFF");
    es7210_read(ES7210_ANALOG, &reg_val);
    ESP_LOGW(TAG, "ANALOG (0x40): 0x%02X", reg_val);
    es7210_read(ES7210_MIC12_BIAS, &reg_val);
    ESP_LOGW(TAG, "MIC12_BIAS (0x41): 0x%02X", reg_val);
    es7210_read(ES7210_MIC34_BIAS, &reg_val);
    ESP_LOGW(TAG, "MIC34_BIAS (0x42): 0x%02X", reg_val);
    es7210_read(ES7210_MIC1_PWR, &reg_val);
    ESP_LOGW(TAG, "MIC1_PWR (0x47): 0x%02X", reg_val);
    es7210_read(ES7210_MIC2_PWR, &reg_val);
    ESP_LOGW(TAG, "MIC2_PWR (0x48): 0x%02X", reg_val);
    es7210_read(ES7210_MIC3_PWR, &reg_val);
    ESP_LOGW(TAG, "MIC3_PWR (0x49): 0x%02X", reg_val);
    es7210_read(ES7210_MIC12_PWR, &reg_val);
    ESP_LOGW(TAG, "MIC12_PWR (0x4B): 0x%02X", reg_val);
    es7210_read(ES7210_MIC34_PWR, &reg_val);
    ESP_LOGW(TAG, "MIC34_PWR (0x4C): 0x%02X", reg_val);
    es7210_read(ES7210_MIC1_GAIN, &reg_val);
    ESP_LOGW(TAG, "MIC1_GAIN (0x43): 0x%02X", reg_val);
    es7210_read(ES7210_MIC2_GAIN, &reg_val);
    ESP_LOGW(TAG, "MIC2_GAIN (0x44): 0x%02X", reg_val);
    es7210_read(ES7210_MIC3_GAIN, &reg_val);
    ESP_LOGW(TAG, "MIC3_GAIN (0x45): 0x%02X", reg_val);
    es7210_read(ES7210_ADC12_MUTE, &reg_val);
    ESP_LOGW(TAG, "ADC12_MUTE (0x15): 0x%02X", reg_val);
    es7210_read(ES7210_ADC34_MUTE, &reg_val);
    ESP_LOGW(TAG, "ADC34_MUTE (0x14): 0x%02X", reg_val);
    es7210_read(ES7210_ADC12_HPF1, &reg_val);
    ESP_LOGW(TAG, "ADC12_HPF1 (0x22): 0x%02X", reg_val);
    es7210_read(ES7210_ADC12_HPF2, &reg_val);
    ESP_LOGW(TAG, "ADC12_HPF2 (0x23): 0x%02X", reg_val);
    ESP_LOGW(TAG, "=== End Register Dump ===");
    
    ESP_ERROR_CHECK(aec_init());
    
    ESP_LOGI(TAG, "All init done, starting audio...");
    xTaskCreatePinnedToCore(audio_task, "audio", 8192, NULL, 5, NULL, 1);
}
