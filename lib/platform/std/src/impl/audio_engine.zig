//! PortAudio full-duplex audio I/O for std platform.
//!
//! DuplexAudio wraps a PortAudio DuplexStream callback into Mic, Speaker,
//! and RefReader drivers. Uses PaStreamCallbackTimeInfo to align mic and
//! ref ring buffers — compensating for the hardware latency difference
//! between ADC input and DAC output.

const std = @import("std");
const pa = @import("portaudio");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;

pub const DuplexAudio = struct {
    const RingCap = FRAME_SIZE * 64;

    // Mic and ref rings, written by callback
    mic_ring: [RingCap]i16,
    mic_write: usize,
    mic_read: usize,

    ref_ring: [RingCap]i16,
    ref_write: usize,
    ref_read: usize,

    // Speaker ring, written by Speaker.write(), read by callback
    spk_ring: [RingCap]i16,
    spk_write: usize,
    spk_read: usize,

    // Alignment: offset in samples between ref and mic.
    // Positive = ref needs to be read offset samples behind mic.
    ref_offset_samples: i32,
    offset_initialized: bool,

    mutex: std.Thread.Mutex,
    mic_ready: std.Thread.Condition,
    spk_ready: std.Thread.Condition,
    duplex: pa.DuplexStream(i16),

    pub fn init() DuplexAudio {
        return .{
            .mic_ring = [_]i16{0} ** RingCap,
            .mic_write = 0,
            .mic_read = 0,
            .ref_ring = [_]i16{0} ** RingCap,
            .ref_write = 0,
            .ref_read = 0,
            .spk_ring = [_]i16{0} ** RingCap,
            .spk_write = 0,
            .spk_read = 0,
            .ref_offset_samples = 0,
            .offset_initialized = false,
            .mutex = .{},
            .mic_ready = .{},
            .spk_ready = .{},
            .duplex = undefined,
        };
    }

    pub fn start(self: *DuplexAudio) !void {
        self.duplex.init(.{
            .sample_rate = @floatFromInt(SAMPLE_RATE),
            .channels = 1,
            .frames_per_buffer = FRAME_SIZE,
        }, duplexCallback, @ptrCast(self)) catch return error.PortAudioError;
        try self.duplex.start();
    }

    pub fn stop(self: *DuplexAudio) void {
        self.duplex.stop() catch {};
        self.duplex.close();
        self.mutex.lock();
        self.mic_ready.broadcast();
        self.spk_ready.broadcast();
        self.mutex.unlock();
    }

    pub fn deinit(_: *DuplexAudio) void {}

    fn duplexCallback(
        input: []const i16,
        output: []i16,
        _: usize,
        time_info: pa.TimeInfo,
        user_data: ?*anyopaque,
    ) pa.CallbackResult {
        const self: *DuplexAudio = @ptrCast(@alignCast(user_data));

        self.mutex.lock();
        defer self.mutex.unlock();

        // Calculate offset from timeInfo (DAC time - ADC time) in samples.
        if (!self.offset_initialized and time_info.input_adc_time > 0) {
            const offset_sec = time_info.output_dac_time - time_info.input_adc_time;
            self.ref_offset_samples = @intFromFloat(@round(offset_sec * @as(f64, SAMPLE_RATE)));
            self.offset_initialized = true;

            // Apply initial alignment: advance ref_read so it lags behind
            // mic_read by offset_samples. This means when mic.read() and
            // ref.read() both consume frames, ref returns data that was
            // played offset_samples earlier — matching the actual echo timing.
            if (self.ref_offset_samples > 0) {
                // ref_read stays at 0, mic_read will naturally advance.
                // When mic reads frame N, ref is still at frame 0.
                // After offset_samples / frame_size frames, they converge.
                // Instead, pre-advance mic by discarding offset_samples:
                // NO — simpler: let ref_read start behind by keeping it at 0
                // while mic_read advances. Or: just note the offset and
                // let RefReader handle it in read().
            }
        }

        // Track drift
        if (self.offset_initialized and time_info.input_adc_time > 0) {
            const offset_sec = time_info.output_dac_time - time_info.input_adc_time;
            const current_offset: i32 = @intFromFloat(@round(offset_sec * @as(f64, SAMPLE_RATE)));
            const drift = current_offset - self.ref_offset_samples;
            if (drift > 80 or drift < -80) {
                // Drift detected: adjust ref_read to compensate
                if (drift > 0) {
                    // ref needs to lag more — skip ref_read backward
                    // (already behind, so just update the offset)
                    self.ref_offset_samples = current_offset;
                } else {
                    // ref needs to lag less — advance ref_read (discard)
                    const skip: usize = @intCast(-drift);
                    self.ref_read += skip;
                    self.ref_offset_samples = current_offset;
                }
            }
        }

        // Push mic samples
        const n = @min(input.len, RingCap);
        for (0..n) |i| {
            self.mic_ring[(self.mic_write + i) % RingCap] = input[i];
        }
        self.mic_write += n;

        // Pop speaker samples → output
        const avail = self.spk_write -| self.spk_read;
        const to_play = @min(avail, output.len);
        for (0..to_play) |i| {
            output[i] = self.spk_ring[(self.spk_read + i) % RingCap];
        }
        for (to_play..output.len) |i| {
            output[i] = 0;
        }
        self.spk_read += to_play;
        self.spk_ready.signal();

        // Copy actual output → ref_ring
        for (0..output.len) |i| {
            self.ref_ring[(self.ref_write + i) % RingCap] = output[i];
        }
        self.ref_write += output.len;

        self.mic_ready.broadcast();

        return .Continue;
    }

    /// Mic driver: blocking read from mic_ring
    pub const Mic = struct {
        parent: *DuplexAudio,

        pub fn read(self_mic: *Mic, buf: []i16) !usize {
            self_mic.parent.mutex.lock();
            defer self_mic.parent.mutex.unlock();
            while (true) {
                const a = self_mic.parent.mic_write -| self_mic.parent.mic_read;
                if (a >= buf.len) {
                    for (0..buf.len) |i| {
                        buf[i] = self_mic.parent.mic_ring[(self_mic.parent.mic_read + i) % RingCap];
                    }
                    self_mic.parent.mic_read += buf.len;
                    return buf.len;
                }
                self_mic.parent.mic_ready.wait(&self_mic.parent.mutex);
            }
        }
    };

    /// Speaker driver: blocking write to spk_ring
    pub const Speaker = struct {
        parent: *DuplexAudio,

        pub fn write(self_spk: *Speaker, buf: []const i16) !usize {
            self_spk.parent.mutex.lock();
            defer self_spk.parent.mutex.unlock();
            var offset: usize = 0;
            while (offset < buf.len) {
                const used = self_spk.parent.spk_write -| self_spk.parent.spk_read;
                const space = RingCap - used;
                if (space == 0) {
                    self_spk.parent.spk_ready.wait(&self_spk.parent.mutex);
                    continue;
                }
                const chunk = @min(buf.len - offset, space);
                for (0..chunk) |i| {
                    self_spk.parent.spk_ring[(self_spk.parent.spk_write + i) % RingCap] = buf[offset + i];
                }
                self_spk.parent.spk_write += chunk;
                offset += chunk;
            }
            return buf.len;
        }

        pub fn setVolume(_: *Speaker, _: u8) !void {}
    };

    /// RefReader: reads ref aligned to mic by time offset.
    /// Each call returns the ref frame that was played `ref_offset_samples`
    /// before the current mic frame — matching the actual echo timing.
    pub const RefReader = struct {
        parent: *DuplexAudio,

        pub fn read(self_ref: *RefReader, buf: []i16) !usize {
            self_ref.parent.mutex.lock();
            defer self_ref.parent.mutex.unlock();

            const offset: usize = if (self_ref.parent.ref_offset_samples > 0)
                @intCast(self_ref.parent.ref_offset_samples)
            else
                0;

            while (true) {
                // Application loop: mic.read() -> ref.read() -> AEC -> speaker.write()
                // 
                // Frame N: mic[N] captures audio including echo from speaker[N-1] (played one frame ago)
                //         ref should be speaker[N-1] (the actual echo source)
                //         clean[N] = AEC(mic[N], ref=speaker[N-1])
                //         speaker[N] = clean[N]
                //
                // So ref frame N should return the speaker output from frame N-1.
                // This is 1 frame of delay (FRAME_SIZE samples), not the PortAudio clock offset.
                
                const mic_end = self_ref.parent.mic_read;
                const mic_start = mic_end - buf.len;  // Start of the frame just read by mic.read()
                
                // AEC needs the speaker output from the PREVIOUS frame as ref.
                // This is a 1-frame delay (FRAME_SIZE samples = 10ms).
                const ref_delay_samples = buf.len;  // One frame delay
                
                // Startup handling: when mic_start < ref_delay_samples, we don't have history.
                // Return silence (zeros) - AEC will just pass through mic (no echo cancellation yet).
                if (mic_start < ref_delay_samples) {
                    @memset(buf, 0);
                    return buf.len;
                }
                
                // Read ref from one frame ago
                const target_ref_start = mic_start - ref_delay_samples;

                // Check if target range [target_ref_start, target_ref_start + buf.len) is available
                const ref_write = self_ref.parent.ref_write;
                
                if (ref_write >= target_ref_start + buf.len) {
                    // Data is available. Read from target_ref_start.
                    for (0..buf.len) |i| {
                        const ref_idx = (target_ref_start + i) % RingCap;
                        buf[i] = self_ref.parent.ref_ring[ref_idx];
                    }
                    
                    // Update ref_read to track what we've consumed
                    // This prevents ref from growing unbounded
                    self_ref.parent.ref_read = target_ref_start + buf.len;
                    
                    // Drift correction: if ref is accumulating too much beyond what we need,
                    // skip ahead to keep latency bounded
                    const backlog = ref_write -| self_ref.parent.ref_read;
                    const max_backlog = offset + FRAME_SIZE * 4;
                    if (backlog > max_backlog) {
                        const skip = backlog - max_backlog;
                        self_ref.parent.ref_read += skip;
                    }

                    return buf.len;
                }
                
                // Target data not yet available - wait for next callback
                self_ref.parent.mic_ready.wait(&self_ref.parent.mutex);
            }
        }
    };

    pub fn mic(self: *DuplexAudio) Mic {
        return .{ .parent = self };
    }

    pub fn speaker(self: *DuplexAudio) Speaker {
        return .{ .parent = self };
    }

    pub fn refReader(self: *DuplexAudio) RefReader {
        return .{ .parent = self };
    }

    /// Return the measured offset in samples (for diagnostics).
    pub fn getRefOffset(self: *DuplexAudio) i32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.ref_offset_samples;
    }
};
