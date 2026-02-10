/**
 * bk_zig_adc_helper.c — SARADC read for Zig
 *
 * Uses the same ADC configuration as Armino's adc_key component.
 */

#include <string.h>
#include <components/log.h>
#include <driver/adc.h>
#include <driver/hal/hal_adc_types.h>

#define TAG "zig_adc"

int bk_zig_adc_read(unsigned int channel, unsigned short *value_out) {
    bk_err_t ret;

    ret = bk_adc_acquire();
    if (ret != BK_OK) {
        BK_LOGE(TAG, "acquire: %d\r\n", ret);
        return (int)ret;
    }

    ret = bk_adc_init((adc_chan_t)channel);
    if (ret != BK_OK) {
        BK_LOGE(TAG, "init(%d): %d\r\n", channel, ret);
        bk_adc_release();
        return (int)ret;
    }

    /* Configure exactly like Armino's adc_key */
    adc_config_t config = {0};
    config.chan = (adc_chan_t)channel;
    config.adc_mode = ADC_CONTINUOUS_MODE;
    config.src_clk = ADC_SCLK_XTAL_26M;
    config.clk = 3203125;
    config.saturate_mode = ADC_SATURATE_MODE_3;
    config.steady_ctrl = 7;
    config.adc_filter = 0;

    ret = bk_adc_set_config(&config);
    if (ret != BK_OK) {
        BK_LOGE(TAG, "set_config: %d\r\n", ret);
        bk_adc_deinit((adc_chan_t)channel);
        bk_adc_release();
        return (int)ret;
    }

    bk_adc_enable_bypass_clalibration();

    ret = bk_adc_start();
    if (ret != BK_OK) {
        BK_LOGE(TAG, "start: %d\r\n", ret);
        bk_adc_deinit((adc_chan_t)channel);
        bk_adc_release();
        return (int)ret;
    }

    uint16_t val = 0;
    ret = bk_adc_read(&val, 200);

    bk_adc_stop();
    bk_adc_deinit((adc_chan_t)channel);
    bk_adc_release();

    if (ret != BK_OK) {
        BK_LOGE(TAG, "read: %d\r\n", ret);
        return (int)ret;
    }

    *value_out = val;
    return 0;
}
