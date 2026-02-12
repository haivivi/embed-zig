/**
 * bk_zig_aec_helper.c — AEC wrapper for Zig.
 *
 * Wraps Armino's libaec.a calls in C to avoid Zig extern ABI issues
 * with prebuilt ARM libraries. Pattern matches aec_demo.c.
 */

#include <os/os.h>
#include <os/mem.h>
#include <components/log.h>
#include <modules/aec.h>
#include <string.h>

#define TAG "zig_aec"

static AECContext *s_aec = NULL;
static uint32_t s_frame_samples = 0;
static int16_t *s_ref_buf = NULL;  /* internal reusable buffers from AEC */
static int16_t *s_mic_buf = NULL;
static int16_t *s_out_buf = NULL;

int bk_zig_aec_init(unsigned int delay, unsigned short sample_rate)
{
    if (s_aec) return 0; /* already initialized */

    uint32_t ctx_size = aec_size(delay);
    BK_LOGI(TAG, "aec_size(%u) = %u bytes\r\n", delay, ctx_size);

    /* Try SRAM first (os_malloc), check if address is in SRAM range */
    void *ptr = os_malloc(ctx_size);
    if (!ptr) {
        BK_LOGE(TAG, "os_malloc(%u) failed!\r\n", ctx_size);
        return -1;
    }
    BK_LOGI(TAG, "AEC context at %p (size=%u)\r\n", ptr, ctx_size);

    /* Check if it's PSRAM (0x28xxxxxx) — AEC may need SRAM */
    if (((uint32_t)ptr & 0xFF000000) == 0x28000000) {
        BK_LOGW(TAG, "WARNING: os_malloc returned PSRAM! Trying os_zalloc...\r\n");
    }

    /* Zero the context to avoid garbage function pointers */
    memset(ptr, 0, ctx_size);

    s_aec = (AECContext *)ptr;
    BK_LOGI(TAG, "Calling aec_init(fs=%u)...\r\n", sample_rate);
    aec_init(s_aec, (int16_t)sample_rate);
    BK_LOGI(TAG, "aec_init done (fs=%u)\r\n", sample_rate);

    /* Get frame size */
    aec_ctrl(s_aec, AEC_CTRL_CMD_GET_FRAME_SAMPLE, (uint32_t)(&s_frame_samples));
    BK_LOGI(TAG, "frame_samples = %u\r\n", s_frame_samples);

    /* Get internal reusable buffers */
    uint32_t val = 0;
    aec_ctrl(s_aec, AEC_CTRL_CMD_GET_RX_BUF, (uint32_t)(&val));
    s_ref_buf = (int16_t *)val;
    aec_ctrl(s_aec, AEC_CTRL_CMD_GET_TX_BUF, (uint32_t)(&val));
    s_mic_buf = (int16_t *)val;
    aec_ctrl(s_aec, AEC_CTRL_CMD_GET_OUT_BUF, (uint32_t)(&val));
    s_out_buf = (int16_t *)val;

    BK_LOGI(TAG, "bufs: ref=%p mic=%p out=%p\r\n", s_ref_buf, s_mic_buf, s_out_buf);

    /* Apply default tuning (from aec_demo.c) */
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_FLAGS, 0x1f);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_MIC_DELAY, 10);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_EC_DEPTH, 5);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_TxRxThr, 13);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_TxRxFlr, 1);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_REF_SCALE, 0);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_VOL, 14);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_NS_LEVEL, 2);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_NS_PARA, 1);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_DRC, 0x15);

    BK_LOGI(TAG, "AEC ready\r\n");
    return 0;
}

void bk_zig_aec_deinit(void)
{
    if (s_aec) {
        os_free(s_aec);
        s_aec = NULL;
        s_ref_buf = NULL;
        s_mic_buf = NULL;
        s_out_buf = NULL;
        s_frame_samples = 0;
        BK_LOGI(TAG, "AEC deinitialized\r\n");
    }
}

unsigned int bk_zig_aec_get_frame_samples(void)
{
    return s_frame_samples;
}

/**
 * Process one AEC frame.
 * ref: speaker reference (frame_samples i16 samples)
 * mic: raw microphone (frame_samples i16 samples)
 * out: echo-cancelled output (frame_samples i16 samples)
 */
void bk_zig_aec_process(const short *ref, const short *mic, short *out)
{
    if (!s_aec || !s_ref_buf || !s_mic_buf || !s_out_buf) return;

    uint32_t n = s_frame_samples;
    memcpy(s_ref_buf, ref, n * sizeof(int16_t));
    memcpy(s_mic_buf, mic, n * sizeof(int16_t));

    aec_proc(s_aec, s_ref_buf, s_mic_buf, s_out_buf);

    memcpy(out, s_out_buf, n * sizeof(int16_t));
}
