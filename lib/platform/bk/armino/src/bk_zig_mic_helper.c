/**
 * bk_zig_mic_helper.c — Direct audio ADC microphone driver for Zig.
 *
 * Simple FIFO polling approach (matches speaker driver pattern):
 *   Microphone → Audio ADC → FIFO → CPU read (poll FIFO_EMPTY)
 */

#include <string.h>
#include <os/os.h>
#include <os/mem.h>
#include <components/log.h>
#include <driver/aud_adc.h>
#include <driver/aud_adc_types.h>
#include <driver/aud_common.h>

#define TAG "zig_mic"

static volatile int s_initialized = 0;

int bk_zig_mic_init(unsigned int sample_rate, unsigned char channels,
                    unsigned char dig_gain, unsigned char ana_gain)
{
    bk_err_t ret;

    BK_LOGI(TAG, "init: rate=%u ch=%u dig=0x%x ana=0x%x\r\n",
            sample_rate, channels, dig_gain, ana_gain);

    if (s_initialized) return 0;

    /* ADC config — must use LR for proper mic data (L-only gives noise) */
    aud_adc_config_t adc_cfg = DEFAULT_AUD_ADC_CONFIG();
    adc_cfg.adc_chl = AUD_ADC_CHL_LR;  /* LR mode: discard R in read() */
    adc_cfg.samp_rate = sample_rate;
    adc_cfg.adc_gain = dig_gain;        /* digital gain 0x00~0x3F */
    adc_cfg.clk_src = AUD_CLK_XTAL;    /* XTAL 26MHz (match official voice service) */

    ret = bk_aud_adc_init(&adc_cfg);
    BK_LOGI(TAG, "adc_init: %d\r\n", ret);
    if (ret != BK_OK) return (int)ret;

    /* Set mic mode (single-ended or differential) */
    ret = bk_aud_adc_set_mic_mode(AUD_MIC_MIC1, AUD_ADC_MODE_DIFFEN);
    BK_LOGI(TAG, "set_mic_mode: %d\r\n", ret);

    /* Set analog gain — critical for mic sensitivity! */
    ret = bk_aud_set_ana_mic0_gain(ana_gain);
    BK_LOGI(TAG, "ana_gain(0x%x): %d\r\n", ana_gain, ret);

    BK_LOGI(TAG, "calling adc_start...\r\n");
    ret = bk_aud_adc_start();
    BK_LOGI(TAG, "adc_start: %d\r\n", ret);
    if (ret != BK_OK) {
        bk_aud_adc_deinit();
        return (int)ret;
    }

    s_initialized = 1;
    BK_LOGI(TAG, "mic ready (FIFO polling, LR->L)\r\n");
    return 0;
}

void bk_zig_mic_deinit(void)
{
    if (!s_initialized) return;
    s_initialized = 0;
    bk_aud_adc_stop();
    bk_aud_adc_deinit();
    BK_LOGI(TAG, "mic deinitialized\r\n");
}

/**
 * Read PCM samples from mic ADC FIFO (L channel only).
 * ADC is in LR mode, so FIFO has interleaved L/R.
 * Read two words per sample: keep L, discard R.
 * Returns number of L samples read.
 */
int bk_zig_mic_read(short *buffer, unsigned int max_samples)
{
    if (!s_initialized) return -1;

    for (unsigned int i = 0; i < max_samples; i++) {
        /* Wait for L sample */
        uint32_t status;
        int timeout = 100000;
        do {
            bk_aud_adc_get_status(&status);
            timeout--;
        } while ((status & (1 << 14)) && timeout > 0);

        if (timeout <= 0) return (int)i;

        uint32_t fifo_data = 0;
        bk_aud_adc_get_fifo_data(&fifo_data);
        buffer[i] = (short)(fifo_data & 0xFFFF);  /* L channel */

        /* Wait for and discard R sample */
        timeout = 100000;
        do {
            bk_aud_adc_get_status(&status);
            timeout--;
        } while ((status & (1 << 14)) && timeout > 0);

        if (timeout > 0) {
            bk_aud_adc_get_fifo_data(&fifo_data);  /* discard R */
        }
    }

    return (int)max_samples;
}
