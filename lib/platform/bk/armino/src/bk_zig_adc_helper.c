/**
 * bk_zig_adc_helper.c — SARADC read for Zig
 *
 * Simple one-shot ADC read on a given channel.
 */

#include <string.h>
#include <components/log.h>

/* Armino SARADC API (from bk_saradc.h / adc_driver.h) */
extern int bk_adc_acquire(void);
extern int bk_adc_init(int adc_chan);
extern int bk_adc_start(void);
extern int bk_adc_read_raw(unsigned short *buf, unsigned int size, unsigned int timeout);
extern int bk_adc_stop(void);
extern int bk_adc_deinit(int chan);
extern int bk_adc_release(void);

#define TAG "zig_adc"

int bk_zig_adc_read(unsigned int channel, unsigned short *value_out) {
    int ret;

    ret = bk_adc_acquire();
    if (ret != 0) {
        BK_LOGE(TAG, "adc_acquire failed: %d\r\n", ret);
        return ret;
    }

    ret = bk_adc_init((int)channel);
    if (ret != 0) {
        BK_LOGE(TAG, "adc_init(%d) failed: %d\r\n", channel, ret);
        bk_adc_release();
        return ret;
    }

    ret = bk_adc_start();
    if (ret != 0) {
        BK_LOGE(TAG, "adc_start failed: %d\r\n", ret);
        bk_adc_deinit((int)channel);
        bk_adc_release();
        return ret;
    }

    unsigned short buf[1] = {0};
    ret = bk_adc_read_raw(buf, 1, 1000);

    bk_adc_stop();
    bk_adc_deinit((int)channel);
    bk_adc_release();

    if (ret != 0) {
        BK_LOGE(TAG, "adc_read_raw failed: %d\r\n", ret);
        return ret;
    }

    *value_out = buf[0];
    return 0;
}
