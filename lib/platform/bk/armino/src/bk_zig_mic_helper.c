/**
 * bk_zig_mic_helper.c — DMA-based microphone driver for BK7258.
 *
 * Uses ADC DMA to transfer audio data to ring buffer, then reads
 * from ring buffer on demand. Provides precise hardware-timed sampling.
 *
 * Flow: Microphone → Audio ADC → DMA → Ring Buffer → bk_zig_mic_read()
 */

#include <string.h>
#include <os/os.h>
#include <os/mem.h>
#include <components/log.h>
#include <driver/aud_adc.h>
#include <driver/aud_adc_types.h>
#include <driver/aud_common.h>
#include <driver/dma.h>
#include <driver/audio_ring_buff.h>

#define TAG "zig_mic"
#define FRAME_MS        20
#define RB_SAFE_MARGIN  8

static volatile int s_initialized = 0;
static dma_id_t s_dma_id;
static int8_t *s_rb_buf = NULL;
static RingBufferContext s_rb;
static beken_semaphore_t s_sem;
static uint32_t s_dma_frame_bytes = 0;  /* LR interleaved frame size */
static uint32_t s_mono_frame_samples = 0;

static void mic_dma_isr(void)
{
    rtos_set_semaphore(&s_sem);
}

int bk_zig_mic_init(unsigned int sample_rate, unsigned char channels,
                    unsigned char dig_gain, unsigned char ana_gain)
{
    bk_err_t ret;

    BK_LOGI(TAG, "init: rate=%u ch=%u dig=0x%x ana=0x%x\r\n",
            sample_rate, channels, dig_gain, ana_gain);

    if (s_initialized) return 0;

    /* Calculate frame sizes */
    s_mono_frame_samples = sample_rate * FRAME_MS / 1000;
    uint32_t mono_frame_bytes = s_mono_frame_samples * 2;
    /* DMA always carries LR interleaved, so 2x mono size */
    s_dma_frame_bytes = mono_frame_bytes * 2;

    /* ADC init — always LR mode (DMA requirement) */
    aud_adc_config_t adc_cfg = DEFAULT_AUD_ADC_CONFIG();
    adc_cfg.adc_chl = AUD_ADC_CHL_LR;
    adc_cfg.samp_rate = sample_rate;
    adc_cfg.adc_gain = dig_gain;
    adc_cfg.clk_src = AUD_CLK_XTAL;

    ret = bk_aud_adc_init(&adc_cfg);
    if (ret != BK_OK) { BK_LOGE(TAG, "adc_init fail: %d\r\n", ret); return (int)ret; }

    bk_aud_adc_set_mic_mode(AUD_MIC_MIC1, AUD_ADC_MODE_DIFFEN);
    bk_aud_set_ana_mic0_gain(ana_gain);

    /* DMA setup */
    s_dma_id = bk_dma_alloc(DMA_DEV_AUDIO);
    if (s_dma_id < DMA_ID_0 || s_dma_id >= DMA_ID_MAX) {
        BK_LOGE(TAG, "dma alloc fail\r\n");
        bk_aud_adc_deinit();
        return -1;
    }

    /* Ring buffer: 2 frames + safety margin */
    uint32_t rb_size = s_dma_frame_bytes * 2 + RB_SAFE_MARGIN;
    s_rb_buf = (int8_t *)os_malloc(rb_size);
    if (!s_rb_buf) {
        BK_LOGE(TAG, "rb malloc fail\r\n");
        bk_dma_free(DMA_DEV_AUDIO, s_dma_id);
        bk_aud_adc_deinit();
        return -1;
    }

    /* DMA config: ADC FIFO → ring buffer */
    uint32_t adc_fifo_addr;
    bk_aud_adc_get_fifo_addr(&adc_fifo_addr);

    dma_config_t dma_cfg;
    os_memset(&dma_cfg, 0, sizeof(dma_cfg));
    dma_cfg.mode = DMA_WORK_MODE_REPEAT;
    dma_cfg.chan_prio = 1;
    dma_cfg.trans_type = DMA_TRANS_DEFAULT;
    dma_cfg.src.dev = DMA_DEV_AUDIO_RX;
    dma_cfg.dst.dev = DMA_DEV_DTCM;
    dma_cfg.src.width = DMA_DATA_WIDTH_32BITS;
    dma_cfg.dst.width = DMA_DATA_WIDTH_32BITS;
    dma_cfg.src.addr_inc_en = DMA_ADDR_INC_ENABLE;
    dma_cfg.src.addr_loop_en = DMA_ADDR_LOOP_ENABLE;
    dma_cfg.src.start_addr = adc_fifo_addr;
    dma_cfg.src.end_addr = adc_fifo_addr + 4;
    dma_cfg.dst.addr_inc_en = DMA_ADDR_INC_ENABLE;
    dma_cfg.dst.addr_loop_en = DMA_ADDR_LOOP_ENABLE;
    dma_cfg.dst.start_addr = (uint32_t)(uintptr_t)s_rb_buf;
    dma_cfg.dst.end_addr = (uint32_t)(uintptr_t)s_rb_buf + rb_size;

    ret = bk_dma_init(s_dma_id, &dma_cfg);
    if (ret != BK_OK) {
        BK_LOGE(TAG, "dma init fail: %d\r\n", ret);
        os_free(s_rb_buf); s_rb_buf = NULL;
        bk_dma_free(DMA_DEV_AUDIO, s_dma_id);
        bk_aud_adc_deinit();
        return -1;
    }

    bk_dma_set_transfer_len(s_dma_id, s_dma_frame_bytes);
    bk_dma_register_isr(s_dma_id, NULL, (void *)mic_dma_isr);
    bk_dma_enable_finish_interrupt(s_dma_id);

#if (CONFIG_SPE)
    bk_dma_set_dest_sec_attr(s_dma_id, DMA_ATTR_SEC);
    bk_dma_set_src_sec_attr(s_dma_id, DMA_ATTR_SEC);
#endif

    ring_buffer_init(&s_rb, (uint8_t *)s_rb_buf, rb_size, s_dma_id, RB_DMA_TYPE_WRITE);
    rtos_init_semaphore(&s_sem, 1);

    /* Start DMA + ADC */
    bk_dma_start(s_dma_id);
    bk_aud_adc_start();

    s_initialized = 1;
    BK_LOGI(TAG, "mic ready (DMA, frame=%u bytes, mono=%u samples)\r\n",
            (unsigned)s_dma_frame_bytes, (unsigned)s_mono_frame_samples);
    return 0;
}

void bk_zig_mic_deinit(void)
{
    if (!s_initialized) return;
    s_initialized = 0;

    bk_aud_adc_stop();
    bk_dma_stop(s_dma_id);
    bk_dma_deinit(s_dma_id);
    bk_dma_free(DMA_DEV_AUDIO, s_dma_id);
    ring_buffer_clear(&s_rb);
    if (s_rb_buf) { os_free(s_rb_buf); s_rb_buf = NULL; }

    bk_aud_adc_deinit();
    BK_LOGI(TAG, "mic deinitialized\r\n");
}

/**
 * Read PCM samples from mic (L channel only).
 * Blocks until one DMA frame is available.
 * Returns number of mono samples read.
 */
int bk_zig_mic_read(short *buffer, unsigned int max_samples)
{
    if (!s_initialized) return -1;

    /* Wait for DMA to deliver a frame */
    if (kNoErr != rtos_get_semaphore(&s_sem, 20000)) {
        BK_LOGE(TAG, "sem timeout\r\n");
        return -1;
    }

    uint32_t fill = ring_buffer_get_fill_size(&s_rb);
    if (fill < s_dma_frame_bytes) {
        /* Not enough data yet, return silence */
        uint32_t n = (max_samples < s_mono_frame_samples) ? max_samples : s_mono_frame_samples;
        os_memset(buffer, 0, n * sizeof(short));
        return (int)n;
    }

    /* Read LR interleaved data from ring buffer */
    int16_t *lr_buf = (int16_t *)os_malloc(s_dma_frame_bytes);
    if (!lr_buf) return -1;

    ring_buffer_read(&s_rb, (uint8_t *)lr_buf, s_dma_frame_bytes);

    /* Extract L channel (every other sample) */
    uint32_t out_samples = s_dma_frame_bytes / 4;  /* each LR pair = 4 bytes */
    if (out_samples > max_samples) out_samples = max_samples;

    for (uint32_t i = 0; i < out_samples; i++) {
        buffer[i] = lr_buf[2 * i];  /* L channel */
    }

    os_free(lr_buf);
    return (int)out_samples;
}
