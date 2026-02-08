/// cache_merge — Zig-native tool for merging zig compilation caches and invoking zig.
///
/// Usage: cache_merge <out_cache> [dep_cache...] -- <zig> <args...>
///
/// 1. Creates out_cache/{z,b,h,o}/ directories
/// 2. Copies all entries from each dep_cache's z/, b/, h/, o/ into out_cache
/// 3. Spawns zig with --cache-dir and --global-cache-dir pointing to out_cache
/// 4. Propagates zig's exit code
///
/// Subdirectories:
///   z/ — Zig compilation unit cache
///   b/ — builtin.zig etc.
///   h/ — C header dependency tracking (@cImport manifest)
///   o/ — C compilation products (.o files)
///
/// Cache entries are content-addressed (hex hash filenames), so merging
/// from multiple dep caches never conflicts.
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const process = std.process;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try process.argsAlloc(allocator);

    if (args.len < 3) {
        std.debug.print("Usage: cache_merge <out_cache> [dep_cache...] -- <zig> <args...>\n", .{});
        process.exit(1);
    }

    const out_cache = args[1];
    const cwd = fs.cwd();

    // Create output subdirectories (z=zig cache, b=builtin, h=cImport headers, o=C objects)
    inline for (.{ "z", "b", "h", "o" }) |subdir| {
        const path = try fs.path.join(allocator, &.{ out_cache, subdir });
        cwd.makePath(path) catch |err| {
            std.debug.print("cache_merge: failed to create {s}: {}\n", .{ path, err });
            process.exit(1);
        };
    }

    // Process dep caches until we hit "--"
    var sep_idx: usize = 2;
    while (sep_idx < args.len) : (sep_idx += 1) {
        if (mem.eql(u8, args[sep_idx], "--")) {
            sep_idx += 1;
            break;
        }
        // Copy entries from this dep cache's z/, b/, h/, o/ subdirs
        for ([_][]const u8{ "z", "b", "h", "o" }) |subdir| {
            copyDirEntries(allocator, cwd, args[sep_idx], out_cache, subdir) catch |err| {
                if (err == error.FileNotFound) continue;
                std.debug.print("cache_merge: copy {s}/{s} failed: {}\n", .{ args[sep_idx], subdir, err });
                process.exit(1);
            };
        }
    }

    // Validate: must have zig command after "--"
    if (sep_idx >= args.len) {
        std.debug.print("cache_merge: missing '--' separator or no zig command after it\n" ++
            "usage: cache_merge <out_cache> [dep_cache...] -- <zig> <args...>\n", .{});
        process.exit(1);
    }

    // Build zig command: remaining args + cache flags
    var zig_argv: std.ArrayListUnmanaged([]const u8) = .empty;

    while (sep_idx < args.len) : (sep_idx += 1) {
        try zig_argv.append(allocator, args[sep_idx]);
    }
    try zig_argv.append(allocator, "--cache-dir");
    try zig_argv.append(allocator, out_cache);
    try zig_argv.append(allocator, "--global-cache-dir");
    try zig_argv.append(allocator, out_cache);

    // Spawn zig and propagate exit code
    var child = process.Child.init(zig_argv.items, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stdin_behavior = .Inherit;

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| process.exit(code),
        else => process.exit(1),
    }
}

/// Copy all entries from src_base/subdir/ to dst_base/subdir/
fn copyDirEntries(
    allocator: mem.Allocator,
    cwd: fs.Dir,
    src_base: []const u8,
    dst_base: []const u8,
    subdir: []const u8,
) !void {
    const src_path = try fs.path.join(allocator, &.{ src_base, subdir });
    const dst_path = try fs.path.join(allocator, &.{ dst_base, subdir });

    var src_dir = try cwd.openDir(src_path, .{ .iterate = true });
    defer src_dir.close();
    var dst_dir = try cwd.openDir(dst_path, .{});
    defer dst_dir.close();

    try copyDirRecursive(allocator, src_dir, dst_dir);
}

/// Recursively copy a directory's contents.
fn copyDirRecursive(allocator: mem.Allocator, src_dir: fs.Dir, dst_dir: fs.Dir) !void {
    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                // Content-addressed: overwrite is safe (same hash = same content)
                try src_dir.copyFile(entry.name, dst_dir, entry.name, .{});
            },
            .directory => {
                dst_dir.makeDir(entry.name) catch |err| {
                    if (err != error.PathAlreadyExists) return err;
                };
                var src_sub = try src_dir.openDir(entry.name, .{ .iterate = true });
                defer src_sub.close();
                var dst_sub = try dst_dir.openDir(entry.name, .{});
                defer dst_sub.close();
                try copyDirRecursive(allocator, src_sub, dst_sub);
            },
            else => {},
        }
    }
}
