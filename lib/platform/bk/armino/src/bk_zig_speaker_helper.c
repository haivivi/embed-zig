/**
 * bk_zig_speaker_helper.c — DMA-based speaker driver for BK7258.
 *
 * Uses DAC DMA to transfer audio data from ring buffer to DAC FIFO.
 * Provides smooth, continuous playback without CPU FIFO polling.
 *
 * Flow: bk_zig_speaker_write() → Ring Buffer → DMA → DAC FIFO → Analog Out → PA → Speaker
 */

#include <string.h>
#include <os/os.h>
#include <os/mem.h>
#include <components/log.h>
#include <driver/aud_dac.h>
#include <driver/aud_dac_types.h>
#include <driver/aud_common.h>
#include <driver/dma.h>
#include <driver/audio_ring_buff.h>
#include <driver/gpio.h>

#define TAG "zig_spk"
#define PA_CTRL_GPIO    0
#define FRAME_MS        20
#define RB_SAFE_MARGIN  8

extern void gpio_dev_unmap(unsigned int id);

static volatile int s_initialized = 0;
static dma_id_t s_dma_id;
static int8_t *s_rb_buf = NULL;
static RingBufferContext s_rb;
static beken_semaphore_t s_sem;
static uint32_t s_frame_bytes = 0;

static void spk_dma_isr(void)
{
    rtos_set_semaphore(&s_sem);
}

static void pa_enable(void)
{
    gpio_dev_unmap(PA_CTRL_GPIO);
    bk_gpio_enable_output(PA_CTRL_GPIO);
    bk_gpio_set_output_high(PA_CTRL_GPIO);
}

int bk_zig_speaker_init(unsigned int sample_rate, unsigned char channels,
                        unsigned char bits, unsigned char dig_gain)
{
    bk_err_t ret;

    BK_LOGI(TAG, "init: rate=%u ch=%u bits=%u gain=0x%x\r\n",
            sample_rate, channels, bits, dig_gain);

    if (s_initialized) return 0;

    /* Frame size in bytes: samples_per_frame * bytes_per_sample */
    s_frame_bytes = sample_rate * FRAME_MS / 1000 * (bits / 8);

    /* DAC init */
    aud_dac_config_t dac_cfg = DEFAULT_AUD_DAC_CONFIG();
    dac_cfg.dac_chl = (channels == 2) ? AUD_DAC_CHL_LR : AUD_DAC_CHL_L;
    dac_cfg.samp_rate = sample_rate;
    dac_cfg.dac_gain = dig_gain;
    dac_cfg.clk_src = AUD_CLK_XTAL;

    ret = bk_aud_dac_init(&dac_cfg);
    if (ret != BK_OK) { BK_LOGE(TAG, "dac_init fail: %d\r\n", ret); return (int)ret; }

    bk_aud_dac_set_ana_gain(0x0A);  /* official default */

    /* DMA setup */
    s_dma_id = bk_dma_alloc(DMA_DEV_AUDIO);
    if (s_dma_id < DMA_ID_0 || s_dma_id >= DMA_ID_MAX) {
        BK_LOGE(TAG, "dma alloc fail\r\n");
        bk_aud_dac_deinit();
        return -1;
    }

    /* Ring buffer: 2 frames + safety */
    uint32_t rb_size = s_frame_bytes * 2 + RB_SAFE_MARGIN;
    s_rb_buf = (int8_t *)os_malloc(rb_size);
    if (!s_rb_buf) {
        BK_LOGE(TAG, "rb malloc fail\r\n");
        bk_dma_free(DMA_DEV_AUDIO, s_dma_id);
        bk_aud_dac_deinit();
        return -1;
    }

    ring_buffer_init(&s_rb, (uint8_t *)s_rb_buf, rb_size, s_dma_id, RB_DMA_TYPE_READ);

    /* DMA config: ring buffer → DAC FIFO */
    uint32_t dac_fifo_addr;
    bk_aud_dac_get_fifo_addr(&dac_fifo_addr);

    dma_config_t dma_cfg;
    os_memset(&dma_cfg, 0, sizeof(dma_cfg));
    dma_cfg.mode = DMA_WORK_MODE_REPEAT;
    dma_cfg.chan_prio = 1;
    dma_cfg.trans_type = DMA_TRANS_DEFAULT;
    dma_cfg.src.dev = DMA_DEV_DTCM;
    dma_cfg.dst.dev = DMA_DEV_AUDIO;
    dma_cfg.src.width = DMA_DATA_WIDTH_32BITS;
    dma_cfg.dst.width = (channels == 1) ? DMA_DATA_WIDTH_16BITS : DMA_DATA_WIDTH_32BITS;
    dma_cfg.src.addr_inc_en = DMA_ADDR_INC_ENABLE;
    dma_cfg.src.addr_loop_en = DMA_ADDR_LOOP_ENABLE;
    dma_cfg.src.start_addr = (uint32_t)(uintptr_t)s_rb_buf;
    dma_cfg.src.end_addr = (uint32_t)(uintptr_t)s_rb_buf + rb_size;
    dma_cfg.dst.addr_inc_en = DMA_ADDR_INC_ENABLE;
    dma_cfg.dst.addr_loop_en = DMA_ADDR_LOOP_ENABLE;
    dma_cfg.dst.start_addr = dac_fifo_addr;
    dma_cfg.dst.end_addr = dac_fifo_addr + 4;

    ret = bk_dma_init(s_dma_id, &dma_cfg);
    if (ret != BK_OK) {
        BK_LOGE(TAG, "dma init fail: %d\r\n", ret);
        os_free(s_rb_buf); s_rb_buf = NULL;
        bk_dma_free(DMA_DEV_AUDIO, s_dma_id);
        bk_aud_dac_deinit();
        return -1;
    }

    bk_dma_set_transfer_len(s_dma_id, s_frame_bytes);
    bk_dma_register_isr(s_dma_id, NULL, (void *)spk_dma_isr);
    bk_dma_enable_finish_interrupt(s_dma_id);

#if (CONFIG_SPE)
    bk_dma_set_dest_sec_attr(s_dma_id, DMA_ATTR_SEC);
    bk_dma_set_src_sec_attr(s_dma_id, DMA_ATTR_SEC);
#endif

    rtos_init_semaphore(&s_sem, 1);

    /* Pre-fill 1 frame of silence to start DMA */
    {
        uint8_t *z = (uint8_t *)os_malloc(s_frame_bytes);
        if (z) {
            os_memset(z, 0, s_frame_bytes);
            ring_buffer_write(&s_rb, z, s_frame_bytes);
            os_free(z);
        }
    }

    /* Enable PA */
    rtos_delay_milliseconds(50);
    pa_enable();

    /* Start DMA + DAC */
    bk_dma_start(s_dma_id);
    bk_aud_dac_start();

    s_initialized = 1;
    BK_LOGI(TAG, "speaker ready (DMA, frame=%u bytes)\r\n", (unsigned)s_frame_bytes);
    return 0;
}

void bk_zig_speaker_deinit(void)
{
    if (!s_initialized) return;
    s_initialized = 0;

    bk_gpio_set_output_low(PA_CTRL_GPIO);
    bk_aud_dac_stop();
    bk_dma_stop(s_dma_id);
    bk_dma_deinit(s_dma_id);
    bk_dma_free(DMA_DEV_AUDIO, s_dma_id);
    ring_buffer_clear(&s_rb);
    if (s_rb_buf) { os_free(s_rb_buf); s_rb_buf = NULL; }

    bk_aud_dac_deinit();
    BK_LOGI(TAG, "speaker deinitialized\r\n");
}

/**
 * Write PCM samples to speaker ring buffer.
 * DMA automatically transfers to DAC.
 * Returns number of samples written.
 */
int bk_zig_speaker_write(const short *data, unsigned int samples)
{
    if (!s_initialized) return -1;

    uint32_t bytes = samples * sizeof(short);
    uint32_t written = ring_buffer_write(&s_rb, (uint8_t *)data, bytes);
    return (int)(written / sizeof(short));
}

int bk_zig_speaker_set_volume(unsigned char gain)
{
    if (!s_initialized) return -1;
    return (int)bk_aud_dac_set_gain(gain);
}
