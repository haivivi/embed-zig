/**
 * bk_zig_speaker_helper.c — Audio pipeline speaker for Zig interop.
 *
 * Wraps Armino's audio_pipeline + onboard_speaker_stream + raw_stream
 * into simple C functions callable from Zig.
 */

#include <os/os.h>
#include <components/log.h>
#include <components/bk_audio/audio_pipeline/audio_pipeline.h>
#include <components/bk_audio/audio_streams/raw_stream.h>
#include <components/bk_audio/audio_streams/onboard_speaker_stream.h>

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
    spk_cfg.dig_gain = dig_gain;
    spk_cfg.frame_size = sample_rate * channels * (bits / 8) * 20 / 1000; /* 20ms */
    spk_cfg.task_stack = 2048;
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

    BK_LOGI(TAG, "speaker pipeline running\r\n");
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
int bk_zig_speaker_write(const short *data, unsigned int samples)
{
    if (!s_raw_write) return -1;
    int bytes = raw_stream_write(s_raw_write, (char *)data, samples * sizeof(short));
    if (bytes < 0) return bytes;
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
