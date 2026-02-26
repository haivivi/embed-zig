//! e2e: selector — verify cross-platform Selector semantics
//!
//! Focus cases:
//!   1) pre-existing data: send before addRecv, then wait should return immediately
//!   2) closed channel: close before wait should wake selector immediately

const std = @import("std");
const platform = @import("platform.zig");

const log = platform.log;
const time = platform.time;
const Channel = platform.channel.Channel;
const Selector = platform.selector.Selector;

fn testPreExistingData(iter: usize) !void {
    const Ch = Channel(u32, 4);
    const channel_slots: usize = if (@hasDecl(Ch, "queue_set_slots")) Ch.queue_set_slots else 1;
    const Sel = Selector(2, channel_slots);

    var ch = try Ch.init();
    defer ch.deinit();

    const expected: u32 = @intCast(1000 + iter);
    try ch.send(expected);

    var sel = try Sel.init();
    defer sel.deinit();

    const recv_idx = try sel.addRecv(&ch);
    if (recv_idx != 0) return error.PreExistingWrongSourceIndex;

    const start = time.nowMs();
    const ready_idx = try sel.wait(200);
    const elapsed = time.nowMs() - start;

    if (ready_idx != 0) return error.PreExistingWrongReadyIndex;
    if (elapsed > 50) return error.PreExistingDataNotImmediate;

    const got = ch.recv() orelse return error.PreExistingDataMissing;
    if (got != expected) return error.PreExistingDataMismatch;

    log.info("[e2e] PASS: selector/pre-existing-data iter={} elapsed={}ms", .{ iter, elapsed });
}

fn testClosedChannelWakeup() !void {
    const Ch = Channel(u32, 4);
    const channel_slots: usize = if (@hasDecl(Ch, "queue_set_slots")) Ch.queue_set_slots else 1;
    const Sel = Selector(2, channel_slots);

    var ch = try Ch.init();
    defer ch.deinit();

    var sel = try Sel.init();
    defer sel.deinit();

    const recv_idx = try sel.addRecv(&ch);
    if (recv_idx != 0) return error.CloseWrongSourceIndex;

    ch.close();

    const start = time.nowMs();
    const ready_idx = try sel.wait(200);
    const elapsed = time.nowMs() - start;

    if (ready_idx != 0) return error.CloseWrongReadyIndex;
    if (elapsed > 50) return error.CloseWakeupTooSlow;
    if (ch.recv() != null) return error.ClosedChannelShouldDrainToNull;

    log.info("[e2e] PASS: selector/closed-channel elapsed={}ms", .{elapsed});
}

fn expectClosedOnTrySend(ch: anytype, value: u32) !void {
    if (ch.trySend(value)) |_| {
        return error.SendAfterCloseUnexpectedSuccess;
    } else |err| switch (err) {
        error.Closed => {},
        else => return error.SendAfterCloseWrongError,
    }
}

fn testSendAfterCloseRejected() !void {
    const Ch = Channel(u32, 4);

    var ch = try Ch.init();
    defer ch.deinit();

    ch.close();

    try expectClosedOnTrySend(&ch, 1);
    if (ch.recv() != null) return error.ClosedChannelShouldBeEmpty;

    log.info("[e2e] PASS: channel/send-after-close-rejected", .{});
}

fn testCloseDrainsBufferedDataThenRejectsSend() !void {
    const Ch = Channel(u32, 4);

    var ch = try Ch.init();
    defer ch.deinit();

    const expected: u32 = 2026;
    try ch.send(expected);
    ch.close();

    const first = ch.recv() orelse return error.ClosedDrainMissingBufferedItem;
    if (first != expected) return error.ClosedDrainWrongBufferedItem;
    if (ch.recv() != null) return error.ClosedDrainShouldEndWithNull;

    try expectClosedOnTrySend(&ch, 2);

    log.info("[e2e] PASS: channel/close-drain-then-reject-send", .{});
}

fn testCloseSendContractStress() !void {
    const Ch = Channel(u32, 4);

    for (0..100) |iter| {
        var ch = try Ch.init();
        defer ch.deinit();

        const value: u32 = @intCast(iter + 5000);
        try ch.send(value);
        ch.close();

        const first = ch.recv() orelse return error.CloseStressMissingBufferedItem;
        if (first != value) return error.CloseStressWrongBufferedItem;
        if (ch.recv() != null) return error.CloseStressShouldDrainToNull;

        try expectClosedOnTrySend(&ch, value + 1);
    }

    log.info("[e2e] PASS: channel/close-send-contract-stress rounds=100", .{});
}

fn runTests() !void {
    log.info("[e2e] START: selector", .{});

    for (0..3) |iter| {
        try testPreExistingData(iter);
    }
    try testClosedChannelWakeup();
    try testSendAfterCloseRejected();
    try testCloseDrainsBufferedDataThenRejectsSend();
    try testCloseSendContractStress();

    log.info("[e2e] PASS: selector", .{});
}

pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: selector — {}", .{err});
    };
}

test "e2e: selector" {
    try runTests();
}
