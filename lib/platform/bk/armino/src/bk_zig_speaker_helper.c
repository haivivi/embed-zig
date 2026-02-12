/**
 * bk_zig_speaker_helper.c — Direct DAC speaker driver for Zig.
 *
 * Simple approach: init DAC, write samples to FIFO directly.
 * No DMA, no pipeline, no ring buffer. Just DAC FIFO polling.
 */

#include <string.h>
#include <os/os.h>
#include <os/mem.h>
#include <components/log.h>
#include <driver/aud_dac.h>
#include <driver/aud_dac_types.h>
#include <driver/gpio.h>

#define TAG "zig_spk"
#define PA_CTRL_GPIO  0

extern void gpio_dev_unmap(unsigned int id);

static volatile int s_initialized = 0;

static void pa_enable(void)
{
    gpio_dev_unmap(PA_CTRL_GPIO);
    bk_gpio_enable_output(PA_CTRL_GPIO);
    bk_gpio_set_output_high(PA_CTRL_GPIO);
    BK_LOGI(TAG, "PA on (GPIO %d)\r\n", PA_CTRL_GPIO);
}

int bk_zig_speaker_init(unsigned int sample_rate, unsigned char channels,
                        unsigned char bits, unsigned char dig_gain)
{
    bk_err_t ret;

    BK_LOGI(TAG, "init: rate=%u ch=%u bits=%u gain=0x%x\r\n",
            sample_rate, channels, bits, dig_gain);

    if (s_initialized) return 0;

    /* Init DAC */
    aud_dac_config_t dac_cfg = DEFAULT_AUD_DAC_CONFIG();
    dac_cfg.dac_chl = (channels == 2) ? AUD_DAC_CHL_LR : AUD_DAC_CHL_L;
    dac_cfg.samp_rate = sample_rate;
    dac_cfg.dac_gain = 0x3F; /* MAX gain for testing */

    ret = bk_aud_dac_init(&dac_cfg);
    BK_LOGI(TAG, "dac_init: %d\r\n", ret);
    if (ret != BK_OK) return (int)ret;

    /* Set analog gain to max */
    ret = bk_aud_dac_set_ana_gain(0x3F);
    BK_LOGI(TAG, "ana_gain: %d\r\n", ret);

    ret = bk_aud_dac_start();
    BK_LOGI(TAG, "dac_start: %d\r\n", ret);
    if (ret != BK_OK) { bk_aud_dac_deinit(); return (int)ret; }

    /* Enable PA */
    rtos_delay_milliseconds(50);
    pa_enable();

    s_initialized = 1;
    BK_LOGI(TAG, "speaker ready\r\n");
    return 0;
}

void bk_zig_speaker_deinit(void)
{
    if (!s_initialized) return;
    s_initialized = 0;
    bk_gpio_set_output_low(PA_CTRL_GPIO);
    bk_aud_dac_stop();
    bk_aud_dac_deinit();
    BK_LOGI(TAG, "deinitialized\r\n");
}

/**
 * Write PCM samples to DAC FIFO with flow control.
 * Polls FIFO status — waits when full, writes when space available.
 * This ensures samples are consumed at the DAC sample rate.
 */
static int s_write_count = 0;

int bk_zig_speaker_write(const short *data, unsigned int samples)
{
    if (!s_initialized) return -1;

    s_write_count++;
    if (s_write_count <= 3) {
        BK_LOGI(TAG, "write #%d: %d samples, d[0..3]=%d %d %d %d\r\n",
                s_write_count, samples,
                (int)data[0], (int)data[1], (int)data[2], (int)data[3]);
    }

    for (unsigned int i = 0; i < samples; i++) {
        /* Wait until FIFO is not full */
        uint32_t status;
        int timeout = 100000;
        do {
            bk_aud_dac_get_status(&status);
            timeout--;
        } while ((status & (1 << 9)) && timeout > 0); /* bit 9 = DACL_FIFO_FULL */

        /* Write 16-bit signed sample to DAC FIFO */
        bk_aud_dac_write((uint32_t)(unsigned short)data[i]);
    }

    return (int)samples;
}

int bk_zig_speaker_set_volume(unsigned char gain)
{
    if (!s_initialized) return -1;
    return (int)bk_aud_dac_set_gain(gain);
}
