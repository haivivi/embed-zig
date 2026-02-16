/**
 * bk_zig_aec_helper.c — AEC wrapper for Zig.
 *
 * Wraps Armino's libaec.a calls in C to avoid Zig extern ABI issues
 * with prebuilt ARM libraries. Pattern matches aec_demo.c.
 */

#include <os/os.h>
#include <os/mem.h>
#include <os/str.h>
#include <components/log.h>
#include <modules/aec_v3.h>  /* MUST use v3, not v1! v1 + v3 data = crash */
#include <string.h>

#define TAG "zig_aec"

/* ===== Audio OSI functions init (required by libaec_v3.a) ===== */
/* libaec_v3.a calls bk_get_audio_osi_funcs() internally to get OS
 * function pointers (malloc, free, memcpy, etc.). These MUST be
 * registered before aec_init() or the lib crashes on garbage ptrs. */

typedef struct {
    void *(*psram_malloc)(size_t);
    void *(*psram_realloc)(void *, size_t);
    void *(*malloc)(size_t);
    void *(*zalloc)(size_t, size_t);
    void *(*realloc)(void *, size_t);
    void  (*free)(void *);
    void *(*memcpy)(void *, const void *, uint32_t);
    void  (*memcpy_word)(void *, const void *, uint32_t);
    void *(*memset)(void *, int, uint32_t);
    void *(*memmove)(void *, const void *, uint32_t);
    void  (*memset_word)(void *, int32_t, uint32_t);
    void  (*log_write)(int, char *, const char *, ...);
    void  (*osi_assert)(uint8_t, char *, const char *);
    uint32_t (*get_time)(void);
} bk_audio_osi_funcs_t;

extern int audio_osi_funcs_init(void *config);
extern void *bk_psram_realloc(void *old_mem, size_t new_size);

static void _log_write(int level, char *tag, const char *fmt, ...) {
    (void)level; (void)tag; (void)fmt;
    /* no-op: AEC lib logging not needed */
}

static void *_psram_malloc(size_t sz) { return psram_malloc(sz); }
static void *_psram_realloc(void *p, size_t sz) { return bk_psram_realloc(p, sz); }
static void *_malloc(size_t sz) { return os_malloc(sz); }
static void *_zalloc(size_t n, size_t sz) { return os_zalloc(n * sz); }
static void *_realloc(void *p, size_t sz) { return os_realloc(p, sz); }
static void  _free(void *p) { os_free(p); }
static void *_memcpy(void *d, const void *s, uint32_t n) { return os_memcpy(d, s, n); }
static void  _memcpy_word(void *d, const void *s, uint32_t n) { os_memcpy_word(d, s, n); }
static void *_memset(void *b, int c, uint32_t n) { return os_memset(b, c, n); }
static void *_memmove(void *d, const void *s, uint32_t n) { return os_memmove(d, s, n); }
static void  _memset_word(void *b, int32_t c, uint32_t n) { os_memset_word(b, c, n); }
static void  _assert(uint8_t e, char *s, const char *f) { if (!e) { BK_LOGE(TAG, "ASSERT(%s) at %s\r\n", s, f); while(1); } }
static uint32_t _get_time(void) { return rtos_get_time(); }

static bk_audio_osi_funcs_t s_osi_funcs = {
    .psram_malloc  = _psram_malloc,
    .psram_realloc = _psram_realloc,
    .malloc        = _malloc,
    .zalloc        = _zalloc,
    .realloc       = _realloc,
    .free          = _free,
    .memcpy        = _memcpy,
    .memcpy_word   = _memcpy_word,
    .memset        = _memset,
    .memmove       = _memmove,
    .memset_word   = _memset_word,
	.log_write     = _log_write,
    .osi_assert    = _assert,
    .get_time      = _get_time,
};

static int s_osi_inited = 0;

/* ===== AEC state ===== */
static AECContext *s_aec = NULL;
static uint32_t s_frame_samples = 0;
static int16_t *s_ref_buf = NULL;  /* internal reusable buffers from AEC */
static int16_t *s_mic_buf = NULL;
static int16_t *s_out_buf = NULL;

int bk_zig_aec_init(unsigned int delay, unsigned short sample_rate)
{
    if (s_aec) return 0; /* already initialized */

    /* Step 1: Register OS function pointers (MUST be before any aec call) */
    if (!s_osi_inited) {
        audio_osi_funcs_init(&s_osi_funcs);
        s_osi_inited = 1;
        BK_LOGI(TAG, "osi init done\r\n");
    }

    /* Step 2: Get context size */
    uint32_t ctx_size = aec_size(delay);
    BK_LOGI(TAG, "aec_size(%u)=%u\r\n", delay, ctx_size);

    /* Use psram_malloc + memset like official audio_malloc */
    void *ptr = psram_malloc(ctx_size);
    if (!ptr) { BK_LOGE(TAG, "malloc fail\r\n"); return -1; }
    BK_LOGI(TAG, "p=%p\r\n", ptr);
    os_memset(ptr, 0, ctx_size);
    BK_LOGI(TAG, "z ok\r\n");

    s_aec = (AECContext *)ptr;
    s_aec->fs = 0;
    BK_LOGI(TAG, "init...\r\n");
    aec_init(s_aec, (int16_t)sample_rate);
    BK_LOGI(TAG, "init ok!\r\n");

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

    /* Apply default tuning — v3 AEC_CTRL_CMD enum */
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_FLAGS, 0x1f);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_MIC_DELAY, 10);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_EC_DEPTH, 5);
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
