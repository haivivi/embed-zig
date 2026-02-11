/**
 * bk_zig_speaker_helper.c — Audio pipeline speaker for Zig interop.
 *
 * Wraps Armino's audio_pipeline + onboard_speaker_stream + raw_stream
 * into simple C functions callable from Zig.
 */

#include <os/os.h>
#include <components/log.h>
#include <driver/gpio.h>
#include <components/bk_audio/audio_pipeline/audio_pipeline.h>
#include <components/bk_audio/audio_streams/raw_stream.h>
#include <components/bk_audio/audio_streams/onboard_speaker_stream.h>

/* PA enable: GPIO 0 controls nSD on speaker board (HIGH = on) */
#define PA_CTRL_GPIO  0

extern void gpio_dev_unmap(unsigned int id);

static void pa_enable(void) {
    gpio_dev_unmap(PA_CTRL_GPIO);
    bk_gpio_enable_output(PA_CTRL_GPIO);
    bk_gpio_set_output_high(PA_CTRL_GPIO);
    BK_LOGI("zig_spk", "PA enabled (GPIO %d HIGH)\r\n", PA_CTRL_GPIO);
}

#define TAG "zig_spk"

static audio_element_handle_t s_onboard_spk = NULL;
static audio_element_handle_t s_raw_write = NULL;
static audio_pipeline_handle_t s_pipeline = NULL;

int bk_zig_speaker_init(unsigned int sample_rate, unsigned char channels,
                        unsigned char bits, unsigned char dig_gain)
{
    BK_LOGI(TAG, "init: rate=%u ch=%u bits=%u gain=0x%x\r\n",
            sample_rate, channels, bits, dig_gain);

    /* Step 1: Create pipeline */
    audio_pipeline_cfg_t pipe_cfg = DEFAULT_AUDIO_PIPELINE_CONFIG();
    pipe_cfg.rb_size = 8 * 1024;
    s_pipeline = audio_pipeline_init(&pipe_cfg);
    if (!s_pipeline) {
        BK_LOGE(TAG, "pipeline init failed\r\n");
        return -1;
    }

    /* Step 2: Create raw write stream (Zig pushes PCM data here) */
    raw_stream_cfg_t raw_cfg = RAW_STREAM_CFG_DEFAULT();
    raw_cfg.type = AUDIO_STREAM_WRITER;
    s_raw_write = raw_stream_init(&raw_cfg);
    if (!s_raw_write) {
        BK_LOGE(TAG, "raw_stream init failed\r\n");
        return -2;
    }

    /* Step 3: Create onboard speaker stream (DAC output) */
    onboard_speaker_stream_cfg_t spk_cfg = ONBOARD_SPEAKER_STREAM_CFG_DEFAULT();
    spk_cfg.sample_rate = sample_rate;
    spk_cfg.chl_num = channels;
    spk_cfg.bits = bits;
    spk_cfg.dig_gain = 0x3F;       /* MAX digital gain (+18dB) */
    spk_cfg.ana_gain = 0x00;       /* MAX analog gain (0dB, least attenuation) */
    spk_cfg.frame_size = sample_rate * channels * (bits / 8) * 20 / 1000; /* 20ms */
    spk_cfg.task_stack = 2048;
    spk_cfg.pa_ctrl_en = true;     /* Enable PA control */
    spk_cfg.pa_ctrl_gpio = PA_CTRL_GPIO;
    spk_cfg.pa_on_level = 1;       /* HIGH = PA on */
    spk_cfg.pa_on_delay = 100;     /* 100ms delay after DAC init */
    BK_LOGI(TAG, "spk config: dig=0x%x ana=0x%x pa_gpio=%d\r\n", 
            spk_cfg.dig_gain, spk_cfg.ana_gain, spk_cfg.pa_ctrl_gpio);
    s_onboard_spk = onboard_speaker_stream_init(&spk_cfg);
    if (!s_onboard_spk) {
        BK_LOGE(TAG, "speaker stream init failed\r\n");
        return -3;
    }

    /* Step 4: Register and link */
    audio_pipeline_register(s_pipeline, s_raw_write, "raw");
    audio_pipeline_register(s_pipeline, s_onboard_spk, "spk");

    const char *link_tag[] = {"raw", "spk"};
    audio_pipeline_link(s_pipeline, link_tag, 2);

    /* Step 5: Start pipeline */
    audio_pipeline_run(s_pipeline);

    /* Step 6: Enable PA (let onboard_speaker_stream handle it via pa_ctrl_en) */

    BK_LOGI(TAG, "speaker pipeline running\r\n");

    /* Step 7: Quick C beep (500Hz square wave, 200ms) */
    {
        BK_LOGI(TAG, "C beep...\r\n");
        short buf[160];
        int half = sample_rate / 500 / 2; /* half period of 500Hz */
        if (half < 1) half = 1;
        int frames = sample_rate * 200 / 1000 / 160;
        for (int f = 0; f < frames; f++) {
            for (int i = 0; i < 160; i++) {
                buf[i] = ((i / half) % 2) ? 12000 : -12000;
            }
            raw_stream_write(s_raw_write, (char *)buf, sizeof(buf));
        }
        memset(buf, 0, sizeof(buf));
        for (int f = 0; f < 5; f++)
            raw_stream_write(s_raw_write, (char *)buf, sizeof(buf));
        BK_LOGI(TAG, "C beep done\r\n");
    }

    return 0;
}

void bk_zig_speaker_deinit(void)
{
    if (s_pipeline) {
        audio_pipeline_stop(s_pipeline);
        audio_pipeline_wait_for_stop(s_pipeline);
        audio_pipeline_terminate(s_pipeline);

        if (s_raw_write) {
            audio_pipeline_unregister(s_pipeline, s_raw_write);
            audio_element_deinit(s_raw_write);
            s_raw_write = NULL;
        }
        if (s_onboard_spk) {
            audio_pipeline_unregister(s_pipeline, s_onboard_spk);
            audio_element_deinit(s_onboard_spk);
            s_onboard_spk = NULL;
        }

        audio_pipeline_deinit(s_pipeline);
        s_pipeline = NULL;
    }
    BK_LOGI(TAG, "speaker deinitialized\r\n");
}

/**
 * Write PCM samples to the speaker pipeline.
 * Returns number of samples written, or negative on error.
 */
static int s_write_count = 0;
static int s_total_bytes = 0;

int bk_zig_speaker_write(const short *data, unsigned int samples)
{
    if (!s_raw_write) {
        BK_LOGE(TAG, "write: raw_write is NULL!\r\n");
        return -1;
    }
    int bytes = raw_stream_write(s_raw_write, (char *)data, samples * sizeof(short));
    if (bytes < 0) {
        BK_LOGE(TAG, "write failed: %d\r\n", bytes);
        return bytes;
    }
    s_write_count++;
    s_total_bytes += bytes;
    if (s_write_count <= 3) {
        BK_LOGI(TAG, "write #%d: %d samples, data[0..4]=%d %d %d %d\r\n",
                s_write_count, samples, data[0], data[1], data[2], data[3]);
    }
    return bytes / (int)sizeof(short);
}

/**
 * Set digital gain (volume).
 */
int bk_zig_speaker_set_volume(unsigned char gain)
{
    if (!s_onboard_spk) return -1;
    return onboard_speaker_stream_set_digital_gain(s_onboard_spk, gain);
}
