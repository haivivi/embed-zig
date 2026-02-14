//! WebSim Screen + Audio Recorder
//!
//! Records the simulator output to an MP4 file using minih264e (H.264) + minimp4 (MP4 container).
//! Supports both video frames (RGBA) and audio (PCM i16 mono 16kHz).
//!
//! ## Usage
//!
//! ```zig
//! var rec = Recorder.start("/tmp/websim_recording.mp4", 960, 720, 30) orelse return;
//! defer rec.stop();
//!
//! // In frame loop:
//! rec.addFrame(rgba_pixels);
//! rec.addAudio(pcm_samples);
//! ```

const std = @import("std");

// C bridge functions (implemented in recorder_c.c + clipboard_macos.m)
const c = struct {
    const recorder_t = ?*anyopaque;

    extern fn websim_recorder_create(path: [*:0]const u8, width: c_int, height: c_int, fps: c_int) recorder_t;
    extern fn websim_recorder_add_frame(rec: recorder_t, rgba: [*]const u8) void;
    extern fn websim_recorder_add_audio(rec: recorder_t, pcm: [*]const i16, num_samples: c_int) void;
    extern fn websim_recorder_close(rec: recorder_t) void;
    extern fn websim_clipboard_copy_video(path: [*:0]const u8) c_int;
};

pub const Recorder = struct {
    handle: c.recorder_t,
    frame_count: u32 = 0,
    start_time_ms: i64,

    /// Start recording to the given file path.
    /// Width and height should match the webview window size.
    pub fn start(path: [:0]const u8, width: u32, height: u32, fps: u32) ?Recorder {
        const handle = c.websim_recorder_create(
            path.ptr,
            @intCast(width),
            @intCast(height),
            @intCast(fps),
        );
        if (handle == null) return null;

        std.debug.print("[Recorder] Started recording to: {s} ({}x{} @ {}fps)\n", .{ path, width, height, fps });

        return Recorder{
            .handle = handle,
            .start_time_ms = std.time.milliTimestamp(),
        };
    }

    /// Add a video frame (RGBA pixel data, width * height * 4 bytes).
    pub fn addFrame(self: *Recorder, rgba: []const u8) void {
        c.websim_recorder_add_frame(self.handle, rgba.ptr);
        self.frame_count += 1;
    }

    /// Add audio samples (PCM i16 mono).
    pub fn addAudio(self: *Recorder, pcm: []const i16) void {
        if (pcm.len == 0) return;
        c.websim_recorder_add_audio(self.handle, pcm.ptr, @intCast(pcm.len));
    }

    /// Stop recording, finalize MP4, and copy to clipboard.
    pub fn stop(self: *Recorder, path: [:0]const u8) void {
        const elapsed_ms = std.time.milliTimestamp() - self.start_time_ms;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

        c.websim_recorder_close(self.handle);
        self.handle = null;

        std.debug.print("[Recorder] Stopped. {} frames in {d:.1}s\n", .{ self.frame_count, elapsed_s });

        // Copy to clipboard
        if (c.websim_clipboard_copy_video(path.ptr) == 0) {
            std.debug.print("[Recorder] Copied to clipboard! Paste in WeChat/Feishu.\n", .{});
        } else {
            std.debug.print("[Recorder] Clipboard copy failed. File at: {s}\n", .{path});
        }
    }
};
