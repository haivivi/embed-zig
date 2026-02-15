//! Redux-style State Store
//!
//! Single-direction data flow for embedded UI:
//!   Event → dispatch() → reducer modifies State → dirty flag set
//!   render checks isDirty() → reads state/prev → draws framebuffer
//!   commitFrame() snapshots prev = state, clears dirty
//!
//! Thread safety: Store is designed for single-thread use.
//! External threads push events via a Channel, the UI thread
//! drains the channel and calls dispatch().

/// Create a typed Store for the given State and Event types.
///
/// `State` must support value copy (no pointers to self).
/// `Event` is typically a tagged union.
///
/// Example:
/// ```
/// const GameState = struct { score: u32 = 0 };
/// const GameEvent = union(enum) { score_up, reset };
///
/// fn reduce(s: *GameState, e: GameEvent) void {
///     switch (e) {
///         .score_up => s.score += 1,
///         .reset => s.* = .{},
///     }
/// }
///
/// var store = Store(GameState, GameEvent).init(.{}, reduce);
/// store.dispatch(.score_up);
/// ```
pub fn Store(comptime State: type, comptime Event: type) type {
    return struct {
        const Self = @This();

        state: State,
        prev: State,
        dirty: bool,
        reducer: *const fn (*State, Event) void,

        /// Create a store with initial state and reducer function.
        pub fn init(initial: State, reducer: *const fn (*State, Event) void) Self {
            return .{
                .state = initial,
                .prev = initial,
                .dirty = true, // first frame always needs render
                .reducer = reducer,
            };
        }

        /// Dispatch a single event — calls reducer, marks dirty.
        pub fn dispatch(self: *Self, event: Event) void {
            self.reducer(&self.state, event);
            self.dirty = true;
        }

        /// Dispatch multiple events in a batch — calls reducer for each,
        /// marks dirty once at the end.
        pub fn dispatchBatch(self: *Self, events: []const Event) void {
            for (events) |event| {
                self.reducer(&self.state, event);
            }
            if (events.len > 0) {
                self.dirty = true;
            }
        }

        /// Check if state changed since last commitFrame.
        pub fn isDirty(self: *const Self) bool {
            return self.dirty;
        }

        /// Get current state (read-only, for rendering).
        pub fn getState(self: *const Self) *const State {
            return &self.state;
        }

        /// Get previous frame state (read-only, for diff rendering).
        pub fn getPrev(self: *const Self) *const State {
            return &self.prev;
        }

        /// End frame — snapshot current state as prev, clear dirty.
        /// Call this after rendering is complete.
        pub fn commitFrame(self: *Self) void {
            self.prev = self.state;
            self.dirty = false;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

const TestState = struct {
    count: u32 = 0,
    name: [8]u8 = .{0} ** 8,
};

const TestEvent = union(enum) {
    increment,
    decrement,
    reset,
    add: u32,
};

fn testReducer(state: *TestState, event: TestEvent) void {
    switch (event) {
        .increment => state.count += 1,
        .decrement => {
            if (state.count > 0) state.count -= 1;
        },
        .reset => state.* = .{},
        .add => |n| state.count += n,
    }
}

test "init sets dirty for first frame" {
    const store = Store(TestState, TestEvent).init(.{}, testReducer);
    try testing.expect(store.isDirty());
    try testing.expectEqual(@as(u32, 0), store.getState().count);
}

test "dispatch modifies state and marks dirty" {
    var store = Store(TestState, TestEvent).init(.{}, testReducer);
    store.commitFrame(); // clear initial dirty
    try testing.expect(!store.isDirty());

    store.dispatch(.increment);
    try testing.expect(store.isDirty());
    try testing.expectEqual(@as(u32, 1), store.getState().count);
}

test "commitFrame snapshots prev and clears dirty" {
    var store = Store(TestState, TestEvent).init(.{}, testReducer);
    store.dispatch(.increment);
    store.dispatch(.increment);
    try testing.expectEqual(@as(u32, 2), store.getState().count);
    try testing.expectEqual(@as(u32, 0), store.getPrev().count);

    store.commitFrame();
    try testing.expect(!store.isDirty());
    try testing.expectEqual(@as(u32, 2), store.getPrev().count);
    try testing.expectEqual(@as(u32, 2), store.getState().count);
}

test "dispatchBatch applies multiple events" {
    var store = Store(TestState, TestEvent).init(.{}, testReducer);
    store.commitFrame();

    const events = [_]TestEvent{ .increment, .increment, .{ .add = 10 }, .decrement };
    store.dispatchBatch(&events);

    try testing.expect(store.isDirty());
    try testing.expectEqual(@as(u32, 12), store.getState().count);
}

test "dispatchBatch with empty slice does not mark dirty" {
    var store = Store(TestState, TestEvent).init(.{}, testReducer);
    store.commitFrame();

    store.dispatchBatch(&[_]TestEvent{});
    try testing.expect(!store.isDirty());
}

test "prev tracks across multiple frames" {
    var store = Store(TestState, TestEvent).init(.{}, testReducer);

    // Frame 1: count goes 0 → 3
    store.dispatch(.{ .add = 3 });
    store.commitFrame();
    try testing.expectEqual(@as(u32, 3), store.getPrev().count);

    // Frame 2: count goes 3 → 5
    store.dispatch(.{ .add = 2 });
    try testing.expectEqual(@as(u32, 3), store.getPrev().count);
    try testing.expectEqual(@as(u32, 5), store.getState().count);
    store.commitFrame();
    try testing.expectEqual(@as(u32, 5), store.getPrev().count);
}

test "reset via dispatch" {
    var store = Store(TestState, TestEvent).init(.{}, testReducer);
    store.dispatch(.{ .add = 100 });
    store.dispatch(.reset);
    try testing.expectEqual(@as(u32, 0), store.getState().count);
}
