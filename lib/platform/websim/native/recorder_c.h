/**
 * WebSim Recorder C Bridge
 *
 * Thin C wrapper around minih264e.h + minimp4.h for Zig consumption.
 * Avoids @cImport issues with Zig multi-module builds.
 */
#ifndef WEBSIM_RECORDER_C_H
#define WEBSIM_RECORDER_C_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct websim_recorder websim_recorder_t;

/**
 * Create a new recorder.
 * @param path Output MP4 file path
 * @param width Video frame width (must be multiple of 16)
 * @param height Video frame height (must be multiple of 16)
 * @param fps Target frame rate
 * @return Recorder handle, or NULL on failure
 */
websim_recorder_t *websim_recorder_create(const char *path, int width, int height, int fps);

/**
 * Add a video frame (RGBA pixel data, top-left origin).
 * @param rec Recorder handle
 * @param rgba RGBA pixel buffer (width * height * 4 bytes)
 */
void websim_recorder_add_frame(websim_recorder_t *rec, const uint8_t *rgba);

/**
 * Add audio samples to the MP4 audio track.
 * @param rec Recorder handle
 * @param pcm PCM samples (signed 16-bit, mono)
 * @param num_samples Number of samples
 */
void websim_recorder_add_audio(websim_recorder_t *rec, const int16_t *pcm, int num_samples);

/**
 * Finalize and close the MP4 file.
 * @param rec Recorder handle (freed after this call)
 * @return 0 on success
 */
void websim_recorder_close(websim_recorder_t *rec);

/**
 * Copy a file's contents to the system clipboard as a video.
 * On macOS uses NSPasteboard with fileURL.
 * @param path Path to the MP4 file
 * @return 0 on success
 */
int websim_clipboard_copy_video(const char *path);

/**
 * Enable media capture (mic/camera) on the webview's WKWebView.
 * Must be called after webview_create, before loading content.
 * @param nswindow The NSWindow* from webview_get_native_handle
 */
void websim_enable_media_capture(void *nswindow);

/* Native audio removed — using localhost HTTP + WebRTC getUserMedia instead */

#ifdef __cplusplus
}
#endif

#endif /* WEBSIM_RECORDER_C_H */
