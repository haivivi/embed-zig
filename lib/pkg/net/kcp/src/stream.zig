//! Stream - A multiplexed reliable stream over KCP.
//!
//! Generic over Runtime (Rt) for cross-platform sync primitives.
//! Supports both manual mode (caller drives update/input) and auto mode
//! (background thread handles recv + update).
//!
//! ## Auto mode (recommended):
//! ```
//! var mux = Mux(Rt).init(alloc, config, true, output_fn, on_new_stream, null);
//! mux.start(recv_fn, null);  // spawns runLoop thread
//! const stream = try mux.openStream(0, &.{});
//! defer stream.close();
//! const n = try stream.readBlocking(&buf, 5_000_000_000);
//! mux.stop();
//! ```

const std = @import("std");
const kcp_mod = @import("kcp.zig");
const ring_buffer_mod = @import("ring_buffer.zig");

const RingBuffer = ring_buffer_mod.RingBuffer;

// Re-export types
pub const StreamState = enum(u32) {
    open = 0,
    local_close = 1,
    remote_close = 2,
    closed = 3,
};

pub const StreamError = error{
    StreamClosed,
    KcpSendFailed,
    Timeout,
    MuxClosed,
};

pub const MuxError = error{
    MuxClosed,
    OutOfMemory,
    InvalidFrame,
};

pub const MuxConfig = struct {
    max_frame_size: usize = 32 * 1024,
    max_receive_buffer: usize = 16 * 1024 * 1024,
    update_interval_ms: u32 = 1,
    spawn_stack_size: u32 = 16384,
};

pub const OutputFn = *const fn (data: []const u8, user_data: ?*anyopaque) anyerror!void;
pub const RecvFn = *const fn (buf: []u8, user_data: ?*anyopaque) anyerror!usize;
pub const OnNewStreamFn = *const fn (stream: *anyopaque, user_data: ?*anyopaque) void;

/// Stream — a multiplexed reliable stream over KCP.
///
/// Generic over Runtime type for cross-platform sync primitives.
/// Rt must provide: Mutex, Condition, Thread, nowMs(), sleepMs().
pub fn Stream(comptime Rt: type) type {
    return struct {
        const Self = @This();

        id: u32,
        proto: u8,
        metadata: []const u8,
        mux_ptr: *anyopaque,
        send_frame_fn: *const fn (mux: *anyopaque, cmd: kcp_mod.Cmd, stream_id: u32, payload: []const u8) anyerror!void,
        kcp_instance: ?kcp_mod.Kcp,
        recv_buf: RingBuffer(u8),
        allocator: std.mem.Allocator,

        kcp_mutex: Rt.Mutex,
        recv_mutex: Rt.Mutex,

        state: std.atomic.Value(StreamState),
        output_error: std.atomic.Value(bool),
        ref_count: std.atomic.Value(u32),
        max_receive_buffer: usize,
        data_available: Rt.Condition,

        pub fn init(
            allocator: std.mem.Allocator,
            id: u32,
            proto: u8,
            metadata: []const u8,
            mux_ptr: *anyopaque,
            send_frame_fn: *const fn (*anyopaque, kcp_mod.Cmd, u32, []const u8) anyerror!void,
            max_recv_buf: usize,
        ) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const meta_copy = if (metadata.len > 0)
                try allocator.dupe(u8, metadata)
            else
                &[_]u8{};

            self.* = Self{
                .id = id,
                .proto = proto,
                .metadata = meta_copy,
                .mux_ptr = mux_ptr,
                .send_frame_fn = send_frame_fn,
                .kcp_instance = null,
                .recv_buf = RingBuffer(u8).init(allocator),
                .allocator = allocator,
                .kcp_mutex = Rt.Mutex.init(),
                .recv_mutex = Rt.Mutex.init(),
                .state = std.atomic.Value(StreamState).init(.open),
                .output_error = std.atomic.Value(bool).init(false),
                .ref_count = std.atomic.Value(u32).init(1),
                .max_receive_buffer = max_recv_buf,
                .data_available = Rt.Condition.init(),
            };

            self.kcp_instance = try kcp_mod.Kcp.init(id, &Self.kcpOutput, self);
            if (self.kcp_instance) |*k| {
                k.setUserPtr();
                k.setDefaultConfig();
            }

            return self;
        }

        pub fn retain(self: *Self) void {
            _ = self.ref_count.fetchAdd(1, .seq_cst);
        }

        pub fn release(self: *Self) bool {
            const old = self.ref_count.fetchSub(1, .seq_cst);
            if (old == 1) {
                self.deinitInternal();
                return true;
            }
            return false;
        }

        pub fn close(self: *Self) void {
            self.shutdown();
            _ = self.release();
        }

        fn deinitInternal(self: *Self) void {
            if (self.kcp_instance) |*k| k.deinit();
            if (self.metadata.len > 0) self.allocator.free(@constCast(self.metadata));
            self.recv_buf.deinit();
            self.data_available.deinit();
            self.recv_mutex.deinit();
            self.kcp_mutex.deinit();
            self.allocator.destroy(self);
        }

        pub fn getId(self: *const Self) u32 {
            return self.id;
        }

        pub fn getProto(self: *const Self) u8 {
            return self.proto;
        }

        pub fn getMetadata(self: *const Self) []const u8 {
            return self.metadata;
        }

        pub fn getState(self: *const Self) StreamState {
            return self.state.load(.seq_cst);
        }

        pub fn write(self: *Self, data: []const u8) StreamError!usize {
            const current_state = self.state.load(.seq_cst);
            if (current_state == .closed or current_state == .local_close) {
                return StreamError.StreamClosed;
            }

            self.kcp_mutex.lock();
            defer self.kcp_mutex.unlock();

            if (self.kcp_instance) |*k| {
                const ret = k.send(data);
                if (ret < 0) return StreamError.KcpSendFailed;
                return data.len;
            }

            return StreamError.KcpSendFailed;
        }

        pub fn flush(self: *Self) StreamError!void {
            self.kcp_mutex.lock();
            defer self.kcp_mutex.unlock();
            if (self.kcp_instance) |*k| k.flush();
        }

        pub fn read(self: *Self, buffer: []u8) StreamError!usize {
            self.recv_mutex.lock();
            defer self.recv_mutex.unlock();
            if (self.recv_buf.readableLength() == 0) return 0;
            return self.recv_buf.read(buffer);
        }

        pub fn readBlocking(self: *Self, buffer: []u8, timeout_ns: ?u64) StreamError!usize {
            self.recv_mutex.lock();
            defer self.recv_mutex.unlock();

            while (self.recv_buf.readableLength() == 0) {
                const current_state = self.state.load(.seq_cst);
                if (current_state == .closed or current_state == .remote_close) return 0;

                if (timeout_ns) |ns| {
                    const result = self.data_available.timedWait(&self.recv_mutex, ns);
                    if (result == .timed_out) return StreamError.Timeout;
                } else {
                    self.data_available.wait(&self.recv_mutex);
                }
            }

            return self.recv_buf.read(buffer);
        }

        pub fn shutdown(self: *Self) void {
            const current_state = self.state.load(.seq_cst);
            if (current_state == .closed or current_state == .local_close) return;

            const should_send_fin = current_state == .open;
            if (current_state == .open) {
                self.state.store(.local_close, .seq_cst);
            } else {
                self.state.store(.closed, .seq_cst);
            }

            if (should_send_fin) {
                self.send_frame_fn(self.mux_ptr, .fin, self.id, &[_]u8{}) catch {};
            }
        }

        pub fn kcpInput(self: *Self, data: []const u8) void {
            if (self.state.load(.seq_cst) == .closed) return;
            self.kcp_mutex.lock();
            defer self.kcp_mutex.unlock();
            if (self.kcp_instance) |*k| _ = k.input(data);
        }

        pub fn kcpRecv(self: *Self) bool {
            var received = false;
            var stack_buf: [1500]u8 = undefined;
            var heap_buf: ?[]u8 = null;
            defer if (heap_buf) |buf| self.allocator.free(buf);

            while (true) {
                self.kcp_mutex.lock();
                const size = if (self.kcp_instance) |*k| k.peekSize() else -1;
                if (size <= 0) {
                    self.kcp_mutex.unlock();
                    break;
                }

                const usize_size: usize = @intCast(size);
                var data_slice: []u8 = undefined;

                if (usize_size <= stack_buf.len) {
                    const n = if (self.kcp_instance) |*k| k.recv(stack_buf[0..usize_size]) else -1;
                    self.kcp_mutex.unlock();
                    if (n <= 0) break;
                    data_slice = stack_buf[0..@intCast(n)];
                } else {
                    if (heap_buf == null or heap_buf.?.len < usize_size) {
                        if (heap_buf) |old| self.allocator.free(old);
                        heap_buf = self.allocator.alloc(u8, usize_size) catch {
                            self.kcp_mutex.unlock();
                            break;
                        };
                    }
                    const n = if (self.kcp_instance) |*k| k.recv(heap_buf.?[0..usize_size]) else -1;
                    self.kcp_mutex.unlock();
                    if (n <= 0) break;
                    data_slice = heap_buf.?[0..@intCast(n)];
                }

                self.recv_mutex.lock();
                const current_size = self.recv_buf.readableLength();
                if (current_size + data_slice.len > self.max_receive_buffer) {
                    self.recv_mutex.unlock();
                    break;
                }
                self.recv_buf.write(data_slice) catch {
                    self.recv_mutex.unlock();
                    break;
                };
                self.data_available.signal();
                self.recv_mutex.unlock();
                received = true;
            }

            return received;
        }

        pub fn kcpUpdate(self: *Self, current: u32) void {
            if (self.state.load(.seq_cst) == .closed) return;
            self.kcp_mutex.lock();
            defer self.kcp_mutex.unlock();
            if (self.kcp_instance) |*k| k.update(current);
        }

        pub fn handleFin(self: *Self) void {
            const current_state = self.state.load(.seq_cst);
            if (current_state == .local_close) {
                self.state.store(.closed, .seq_cst);
            } else if (current_state == .open) {
                self.state.store(.remote_close, .seq_cst);
            }
            // Hold recv_mutex while broadcasting to prevent lost wakeup:
            // readBlocking checks state then calls wait() under recv_mutex,
            // so broadcast without the mutex can fire in between and be missed.
            self.recv_mutex.lock();
            self.data_available.broadcast();
            self.recv_mutex.unlock();
        }

        fn kcpOutput(data: []const u8, user: ?*anyopaque) void {
            if (user) |u| {
                const stream: *Self = @ptrCast(@alignCast(u));
                stream.send_frame_fn(stream.mux_ptr, .psh, stream.id, data) catch |err| {
                    stream.output_error.store(true, .seq_cst);
                    std.log.err("Stream {d} output error: {s}", .{ stream.id, @errorName(err) });
                };
            }
        }
    };
}

/// Mux multiplexes streams over a single connection.
///
/// Generic over Runtime type for cross-platform sync + timer.
/// Rt must provide: Mutex, Condition, Thread, nowMs(), sleepMs().
pub fn Mux(comptime Rt: type) type {
    const StreamType = Stream(Rt);

    return struct {
        const Self = @This();

        config: MuxConfig,
        output_fn: OutputFn,
        on_new_stream: OnNewStreamFn,
        user_data: ?*anyopaque,
        is_client: bool,
        streams: std.AutoHashMap(u32, *StreamType),
        next_id: u32,
        closed: std.atomic.Value(bool),
        allocator: std.mem.Allocator,
        mutex: Rt.Mutex,
        ref_count: std.atomic.Value(u32),

        accept_queue: AcceptQueue,
        accept_cond: Rt.Condition,
        output_mutex: Rt.Mutex,

        recv_fn: ?RecvFn,
        recv_user_data: ?*anyopaque,
        stop_flag: std.atomic.Value(bool),
        run_thread: ?Rt.Thread,

        const AcceptQueue = struct {
            buf: [16]?*StreamType = [_]?*StreamType{null} ** 16,
            head: usize = 0,
            tail: usize = 0,
            len: usize = 0,
            is_closed: bool = false,

            fn push(self: *AcceptQueue, item: *StreamType) bool {
                if (self.len >= 16) return false;
                self.buf[self.tail] = item;
                self.tail = (self.tail + 1) % 16;
                self.len += 1;
                return true;
            }

            fn pop(self: *AcceptQueue) ?*StreamType {
                if (self.len == 0) return null;
                const item = self.buf[self.head];
                self.buf[self.head] = null;
                self.head = (self.head + 1) % 16;
                self.len -= 1;
                return item;
            }
        };

        pub fn init(
            allocator: std.mem.Allocator,
            config: MuxConfig,
            is_client: bool,
            output_fn: OutputFn,
            on_new_stream: OnNewStreamFn,
            user_data: ?*anyopaque,
        ) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = Self{
                .config = config,
                .output_fn = output_fn,
                .on_new_stream = on_new_stream,
                .user_data = user_data,
                .is_client = is_client,
                .streams = std.AutoHashMap(u32, *StreamType).init(allocator),
                .next_id = if (is_client) 1 else 2,
                .closed = std.atomic.Value(bool).init(false),
                .allocator = allocator,
                .mutex = Rt.Mutex.init(),
                .ref_count = std.atomic.Value(u32).init(1),
                .accept_queue = .{},
                .accept_cond = Rt.Condition.init(),
                .output_mutex = Rt.Mutex.init(),
                .recv_fn = null,
                .recv_user_data = null,
                .stop_flag = std.atomic.Value(bool).init(false),
                .run_thread = null,
            };

            return self;
        }

        // ================================================================
        // Auto mode
        // ================================================================

        pub fn start(self: *Self, recv_fn: RecvFn, recv_user_data: ?*anyopaque) !void {
            self.recv_fn = recv_fn;
            self.recv_user_data = recv_user_data;
            self.stop_flag.store(false, .release);
            self.run_thread = Rt.Thread.spawn(.{}, runLoopWrapper, .{self});
        }

        pub fn stop(self: *Self) void {
            self.stop_flag.store(true, .release);
            if (self.run_thread) |t| {
                t.join();
                self.run_thread = null;
            }
        }

        fn runLoopWrapper(self: *Self) void {
            self.runLoop();
        }

        fn runLoop(self: *Self) void {
            const recv_fn = self.recv_fn orelse return;
            var buf: [2048]u8 = undefined;

            while (!self.stop_flag.load(.acquire)) {
                const n = recv_fn(&buf, self.recv_user_data) catch 0;
                if (n > 0) {
                    self.input(buf[0..n]) catch {};
                }
                self.update();
            }
        }

        // ================================================================
        // Manual mode
        // ================================================================

        pub fn update(self: *Self) void {
            if (self.closed.load(.acquire)) return;

            const current: u32 = @intCast(Rt.nowMs() & 0xFFFFFFFF);

            var stream_list: std.ArrayListUnmanaged(*StreamType) = .{};
            defer stream_list.deinit(self.allocator);

            self.mutex.lock();
            var iter = self.streams.valueIterator();
            while (iter.next()) |stream_ptr| {
                stream_list.append(self.allocator, stream_ptr.*) catch break;
            }
            self.mutex.unlock();

            for (stream_list.items) |stream| {
                stream.kcpUpdate(current);
                _ = stream.kcpRecv();
            }
        }

        pub fn retain(self: *Self) void {
            _ = self.ref_count.fetchAdd(1, .seq_cst);
        }

        pub fn release(self: *Self) bool {
            const old = self.ref_count.fetchSub(1, .seq_cst);
            if (old == 1) {
                self.deinitInternal();
                return true;
            }
            return false;
        }

        pub fn deinit(self: *Self) void {
            if (self.recv_fn != null) self.stop();
            self.closed.store(true, .release);

            self.mutex.lock();
            self.accept_queue.is_closed = true;
            self.accept_cond.broadcast();
            var val_iter = self.streams.valueIterator();
            while (val_iter.next()) |stream_ptr| {
                stream_ptr.*.state.store(.closed, .seq_cst);
                _ = stream_ptr.*.release();
            }
            self.streams.deinit();
            self.mutex.unlock();

            _ = self.release();
        }

        fn deinitInternal(self: *Self) void {
            self.output_mutex.deinit();
            self.accept_cond.deinit();
            self.mutex.deinit();
            self.allocator.destroy(self);
        }

        pub fn isClosed(self: *Self) bool {
            return self.closed.load(.acquire);
        }

        pub fn openStream(self: *Self, proto: u8, metadata: []const u8) MuxError!*StreamType {
            if (self.closed.load(.acquire)) return MuxError.MuxClosed;

            self.mutex.lock();
            defer self.mutex.unlock();

            const id = self.next_id;
            self.next_id += 2;

            const stream = StreamType.init(
                self.allocator,
                id,
                proto,
                metadata,
                self,
                sendFrameWrapper,
                self.config.max_receive_buffer,
            ) catch return MuxError.OutOfMemory;

            self.streams.put(id, stream) catch {
                _ = stream.release();
                return MuxError.OutOfMemory;
            };

            const syn_payload = if (proto != 0 or metadata.len > 0) blk: {
                const total = std.math.add(usize, 1, metadata.len) catch return MuxError.OutOfMemory;
                const buf = self.allocator.alloc(u8, total) catch return MuxError.OutOfMemory;
                buf[0] = proto;
                if (metadata.len > 0) @memcpy(buf[1..], metadata);
                break :blk buf;
            } else &[_]u8{};
            defer if (proto != 0 or metadata.len > 0) self.allocator.free(syn_payload);

            self.sendFrameInternal(.syn, id, syn_payload) catch {
                _ = self.streams.remove(id);
                _ = stream.release();
                return MuxError.OutOfMemory;
            };

            stream.retain();
            return stream;
        }

        pub fn acceptStream(self: *Self) ?*StreamType {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.accept_queue.len == 0) {
                if (self.accept_queue.is_closed) return null;
                self.accept_cond.wait(&self.mutex);
            }
            return self.accept_queue.pop();
        }

        pub fn acceptStreamTimeout(self: *Self, timeout_ns: u64) ?*StreamType {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.accept_queue.len == 0) {
                if (self.accept_queue.is_closed) return null;
                const result = self.accept_cond.timedWait(&self.mutex, timeout_ns);
                if (result == .timed_out) return null;
            }
            return self.accept_queue.pop();
        }

        pub fn tryAcceptStream(self: *Self) ?*StreamType {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.accept_queue.pop();
        }

        pub fn input(self: *Self, data: []const u8) MuxError!void {
            if (self.closed.load(.acquire)) return MuxError.MuxClosed;

            const frame = kcp_mod.Frame.decode(data) catch return MuxError.InvalidFrame;

            self.mutex.lock();
            defer self.mutex.unlock();

            switch (frame.cmd) {
                .syn => self.handleSynWithPayload(frame.stream_id, frame.payload),
                .fin => self.handleFin(frame.stream_id),
                .psh => self.handlePsh(frame.stream_id, frame.payload),
                .nop => {},
            }
        }

        fn handleSynWithPayload(self: *Self, id: u32, payload: []const u8) void {
            if (self.streams.contains(id)) return;

            const proto: u8 = if (payload.len >= 1) payload[0] else 0;
            const metadata: []const u8 = if (payload.len > 1) payload[1..] else &[_]u8{};

            const stream = StreamType.init(
                self.allocator,
                id,
                proto,
                metadata,
                self,
                sendFrameWrapper,
                self.config.max_receive_buffer,
            ) catch return;

            self.streams.put(id, stream) catch {
                _ = stream.release();
                return;
            };

            stream.retain();
            if (!self.accept_queue.push(stream)) {
                _ = stream.release();
            } else {
                self.accept_cond.signal();
            }

            // Retain for callback duration — another thread could accept + close
            // the stream while we're outside the mutex.
            stream.retain();
            self.mutex.unlock();
            self.on_new_stream(@ptrCast(stream), self.user_data);
            self.mutex.lock();
            _ = stream.release();
        }

        fn handleFin(self: *Self, id: u32) void {
            if (self.streams.get(id)) |stream| stream.handleFin();
        }

        fn handlePsh(self: *Self, id: u32, payload: []const u8) void {
            const stream = self.streams.get(id) orelse return;
            stream.retain();
            self.mutex.unlock();
            stream.kcpInput(payload);
            _ = stream.kcpRecv();
            _ = stream.release();
            self.mutex.lock();
        }

        fn sendFrameWrapper(mux_ptr: *anyopaque, cmd: kcp_mod.Cmd, stream_id: u32, payload: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(mux_ptr));
            try self.sendFrameInternal(cmd, stream_id, payload);
        }

        fn sendFrameInternal(self: *Self, cmd: kcp_mod.Cmd, stream_id: u32, payload: []const u8) !void {
            if (self.closed.load(.acquire)) return MuxError.MuxClosed;

            const frame = kcp_mod.Frame{
                .cmd = cmd,
                .stream_id = stream_id,
                .payload = payload,
            };

            const required_size = kcp_mod.FrameHeaderSize + payload.len;
            var stack_buf: [1500]u8 = undefined;

            self.output_mutex.lock();
            defer self.output_mutex.unlock();

            if (required_size <= stack_buf.len) {
                const encoded = try frame.encode(&stack_buf);
                try self.output_fn(encoded, self.user_data);
            } else {
                const buf = try self.allocator.alloc(u8, required_size);
                defer self.allocator.free(buf);
                const encoded = try frame.encode(buf);
                try self.output_fn(encoded, self.user_data);
            }
        }

        pub fn removeStream(self: *Self, id: u32) void {
            self.mutex.lock();
            const maybe_stream = self.streams.fetchRemove(id);
            self.mutex.unlock();
            if (maybe_stream) |kv| _ = kv.value.release();
        }

        pub fn numStreams(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.streams.count();
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

const TestRuntime = if (@import("builtin").os.tag != .freestanding) struct {
    pub const Mutex = struct {
        inner: std.Thread.Mutex = .{},
        pub fn init() Mutex {
            return .{};
        }
        pub fn deinit(_: *Mutex) void {}
        pub fn lock(self: *Mutex) void {
            self.inner.lock();
        }
        pub fn unlock(self: *Mutex) void {
            self.inner.unlock();
        }
    };
    pub const Condition = struct {
        inner: std.Thread.Condition = .{},
        pub const TimedWaitResult = enum { signaled, timed_out };
        pub fn init() Condition {
            return .{};
        }
        pub fn deinit(_: *Condition) void {}
        pub fn wait(self: *Condition, mutex: *Mutex) void {
            self.inner.wait(&mutex.inner);
        }
        pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) TimedWaitResult {
            return if (self.inner.timedWait(&mutex.inner, timeout_ns) == .timed_out) .timed_out else .signaled;
        }
        pub fn signal(self: *Condition) void {
            self.inner.signal();
        }
        pub fn broadcast(self: *Condition) void {
            self.inner.broadcast();
        }
    };
    pub const Thread = std.Thread;
    pub fn nowMs() u64 {
        return @intCast(std.time.milliTimestamp());
    }
    pub fn sleepMs(ms: u32) void {
        std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
    }
} else struct {};

test "Stream init deinit" {
    if (@import("builtin").os.tag == .freestanding) return;
    const allocator = std.testing.allocator;

    const DummyMux = struct {
        fn sendFrame(_: *anyopaque, _: kcp_mod.Cmd, _: u32, _: []const u8) anyerror!void {}
    };

    var dummy: u8 = 0;
    const StreamT = Stream(TestRuntime);
    const stream = try StreamT.init(allocator, 1, 0, &[_]u8{}, &dummy, DummyMux.sendFrame, 256 * 1024);
    defer _ = stream.release();

    try std.testing.expectEqual(@as(u32, 1), stream.getId());
    try std.testing.expectEqual(@as(u8, 0), stream.getProto());
    try std.testing.expectEqual(@as(usize, 0), stream.getMetadata().len);
    try std.testing.expectEqual(StreamState.open, stream.getState());
}
