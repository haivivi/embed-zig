/**
 * bk_zig_mic_helper.c — Direct audio ADC+DMA microphone driver for Zig.
 *
 * No pipeline. Just:
 *   Microphone → Audio ADC → FIFO → DMA → ring buffer → Zig read
 *
 * Reference: onboard_mic_stream.c aud_adc_dma_config()
 */

#include <string.h>
#include <os/os.h>
#include <os/mem.h>
#include <components/log.h>
#include <driver/aud_adc.h>
#include <driver/aud_adc_types.h>
#include <driver/dma.h>
#include <driver/audio_ring_buff.h>

#define TAG "zig_mic"

#define DMA_RB_SAFE_INTERVAL  8

/* State */
static dma_id_t s_dma_id = DMA_ID_MAX;
static RingBufferContext s_rb;
static int8_t *s_ring_buff = NULL;
static uint32_t s_frame_size = 0;   /* bytes per frame (20ms, one channel) */
static uint32_t s_dma_frame_size = 0; /* DMA transfer size (may be 2x for mono) */
static uint8_t s_channels = 1;
static beken_semaphore_t s_read_sem = NULL;
static volatile int s_initialized = 0;

/* DMA finish ISR — one frame of mic data ready */
static void adc_dma_finish_isr(void)
{
    if (s_read_sem) {
        rtos_set_semaphore(&s_read_sem);
    }
}

int bk_zig_mic_init(unsigned int sample_rate, unsigned char channels, unsigned char gain)
{
    bk_err_t ret;

    BK_LOGI(TAG, "init: rate=%u ch=%u gain=0x%x\r\n", sample_rate, channels, gain);

    if (s_initialized) {
        BK_LOGW(TAG, "already initialized\r\n");
        return 0;
    }

    s_channels = channels;
    /* Frame size = 20ms of one-channel 16-bit audio */
    s_frame_size = sample_rate * 1 * 2 * 20 / 1000; /* always per-channel */

    /*
     * DMA must carry ADCL and ADCR together (hardware constraint).
     * For mono: DMA transfers 2x frame_size, we extract L channel only.
     * For stereo: DMA transfers frame_size per channel = frame_size total.
     */
    s_dma_frame_size = (channels == 1) ? s_frame_size * 2 : s_frame_size;

    BK_LOGI(TAG, "frame=%u dma_frame=%u bytes\r\n", s_frame_size, s_dma_frame_size);

    /* 1. Init audio ADC */
    aud_adc_config_t adc_cfg = DEFAULT_AUD_ADC_CONFIG();
    adc_cfg.adc_chl = (channels == 2) ? AUD_ADC_CHL_LR : AUD_ADC_CHL_L;
    adc_cfg.samp_rate = sample_rate;
    adc_cfg.adc_gain = gain;

    ret = bk_aud_adc_init(&adc_cfg);
    if (ret != BK_OK) {
        BK_LOGE(TAG, "adc_init: %d\r\n", ret);
        return (int)ret;
    }

    /* 2. Alloc DMA channel */
    s_dma_id = bk_dma_alloc(DMA_DEV_AUDIO);
    if (s_dma_id < DMA_ID_0 || s_dma_id >= DMA_ID_MAX) {
        BK_LOGE(TAG, "dma_alloc fail\r\n");
        bk_aud_adc_deinit();
        return -1;
    }

    /* 3. Alloc ring buffer (2 DMA frames + safety) */
    uint32_t rb_size = s_dma_frame_size * 2 + DMA_RB_SAFE_INTERVAL;
    s_ring_buff = (int8_t *)os_malloc(rb_size);
    if (!s_ring_buff) {
        BK_LOGE(TAG, "rb malloc fail (%u)\r\n", rb_size);
        bk_dma_free(DMA_DEV_AUDIO, s_dma_id);
        bk_aud_adc_deinit();
        return -2;
    }
    memset(s_ring_buff, 0, rb_size);

    /* 4. Configure DMA: ADC FIFO → ring buffer */
    uint32_t adc_fifo_addr = 0;
    ret = bk_aud_adc_get_fifo_addr(&adc_fifo_addr);
    if (ret != BK_OK) {
        BK_LOGE(TAG, "get_fifo_addr: %d\r\n", ret);
        goto fail;
    }

    dma_config_t dma_cfg;
    memset(&dma_cfg, 0, sizeof(dma_cfg));
    dma_cfg.mode = DMA_WORK_MODE_REPEAT;
    dma_cfg.chan_prio = 1;
    dma_cfg.trans_type = DMA_TRANS_DEFAULT;

    /* Source: audio ADC FIFO */
    dma_cfg.src.dev = DMA_DEV_AUDIO_RX;
    dma_cfg.src.width = DMA_DATA_WIDTH_32BITS;
    dma_cfg.src.addr_inc_en = DMA_ADDR_INC_ENABLE;
    dma_cfg.src.addr_loop_en = DMA_ADDR_LOOP_ENABLE;
    dma_cfg.src.start_addr = adc_fifo_addr;
    dma_cfg.src.end_addr = adc_fifo_addr + 4;

    /* Destination: DTCM ring buffer */
    dma_cfg.dst.dev = DMA_DEV_DTCM;
    dma_cfg.dst.width = DMA_DATA_WIDTH_32BITS;
    dma_cfg.dst.addr_inc_en = DMA_ADDR_INC_ENABLE;
    dma_cfg.dst.addr_loop_en = DMA_ADDR_LOOP_ENABLE;
    dma_cfg.dst.start_addr = (uint32_t)(uintptr_t)s_ring_buff;
    dma_cfg.dst.end_addr = (uint32_t)(uintptr_t)s_ring_buff + rb_size;

    ret = bk_dma_init(s_dma_id, &dma_cfg);
    if (ret != BK_OK) {
        BK_LOGE(TAG, "dma_init: %d\r\n", ret);
        goto fail;
    }

    bk_dma_set_transfer_len(s_dma_id, s_dma_frame_size);

    /* 5. DMA finish ISR */
    ret = rtos_init_semaphore(&s_read_sem, 2);
    if (ret != BK_OK) {
        BK_LOGE(TAG, "sem_init: %d\r\n", ret);
        goto fail;
    }

    bk_dma_register_isr(s_dma_id, NULL, (void *)adc_dma_finish_isr);
    bk_dma_enable_finish_interrupt(s_dma_id);

    ring_buffer_init(&s_rb, (uint8_t *)s_ring_buff, rb_size, s_dma_id, RB_DMA_TYPE_WRITE);

    /* 6. Start */
    ret = bk_aud_adc_start();
    if (ret != BK_OK) {
        BK_LOGE(TAG, "adc_start: %d\r\n", ret);
        goto fail;
    }

    ret = bk_dma_start(s_dma_id);
    if (ret != BK_OK) {
        BK_LOGE(TAG, "dma_start: %d\r\n", ret);
        bk_aud_adc_stop();
        goto fail;
    }

    s_initialized = 1;
    BK_LOGI(TAG, "mic ready (dma=%d)\r\n", s_dma_id);
    return 0;

fail:
    if (s_read_sem) { rtos_deinit_semaphore(&s_read_sem); s_read_sem = NULL; }
    if (s_ring_buff) { os_free(s_ring_buff); s_ring_buff = NULL; }
    bk_dma_deinit(s_dma_id);
    bk_dma_free(DMA_DEV_AUDIO, s_dma_id);
    bk_aud_adc_deinit();
    return -3;
}

void bk_zig_mic_deinit(void)
{
    if (!s_initialized) return;
    s_initialized = 0;

    bk_dma_stop(s_dma_id);
    bk_aud_adc_stop();
    bk_dma_deinit(s_dma_id);
    bk_dma_free(DMA_DEV_AUDIO, s_dma_id);
    bk_aud_adc_deinit();

    if (s_read_sem) { rtos_deinit_semaphore(&s_read_sem); s_read_sem = NULL; }
    if (s_ring_buff) { os_free(s_ring_buff); s_ring_buff = NULL; }

    BK_LOGI(TAG, "mic deinitialized\r\n");
}

/**
 * Read PCM samples from microphone.
 * For mono: DMA captures L+R interleaved, we extract L channel only.
 * Blocks until data is available.
 * Returns number of samples read, or negative on error.
 */
int bk_zig_mic_read(short *buffer, unsigned int max_samples)
{
    if (!s_initialized || !s_ring_buff) return -1;

    uint32_t need_bytes;
    if (s_channels == 1) {
        /* For mono: DMA has L+R interleaved (32-bit per sample pair).
         * We need to read 4 bytes per sample (L16 + R16) and extract L. */
        need_bytes = max_samples * 4; /* 2 channels * 2 bytes each */
    } else {
        need_bytes = max_samples * 2;
    }

    /* Wait for data */
    uint32_t avail = ring_buffer_get_fill_size(&s_rb);
    while (avail < need_bytes) {
        rtos_get_semaphore(&s_read_sem, 50);
        avail = ring_buffer_get_fill_size(&s_rb);
        if (!s_initialized) return -1;
    }

    if (s_channels == 1) {
        /* Read interleaved L+R, extract L channel */
        uint32_t pairs = max_samples;
        if (pairs > 160) pairs = 160; /* limit stack usage */
        uint32_t raw_bytes = pairs * 4;
        int32_t raw_buf[160]; /* L16+R16 packed as int32 */
        uint32_t read = ring_buffer_read(&s_rb, (uint8_t *)raw_buf, raw_bytes);
        uint32_t samples_read = read / 4;
        for (uint32_t i = 0; i < samples_read; i++) {
            buffer[i] = (short)(raw_buf[i] & 0xFFFF); /* extract lower 16 bits = L channel */
        }
        return (int)samples_read;
    } else {
        /* Stereo: direct read */
        uint32_t read = ring_buffer_read(&s_rb, (uint8_t *)buffer, need_bytes);
        return (int)(read / 2);
    }
}
