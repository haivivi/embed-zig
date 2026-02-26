//! BK Runtime — Runtime implementation using FreeRTOS (via Armino RTOS wrappers)
//!
//! Provides Mutex, Condition, and spawn for cross-platform async packages
//! on BK7258. Mirrors ESP runtime interface.
//!
//! ## Usage
//!
//! ```zig
//! const armino = @import("armino");
//! const Rt = armino.runtime;
//!
//! const MyChannel = channel.Channel(u32, 16, Rt);
//! ```

const std = @import("std");
const log = std.log.scoped(.bk_rt);

// ============================================================================
// C Helper bindings
// ============================================================================

extern fn bk_zig_mutex_create() ?*anyopaque;
extern fn bk_zig_mutex_destroy(handle: ?*anyopaque) void;
extern fn bk_zig_mutex_lock(handle: ?*anyopaque) void;
extern fn bk_zig_mutex_unlock(handle: ?*anyopaque) void;

extern fn bk_zig_cond_create() ?*anyopaque;
extern fn bk_zig_cond_destroy(handle: ?*anyopaque) void;
extern fn bk_zig_cond_signal(handle: ?*anyopaque) void;
extern fn bk_zig_cond_wait(handle: ?*anyopaque, timeout_ms: c_uint) c_int;

extern fn bk_zig_spawn(name: [*:0]const u8, func: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque, stack_size: c_uint, priority: c_uint) c_int;
extern fn bk_zig_sram_malloc(size: c_uint) ?[*]u8;
extern fn bk_zig_free(ptr: ?*anyopaque) void;
extern fn rtos_delete_thread(thread: ?*anyopaque) void;

fn sramFree(ptr: ?*anyopaque) void {
    bk_zig_free(ptr);
}

extern fn bk_zig_now_ms() u64;
extern fn bk_zig_sleep_ms(ms: c_uint) void;
extern fn bk_zig_get_cpu_count() c_int;

// ============================================================================
// Mutex
// ============================================================================

pub const Mutex = struct {
    handle: ?*anyopaque,

    pub fn init() Mutex {
        return .{ .handle = bk_zig_mutex_create() };
    }

    pub fn deinit(self: *Mutex) void {
        if (self.handle) |h| {
            bk_zig_mutex_destroy(h);
            self.handle = null;
        }
    }

    pub fn lock(self: *Mutex) void {
        bk_zig_mutex_lock(self.handle);
    }

    pub fn unlock(self: *Mutex) void {
        bk_zig_mutex_unlock(self.handle);
    }
};

// ============================================================================
// Condition — counting semaphore based
// ============================================================================

pub const Condition = struct {
    sem: ?*anyopaque,
    waiters: std.atomic.Value(u32),

    pub fn init() Condition {
        return .{
            .sem = bk_zig_cond_create(),
            .waiters = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *Condition) void {
        if (self.sem) |s| {
            bk_zig_cond_destroy(s);
            self.sem = null;
        }
    }

    /// Atomically release mutex, wait for signal, re-acquire mutex.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        _ = self.waiters.fetchAdd(1, .acq_rel);
        mutex.unlock();
        _ = bk_zig_cond_wait(self.sem, 0xFFFFFFFF); // portMAX_DELAY equivalent
        mutex.lock();
    }

    pub const TimedWaitResult = enum { signaled, timed_out };

    /// Wait with timeout (nanoseconds).
    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) TimedWaitResult {
        _ = self.waiters.fetchAdd(1, .acq_rel);
        const timeout_ms: u32 = @intCast(@min(timeout_ns / 1_000_000, std.math.maxInt(u32)));
        mutex.unlock();
        const result = bk_zig_cond_wait(self.sem, if (timeout_ms > 0) timeout_ms else 1);
        mutex.lock();
        if (result != 0) {
            _ = self.waiters.fetchSub(1, .acq_rel);
            return .timed_out;
        }
        return .signaled;
    }

    /// Wake one waiting thread.
    pub fn signal(self: *Condition) void {
        var current = self.waiters.load(.acquire);
        while (current > 0) {
            if (self.waiters.cmpxchgWeak(current, current - 1, .acq_rel, .acquire)) |actual| {
                current = actual;
                continue;
            }
            bk_zig_cond_signal(self.sem);
            break;
        }
    }

    /// Wake all waiting threads.
    pub fn broadcast(self: *Condition) void {
        var current = self.waiters.load(.acquire);
        while (current > 0) {
            if (self.waiters.cmpxchgWeak(current, 0, .acq_rel, .acquire)) |actual| {
                current = actual;
                continue;
            }
            while (current > 0) : (current -= 1) {
                bk_zig_cond_signal(self.sem);
            }
            break;
        }
    }
};

// ============================================================================
// Time
// ============================================================================

pub fn nowMs() u64 {
    return bk_zig_now_ms();
}

pub fn sleepMs(ms: u32) void {
    bk_zig_sleep_ms(ms);
}

// ============================================================================
// Spawn
// ============================================================================

pub const TaskFn = *const fn (?*anyopaque) void;

pub const Options = struct {
    stack_size: u32 = 8192,
    priority: u8 = 4,
    core: i8 = -1,
    // No allocator field — BK uses C-backed psram/sram allocators, not std.heap
};

const SpawnCtx = struct {
    func: TaskFn,
    ctx: ?*anyopaque,
};

fn spawnWrapper(raw_ctx: ?*anyopaque) callconv(.c) void {
    const spawn_ctx: *SpawnCtx = @ptrCast(@alignCast(raw_ctx));
    const func = spawn_ctx.func;
    const ctx = spawn_ctx.ctx;
    // Note: SpawnCtx is stack-allocated by caller in spawn(), which returns
    // before this runs. So we must copy before calling. But since FreeRTOS
    // creates the task synchronously, the caller's stack is still valid when
    // we read. However, to be safe we should copy immediately.
    // Actually, rtos_create_thread copies params, so by the time spawnWrapper
    // runs, we need allocated memory. Use a simple static approach.
    func(ctx);
}

// Static spawn context pool (simple, avoids dynamic allocation in spawn hot path)
var spawn_ctx_pool: [8]SpawnCtx = undefined;
var spawn_ctx_idx: u32 = 0;

pub fn spawn(name: [:0]const u8, func: TaskFn, ctx: ?*anyopaque, opts: Options) !void {
    _ = opts.core; // BK doesn't support core pinning via simple API

    // Use rotating pool for spawn context
    const idx = @atomicRmw(u32, &spawn_ctx_idx, .Add, 1, .monotonic) % 8;
    spawn_ctx_pool[idx] = .{ .func = func, .ctx = ctx };

    const ret = bk_zig_spawn(name.ptr, spawnWrapper, @ptrCast(&spawn_ctx_pool[idx]), opts.stack_size, opts.priority);
    if (ret != 0) return error.SpawnFailed;
}

// ============================================================================
// Thread (joinable) — simplified version
// ============================================================================

pub const Thread = struct {
    ctx: ?*ThreadCtx,

    pub const SpawnConfig = struct {
        stack_size: usize = 16384, // 16KB default
        priority: u8 = 4,
        core: i8 = -1,
    };

    const ThreadCtx = struct {
        func_ptr: *const anyopaque,
        args_ptr: *const anyopaque,
        cleanup_fn: *const fn (?*anyopaque) void,
        done_sem: ?*anyopaque,
        detached: std.atomic.Value(bool),
    };

    fn threadWrapper(raw_ctx: ?*anyopaque) callconv(.c) void {
        const thread_ctx: *ThreadCtx = @ptrCast(@alignCast(raw_ctx));

        const done_sem = thread_ctx.done_sem;
        const func_ptr = thread_ctx.func_ptr;
        const args_ptr = thread_ctx.args_ptr;
        const cleanup_fn = thread_ctx.cleanup_fn;

        const FnType = *const fn (*const anyopaque) void;
        const func: FnType = @ptrCast(@alignCast(func_ptr));
        func(args_ptr);

        cleanup_fn(@constCast(args_ptr));

        const is_detached = thread_ctx.detached.load(.acquire);
        if (is_detached) {
            if (done_sem) |s| bk_zig_cond_destroy(s);
            sramFree(thread_ctx);
        } else {
            if (done_sem) |s| bk_zig_cond_signal(s);
        }

        rtos_delete_thread(null);
    }

    /// Spawn a thread with comptime function + args tuple.
    pub fn spawn(config: SpawnConfig, comptime func: anytype, args: anytype) !Thread {
        const ArgsType = @TypeOf(args);

        const done_sem = bk_zig_cond_create();

        const thread_ctx_mem = bk_zig_sram_malloc(@intCast(@sizeOf(ThreadCtx))) orelse {
            if (done_sem) |s| bk_zig_cond_destroy(s);
            return error.SpawnFailed;
        };
        const thread_ctx: *ThreadCtx = @ptrCast(@alignCast(thread_ctx_mem));

        const args_mem = bk_zig_sram_malloc(@intCast(@sizeOf(ArgsType))) orelse {
            sramFree(thread_ctx);
            if (done_sem) |s| bk_zig_cond_destroy(s);
            return error.SpawnFailed;
        };
        const args_copy: *ArgsType = @ptrCast(@alignCast(args_mem));
        args_copy.* = args;

        const Wrapper = struct {
            fn call(args_ptr: *const anyopaque) void {
                const typed_args: *const ArgsType = @ptrCast(@alignCast(args_ptr));
                @call(.auto, func, typed_args.*);
            }

            fn cleanup(args_ptr: ?*anyopaque) void {
                sramFree(args_ptr);
            }
        };

        thread_ctx.* = .{
            .func_ptr = @ptrCast(&Wrapper.call),
            .args_ptr = @ptrCast(args_copy),
            .cleanup_fn = &Wrapper.cleanup,
            .done_sem = done_sem,
            .detached = std.atomic.Value(bool).init(false),
        };

        const ret = bk_zig_spawn(
            "zig-thr",
            threadWrapper,
            @ptrCast(thread_ctx),
            @intCast(config.stack_size),
            config.priority,
        );

        if (ret != 0) {
            sramFree(args_mem);
            sramFree(thread_ctx);
            if (done_sem) |s| bk_zig_cond_destroy(s);
            return error.SpawnFailed;
        }

        return .{ .ctx = thread_ctx };
    }

    pub fn join(self: Thread) void {
        if (self.ctx) |ctx| {
            if (ctx.done_sem) |s| {
                _ = bk_zig_cond_wait(s, 0xFFFFFFFF);
                bk_zig_cond_destroy(s);
            }
            sramFree(ctx);
        }
    }

    pub fn detach(self: Thread) void {
        if (self.ctx) |ctx| {
            ctx.detached.store(true, .release);
        }
    }
};

/// Get CPU core count
pub fn getCpuCount() !usize {
    return @intCast(bk_zig_get_cpu_count());
}
