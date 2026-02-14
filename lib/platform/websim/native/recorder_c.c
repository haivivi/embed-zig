/**
 * WebSim Recorder C Implementation
 *
 * Uses minih264e.h for H.264 encoding and minimp4.h for MP4 muxing.
 * Provides a simple C API for Zig consumption.
 */

#include "recorder_c.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Include single-header APIs (without implementations — those go in separate TUs) */
#include "minih264e.h"
#include "minimp4.h"

/* ======================================================================== */
/* Recorder state                                                            */
/* ======================================================================== */

struct websim_recorder {
    /* MP4 muxer */
    MP4E_mux_t *mux;
    mp4_h26x_writer_t h264_writer;
    FILE *fp;

    /* H.264 encoder */
    H264E_persist_t *enc;
    H264E_scratch_t *scratch;

    /* Frame parameters */
    int width;
    int height;
    int fps;
    int frame_count;

    /* YUV conversion buffer */
    uint8_t *yuv_buf;

    /* Audio track */
    int audio_track_id;
    int audio_sample_count;
};

/* ======================================================================== */
/* MP4 write callback                                                        */
/* ======================================================================== */

static int mp4_write_callback(int64_t offset, const void *buffer, size_t size, void *token) {
    FILE *fp = (FILE *)token;
    if (fseeko(fp, offset, SEEK_SET)) return 1;
    return fwrite(buffer, 1, size, fp) != size;
}

/* ======================================================================== */
/* RGB to YUV420 conversion                                                  */
/* ======================================================================== */

static void rgba_to_yuv420(const uint8_t *rgba, uint8_t *y_plane, uint8_t *u_plane, uint8_t *v_plane,
                           int width, int height, int y_stride, int uv_stride) {
    for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
            int idx = (row * width + col) * 4;
            int r = rgba[idx + 0];
            int g = rgba[idx + 1];
            int b = rgba[idx + 2];

            /* BT.601 RGB->YUV */
            int y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
            y_plane[row * y_stride + col] = (uint8_t)(y < 16 ? 16 : (y > 235 ? 235 : y));

            if ((row & 1) == 0 && (col & 1) == 0) {
                int u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
                int v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
                u_plane[(row / 2) * uv_stride + (col / 2)] = (uint8_t)(u < 16 ? 16 : (u > 240 ? 240 : u));
                v_plane[(row / 2) * uv_stride + (col / 2)] = (uint8_t)(v < 16 ? 16 : (v > 240 ? 240 : v));
            }
        }
    }
}

/* ======================================================================== */
/* Public API                                                                */
/* ======================================================================== */

websim_recorder_t *websim_recorder_create(const char *path, int width, int height, int fps) {
    websim_recorder_t *rec = (websim_recorder_t *)calloc(1, sizeof(websim_recorder_t));
    if (!rec) return NULL;

    rec->width = width;
    rec->height = height;
    rec->fps = fps;
    rec->frame_count = 0;
    rec->audio_sample_count = 0;

    /* Align width/height to 16 for H.264 */
    int aligned_w = (width + 15) & ~15;
    int aligned_h = (height + 15) & ~15;

    /* Open output file */
    rec->fp = fopen(path, "wb");
    if (!rec->fp) { free(rec); return NULL; }

    /* Initialize MP4 muxer */
    rec->mux = MP4E_open(0 /* not sequential */, 0 /* no fragmentation */, rec->fp, mp4_write_callback);
    if (!rec->mux) { fclose(rec->fp); free(rec); return NULL; }

    /* Initialize H.264 writer (handles SPS/PPS/NAL packaging) */
    if (mp4_h26x_write_init(&rec->h264_writer, rec->mux, width, height, 0 /* not HEVC */)) {
        MP4E_close(rec->mux);
        fclose(rec->fp);
        free(rec);
        return NULL;
    }

    /* Add audio track (PCM 16-bit mono 16kHz) */
    {
        MP4E_track_t tr;
        memset(&tr, 0, sizeof(tr));
        tr.track_media_kind = e_audio;
        tr.time_scale = 16000;
        tr.default_duration = 1; /* 1 sample per packet */
        tr.u.a.channelcount = 1;
        rec->audio_track_id = MP4E_add_track(rec->mux, &tr);
    }

    /* Initialize H.264 encoder */
    {
        H264E_create_param_t par;
        memset(&par, 0, sizeof(par));
        par.width = aligned_w;
        par.height = aligned_h;
        par.fine_rate_control_flag = 0;
        par.const_input_flag = 1;
        par.vbv_size_bytes = 100000 / 8;
        par.gop = fps; /* I-frame every N frames */
        par.max_threads = 1;
        par.max_long_term_reference_frames = 0;
        par.temporal_denoise_flag = 0;

        int sizeof_persist = 0, sizeof_scratch = 0;
        if (H264E_sizeof(&par, &sizeof_persist, &sizeof_scratch) != 0) {
            mp4_h26x_write_close(&rec->h264_writer);
            MP4E_close(rec->mux);
            fclose(rec->fp);
            free(rec);
            return NULL;
        }

        rec->enc = (H264E_persist_t *)calloc(1, sizeof_persist);
        rec->scratch = (H264E_scratch_t *)calloc(1, sizeof_scratch);
        if (!rec->enc || !rec->scratch) {
            free(rec->enc);
            free(rec->scratch);
            mp4_h26x_write_close(&rec->h264_writer);
            MP4E_close(rec->mux);
            fclose(rec->fp);
            free(rec);
            return NULL;
        }

        if (H264E_init(rec->enc, &par) != 0) {
            free(rec->enc);
            free(rec->scratch);
            mp4_h26x_write_close(&rec->h264_writer);
            MP4E_close(rec->mux);
            fclose(rec->fp);
            free(rec);
            return NULL;
        }
    }

    /* Allocate YUV buffer */
    {
        int y_size = aligned_w * aligned_h;
        int uv_size = (aligned_w / 2) * (aligned_h / 2);
        rec->yuv_buf = (uint8_t *)calloc(1, y_size + uv_size * 2);
        if (!rec->yuv_buf) {
            free(rec->enc);
            free(rec->scratch);
            mp4_h26x_write_close(&rec->h264_writer);
            MP4E_close(rec->mux);
            fclose(rec->fp);
            free(rec);
            return NULL;
        }
    }

    return rec;
}

void websim_recorder_add_frame(websim_recorder_t *rec, const uint8_t *rgba) {
    if (!rec || !rgba) return;

    int aligned_w = (rec->width + 15) & ~15;
    int aligned_h = (rec->height + 15) & ~15;
    int y_size = aligned_w * aligned_h;
    int uv_stride = aligned_w / 2;

    uint8_t *y_plane = rec->yuv_buf;
    uint8_t *u_plane = rec->yuv_buf + y_size;
    uint8_t *v_plane = u_plane + (aligned_w / 2) * (aligned_h / 2);

    /* Convert RGBA to YUV420 */
    rgba_to_yuv420(rgba, y_plane, u_plane, v_plane,
                   rec->width, rec->height, aligned_w, uv_stride);

    /* Encode frame */
    H264E_io_yuv_t yuv;
    yuv.yuv[0] = y_plane;
    yuv.yuv[1] = u_plane;
    yuv.yuv[2] = v_plane;
    yuv.stride[0] = aligned_w;
    yuv.stride[1] = uv_stride;
    yuv.stride[2] = uv_stride;

    H264E_run_param_t run;
    memset(&run, 0, sizeof(run));
    run.frame_type = 0; /* auto */
    run.encode_speed = 6; /* faster encoding for realtime */
    run.desired_frame_bytes = 50000; /* ~50KB per frame target */
    run.qp_min = 10;
    run.qp_max = 40;

    unsigned char *coded_data = NULL;
    int coded_size = 0;

    if (H264E_encode(rec->enc, rec->scratch, &run, &yuv, &coded_data, &coded_size) == 0) {
        if (coded_data && coded_size > 0) {
            /* Calculate timestamp in 90kHz units (standard for MP4 video) */
            unsigned ts_next = (unsigned)((rec->frame_count + 1) * 90000ULL / rec->fps);
            mp4_h26x_write_nal(&rec->h264_writer, coded_data, coded_size, ts_next);
        }
    }

    rec->frame_count++;
}

void websim_recorder_add_audio(websim_recorder_t *rec, const int16_t *pcm, int num_samples) {
    if (!rec || !pcm || num_samples <= 0) return;
    if (rec->audio_track_id < 0) return;

    /* Write PCM samples as a single MP4 sample */
    int data_bytes = num_samples * 2; /* 16-bit samples */
    MP4E_put_sample(rec->mux, rec->audio_track_id, pcm, data_bytes,
                    num_samples, MP4E_SAMPLE_DEFAULT);
    rec->audio_sample_count += num_samples;
}

void websim_recorder_close(websim_recorder_t *rec) {
    if (!rec) return;

    mp4_h26x_write_close(&rec->h264_writer);
    MP4E_close(rec->mux);
    fclose(rec->fp);

    free(rec->yuv_buf);
    free(rec->scratch);
    free(rec->enc);
    free(rec);
}
