/**
 * @file aec_helper.c
 * @brief AEC (Acoustic Echo Cancellation) helper for Zig integration
 *
 * Wraps ESP-SR's esp_afe_aec API for use from Zig code.
 * Supports configurable input formats like "MR" (Mic+Ref) or "RMNM" (Ref+Mic+Null+Mic).
 */

#include <stdint.h>
#include <string.h>
#include "esp_log.h"
#include "esp_heap_caps.h"
#include "esp_afe_aec.h"

static const char *TAG = "sr_aec";

// Forward declarations
afe_aec_handle_t* aec_helper_create(const char *input_format, int filter_length, int type, int mode);
int aec_helper_process(afe_aec_handle_t *handle, const int16_t *indata, int16_t *outdata);
int aec_helper_get_chunksize(afe_aec_handle_t *handle);
int aec_helper_get_total_channels(afe_aec_handle_t *handle);
void aec_helper_destroy(afe_aec_handle_t *handle);
int16_t* aec_helper_alloc_buffer(int samples);
void aec_helper_free_buffer(int16_t *buf);

// Force linker to include these symbols
void aec_helper_force_link(void) {
    (void)aec_helper_create;
    (void)aec_helper_process;
    (void)aec_helper_get_chunksize;
    (void)aec_helper_destroy;
    (void)aec_helper_get_total_channels;
    (void)aec_helper_alloc_buffer;
    (void)aec_helper_free_buffer;
}

/**
 * @brief Create an AEC instance
 *
 * @param input_format Input format string:
 *        - "MR": Microphone + Reference (2 channels)
 *        - "RM": Reference + Microphone (2 channels)
 *        - "RMNM": Ref + Mic + Null + Mic (4 channels, Korvo-2 V3)
 * @param filter_length AEC filter length (recommended: 4 for ESP32-S3)
 * @param type AFE type: 0=SR (speech recognition), 1=VC (voice communication), 2=VC_8K
 * @param mode AFE mode: 0=LOW_COST, 1=HIGH_PERF
 * @return AEC handle or NULL on failure
 */
afe_aec_handle_t* aec_helper_create(const char *input_format, int filter_length, int type, int mode)
{
    ESP_LOGI(TAG, "Creating AEC: format=%s, filter=%d, type=%d, mode=%d",
             input_format, filter_length, type, mode);

    afe_aec_handle_t *handle = afe_aec_create(input_format, filter_length,
                                               (afe_type_t)type, (afe_mode_t)mode);
    if (handle == NULL) {
        ESP_LOGE(TAG, "Failed to create AEC handle");
        return NULL;
    }

    int chunk_size = afe_aec_get_chunksize(handle);
    ESP_LOGI(TAG, "AEC created: chunk_size=%d, total_ch=%d, mic_num=%d, sample_rate=%d",
             chunk_size,
             handle->pcm_config.total_ch_num,
             handle->pcm_config.mic_num,
             handle->pcm_config.sample_rate);

    return handle;
}

/**
 * @brief Process one frame of audio through AEC
 *
 * @param handle AEC handle from aec_helper_create
 * @param indata Input audio data (interleaved multi-channel)
 * @param outdata Output buffer for processed audio (must be 16-byte aligned)
 * @return Number of output samples, or negative on error
 */
int aec_helper_process(afe_aec_handle_t *handle, const int16_t *indata, int16_t *outdata)
{
    if (handle == NULL || indata == NULL || outdata == NULL) {
        return -1;
    }

    size_t ret = afe_aec_process(handle, indata, outdata);
    return (int)ret;
}

/**
 * @brief Get the chunk size (samples per frame) for AEC processing
 *
 * @param handle AEC handle
 * @return Number of samples per channel per frame (typically 256 for 16ms @ 16kHz)
 */
int aec_helper_get_chunksize(afe_aec_handle_t *handle)
{
    if (handle == NULL) {
        return -1;
    }
    return afe_aec_get_chunksize(handle);
}

/**
 * @brief Get the total number of input channels expected by AEC
 *
 * @param handle AEC handle
 * @return Total channel count from the input format
 */
int aec_helper_get_total_channels(afe_aec_handle_t *handle)
{
    if (handle == NULL) {
        return -1;
    }
    return handle->pcm_config.total_ch_num;
}

/**
 * @brief Destroy AEC instance and free resources
 *
 * @param handle AEC handle to destroy
 */
void aec_helper_destroy(afe_aec_handle_t *handle)
{
    if (handle != NULL) {
        ESP_LOGI(TAG, "Destroying AEC handle");
        afe_aec_destroy(handle);
    }
}

/**
 * @brief Allocate aligned buffer for AEC output
 *
 * AEC requires 16-byte aligned output buffers.
 *
 * @param samples Number of samples to allocate
 * @return Aligned buffer or NULL on failure
 */
int16_t* aec_helper_alloc_buffer(int samples)
{
    size_t size = samples * sizeof(int16_t);
    int16_t *buf = (int16_t *)heap_caps_aligned_calloc(16, 1, size, MALLOC_CAP_DEFAULT);
    if (buf == NULL) {
        ESP_LOGE(TAG, "Failed to allocate aligned buffer for %d samples", samples);
    }
    return buf;
}

/**
 * @brief Free buffer allocated by aec_helper_alloc_buffer
 *
 * @param buf Buffer to free
 */
void aec_helper_free_buffer(int16_t *buf)
{
    if (buf != NULL) {
        heap_caps_free(buf);
    }
}
