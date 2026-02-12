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

#define TAG "zig_mic"

static volatile int s_initialized = 0;

int bk_zig_mic_init(unsigned int sample_rate, unsigned char channels, unsigned char gain)
{
    bk_err_t ret;

    BK_LOGI(TAG, "init: rate=%u ch=%u gain=0x%x\r\n", sample_rate, channels, gain);

    if (s_initialized) return 0;

    aud_adc_config_t adc_cfg = DEFAULT_AUD_ADC_CONFIG();
    adc_cfg.adc_chl = (channels == 2) ? AUD_ADC_CHL_LR : AUD_ADC_CHL_L;
    adc_cfg.samp_rate = sample_rate;
    adc_cfg.adc_gain = gain;

    ret = bk_aud_adc_init(&adc_cfg);
    BK_LOGI(TAG, "adc_init: %d\r\n", ret);
    if (ret != BK_OK) return (int)ret;

    BK_LOGI(TAG, "calling adc_start...\r\n");
    ret = bk_aud_adc_start();
    BK_LOGI(TAG, "adc_start: %d\r\n", ret);
    if (ret != BK_OK) {
        bk_aud_adc_deinit();
        return (int)ret;
    }

    s_initialized = 1;
    BK_LOGI(TAG, "mic ready (FIFO polling)\r\n");
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
 * Read PCM samples from mic ADC FIFO.
 * Polls FIFO status — waits when empty, reads when data available.
 * For mono: ADC FIFO returns 32-bit values with L channel in lower 16 bits.
 * Returns number of samples read.
 */
int bk_zig_mic_read(short *buffer, unsigned int max_samples)
{
    if (!s_initialized) return -1;

    for (unsigned int i = 0; i < max_samples; i++) {
        /* Wait until FIFO is not empty */
        uint32_t status;
        int timeout = 100000;
        do {
            bk_aud_adc_get_status(&status);
            timeout--;
        } while ((status & (1 << 14)) && timeout > 0); /* bit 14 = ADCL_FIFO_EMPTY */

        if (timeout <= 0) {
            return (int)i; /* return what we got so far */
        }

        /* Read one sample from FIFO */
        uint32_t fifo_data = 0;
        bk_aud_adc_get_fifo_data(&fifo_data);

        /* Extract L channel (lower 16 bits) as signed */
        buffer[i] = (short)(fifo_data & 0xFFFF);
    }

    return (int)max_samples;
}
