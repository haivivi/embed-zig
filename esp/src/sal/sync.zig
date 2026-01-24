//! SAL Sync Implementation - FreeRTOS
//!
//! Implements sal.sync interface using FreeRTOS semaphores and event groups.

const std = @import("std");

const c = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/semphr.h");
    @cInclude("freertos/event_groups.h");
});

// ============================================================================
// Mutex - Mutual Exclusion Lock
// ============================================================================

pub const Mutex = struct {
    handle: c.SemaphoreHandle_t,

    /// Initialize mutex
    pub fn init() Mutex {
        const handle = c.xSemaphoreCreateMutex();
        return .{ .handle = handle };
    }

    /// Release mutex resources
    pub fn deinit(self: *Mutex) void {
        if (self.handle != null) {
            c.vSemaphoreDelete(self.handle);
            self.handle = null;
        }
    }

    /// Acquire the mutex (blocking)
    pub fn lock(self: *Mutex) void {
        _ = c.xSemaphoreTake(self.handle, c.portMAX_DELAY);
    }

    /// Try to acquire the mutex (non-blocking)
    /// Returns true if acquired, false if already held
    pub fn tryLock(self: *Mutex) bool {
        return c.xSemaphoreTake(self.handle, 0) == c.pdTRUE;
    }

    /// Try to acquire with timeout
    /// Returns true if acquired, false if timeout
    pub fn lockTimeout(self: *Mutex, timeout_ms: u32) bool {
        const ticks = timeout_ms / c.portTICK_PERIOD_MS;
        return c.xSemaphoreTake(self.handle, ticks) == c.pdTRUE;
    }

    /// Release the mutex
    pub fn unlock(self: *Mutex) void {
        _ = c.xSemaphoreGive(self.handle);
    }

    /// RAII-style scoped lock
    pub fn acquire(self: *Mutex) Held {
        self.lock();
        return .{ .mutex = self };
    }

    pub const Held = struct {
        mutex: *Mutex,

        pub fn release(self: Held) void {
            self.mutex.unlock();
        }
    };
};

// ============================================================================
// Semaphore - Counting Semaphore
// ============================================================================

pub const Semaphore = struct {
    handle: c.SemaphoreHandle_t,

    /// Initialize counting semaphore
    pub fn init(max_count: u32, initial_count: u32) Semaphore {
        const handle = c.xSemaphoreCreateCounting(max_count, initial_count);
        return .{ .handle = handle };
    }

    /// Initialize binary semaphore (max count = 1)
    pub fn initBinary() Semaphore {
        const handle = c.xSemaphoreCreateBinary();
        return .{ .handle = handle };
    }

    /// Release semaphore resources
    pub fn deinit(self: *Semaphore) void {
        if (self.handle != null) {
            c.vSemaphoreDelete(self.handle);
            self.handle = null;
        }
    }

    /// Wait (decrement) - blocks if count is 0
    pub fn wait(self: *Semaphore) void {
        _ = c.xSemaphoreTake(self.handle, c.portMAX_DELAY);
    }

    /// Wait with timeout
    /// Returns true if acquired, false if timeout
    pub fn waitTimeout(self: *Semaphore, timeout_ms: u32) bool {
        const ticks = timeout_ms / c.portTICK_PERIOD_MS;
        return c.xSemaphoreTake(self.handle, ticks) == c.pdTRUE;
    }

    /// Try wait (non-blocking)
    /// Returns true if acquired, false if would block
    pub fn tryWait(self: *Semaphore) bool {
        return c.xSemaphoreTake(self.handle, 0) == c.pdTRUE;
    }

    /// Signal (increment) - wakes one waiting thread
    pub fn signal(self: *Semaphore) void {
        _ = c.xSemaphoreGive(self.handle);
    }

    /// Signal from ISR context
    pub fn signalFromIsr(self: *Semaphore) bool {
        var higher_priority_woken: c.BaseType_t = c.pdFALSE;
        _ = c.xSemaphoreGiveFromISR(self.handle, &higher_priority_woken);
        return higher_priority_woken == c.pdTRUE;
    }

    /// Get current count
    pub fn getCount(self: *Semaphore) u32 {
        return @intCast(c.uxSemaphoreGetCount(self.handle));
    }
};

// ============================================================================
// Event - Event Flags (FreeRTOS Event Groups)
// ============================================================================

pub const Event = struct {
    handle: c.EventGroupHandle_t,

    /// Wait mode for multi-flag waits
    pub const WaitMode = enum {
        /// Wait for ANY of the specified flags
        any,
        /// Wait for ALL of the specified flags
        all,
    };

    /// Initialize event group
    pub fn init() Event {
        const handle = c.xEventGroupCreate();
        return .{ .handle = handle };
    }

    /// Release event resources
    pub fn deinit(self: *Event) void {
        if (self.handle != null) {
            c.vEventGroupDelete(self.handle);
            self.handle = null;
        }
    }

    /// Set event flags
    pub fn set(self: *Event, flags: u32) void {
        _ = c.xEventGroupSetBits(self.handle, @intCast(flags));
    }

    /// Set event flags from ISR
    pub fn setFromIsr(self: *Event, flags: u32) bool {
        var higher_priority_woken: c.BaseType_t = c.pdFALSE;
        _ = c.xEventGroupSetBitsFromISR(self.handle, @intCast(flags), &higher_priority_woken);
        return higher_priority_woken == c.pdTRUE;
    }

    /// Clear event flags
    pub fn clear(self: *Event, flags: u32) void {
        _ = c.xEventGroupClearBits(self.handle, @intCast(flags));
    }

    /// Wait for event flags
    /// Returns the flags that were set
    pub fn wait(self: *Event, flags: u32, mode: WaitMode, clear_on_exit: bool) u32 {
        const wait_all = mode == .all;
        const bits = c.xEventGroupWaitBits(
            self.handle,
            @intCast(flags),
            @intFromBool(clear_on_exit),
            @intFromBool(wait_all),
            c.portMAX_DELAY,
        );
        return @intCast(bits);
    }

    /// Wait for event flags with timeout
    /// Returns null on timeout, otherwise the flags that were set
    pub fn waitTimeout(self: *Event, flags: u32, mode: WaitMode, clear_on_exit: bool, timeout_ms: u32) ?u32 {
        const wait_all = mode == .all;
        const ticks = timeout_ms / c.portTICK_PERIOD_MS;
        const bits = c.xEventGroupWaitBits(
            self.handle,
            @intCast(flags),
            @intFromBool(clear_on_exit),
            @intFromBool(wait_all),
            ticks,
        );

        // Check if the required bits were set
        const result: u32 = @intCast(bits);
        if (mode == .all) {
            if ((result & flags) == flags) return result;
        } else {
            if ((result & flags) != 0) return result;
        }
        return null;
    }

    /// Get current flags (non-blocking, no clear)
    pub fn getFlags(self: *Event) u32 {
        return @intCast(c.xEventGroupGetBits(self.handle));
    }
};
