//! Shared helpers for selector std e2e tests/benchmarks.

const platform = @import("std_impl");
const Selector = platform.selector.Selector;

/// Build Selector(max_sources, max_events) with explicit queue_set_slots sum.
pub fn makeSelector(comptime max_sources: usize, comptime Ch: type) type {
    comptime var max_events: usize = 0;
    inline for (0..max_sources) |_| {
        max_events += Ch.queue_set_slots;
    }
    return Selector(max_sources, max_events);
}
