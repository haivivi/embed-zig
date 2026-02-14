//! e2e: trait/kvs — Verify key-value store (NVS on ESP)
//!
//! Tests:
//!   1. NVS init
//!   2. setU32 + getU32 round-trip
//!   3. Key not found returns error

const platform = @import("platform.zig");
const log = platform.log;
const Nvs = platform.Nvs;

fn runTests() !void {
    log.info("[e2e] START: trait/kvs", .{});

    // Test 1: NVS init
    Nvs.flashInit() catch |err| {
        log.err("[e2e] FAIL: trait/kvs/init — {}", .{err});
        return error.NvsInitFailed;
    };
    log.info("[e2e] PASS: trait/kvs/init", .{});

    // Open namespace
    var nvs = Nvs.open("e2e_test") catch |err| {
        log.err("[e2e] FAIL: trait/kvs/open — {}", .{err});
        return error.NvsOpenFailed;
    };
    defer nvs.deinit();
    log.info("[e2e] PASS: trait/kvs/open", .{});

    // Test 2: setU32 + getU32
    {
        nvs.setU32("test_val", 12345) catch |err| {
            log.err("[e2e] FAIL: trait/kvs/setU32 — {}", .{err});
            return error.NvsSetFailed;
        };
        nvs.commit() catch |err| {
            log.err("[e2e] FAIL: trait/kvs/commit — {}", .{err});
            return error.NvsCommitFailed;
        };

        const val = nvs.getU32("test_val") catch |err| {
            log.err("[e2e] FAIL: trait/kvs/getU32 — {}", .{err});
            return error.NvsGetFailed;
        };

        if (val != 12345) {
            log.err("[e2e] FAIL: trait/kvs/roundtrip — expected 12345, got {}", .{val});
            return error.NvsValueMismatch;
        }
        log.info("[e2e] PASS: trait/kvs/roundtrip — setU32/getU32 = {}", .{val});
    }

    // Test 3: Key not found
    {
        _ = nvs.getU32("nonexistent_key_xyz") catch |err| {
            if (err == Nvs.NvsError.NotFound) {
                log.info("[e2e] PASS: trait/kvs/not_found — correct error", .{});
                return; // this is the expected path
            }
            log.err("[e2e] FAIL: trait/kvs/not_found — wrong error: {}", .{err});
            return error.NvsWrongError;
        };
        log.err("[e2e] FAIL: trait/kvs/not_found — no error returned", .{});
        return error.NvsExpectedError;
    }
}

pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: trait/kvs — {}", .{err});
        return;
    };
    log.info("[e2e] PASS: trait/kvs", .{});
}

test "e2e: trait/kvs" {
    // KVS test is ESP-only (NVS flash)
    return error.SkipZigTest;
}
