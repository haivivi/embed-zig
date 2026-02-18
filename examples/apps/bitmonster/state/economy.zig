//! Economy — currency formatting, pricing

pub fn formatCurrency(buf: []u8, bytes: u64) []const u8 {
    if (bytes >= 1024 * 1024 * 1024 * 1024) return fmtUnit(buf, bytes, 1024 * 1024 * 1024 * 1024, "TB");
    if (bytes >= 1024 * 1024 * 1024) return fmtUnit(buf, bytes, 1024 * 1024 * 1024, "GB");
    if (bytes >= 1024 * 1024) return fmtUnit(buf, bytes, 1024 * 1024, "MB");
    if (bytes >= 1024) return fmtUnit(buf, bytes, 1024, "KB");
    return fmtUnit(buf, bytes, 1, "B");
}

fn fmtUnit(buf: []u8, value: u64, unit: u64, suffix: []const u8) []const u8 {
    const whole = value / unit;
    var pos: usize = 0;

    // Write whole part
    if (whole == 0) {
        if (pos < buf.len) { buf[pos] = '0'; pos += 1; }
    } else {
        var tmp: [20]u8 = undefined;
        var n = whole;
        var len: usize = 0;
        while (n > 0) : (n /= 10) {
            tmp[len] = @intCast('0' + n % 10);
            len += 1;
        }
        var j = len;
        while (j > 0) {
            j -= 1;
            if (pos < buf.len) { buf[pos] = tmp[j]; pos += 1; }
        }
    }

    // Decimal for KB+ (1 digit)
    if (unit > 1) {
        const frac = (value % unit) * 10 / unit;
        if (frac > 0) {
            if (pos < buf.len) { buf[pos] = '.'; pos += 1; }
            if (pos < buf.len) { buf[pos] = @intCast('0' + frac); pos += 1; }
        }
    }

    // Space + suffix
    if (pos < buf.len) { buf[pos] = ' '; pos += 1; }
    for (suffix) |c| {
        if (pos < buf.len) { buf[pos] = c; pos += 1; }
    }
    return buf[0..pos];
}

pub const Item = struct {
    id: u8,
    name: []const u8,
    price: u64,
    restore_attr: Attr,
    restore_amount: u8,
};

pub const Attr = enum { health, spirit, luck };

pub const items = [_]Item{
    .{ .id = 0, .name = "Bread", .price = 20, .restore_attr = .health, .restore_amount = 10 },
    .{ .id = 1, .name = "Steak", .price = 60, .restore_attr = .health, .restore_amount = 25 },
    .{ .id = 2, .name = "Fruit Platter", .price = 35, .restore_attr = .health, .restore_amount = 15 },
    .{ .id = 3, .name = "Cake", .price = 80, .restore_attr = .health, .restore_amount = 30 },
    .{ .id = 4, .name = "Energy Bar", .price = 45, .restore_attr = .health, .restore_amount = 20 },
    .{ .id = 5, .name = "Feast", .price = 500, .restore_attr = .health, .restore_amount = 100 },
    .{ .id = 6, .name = "Juice", .price = 20, .restore_attr = .spirit, .restore_amount = 10 },
    .{ .id = 7, .name = "Coffee", .price = 40, .restore_attr = .spirit, .restore_amount = 20 },
    .{ .id = 8, .name = "Energy Drink", .price = 100, .restore_attr = .spirit, .restore_amount = 40 },
    .{ .id = 9, .name = "Elixir", .price = 500, .restore_attr = .spirit, .restore_amount = 100 },
    .{ .id = 10, .name = "Clover", .price = 30, .restore_attr = .luck, .restore_amount = 10 },
    .{ .id = 11, .name = "Lucky Shard", .price = 80, .restore_attr = .luck, .restore_amount = 25 },
    .{ .id = 12, .name = "Lucky Cat", .price = 50, .restore_attr = .luck, .restore_amount = 15 },
    .{ .id = 13, .name = "Rainbow Crystal", .price = 250, .restore_attr = .luck, .restore_amount = 50 },
};

pub fn sellPrice(buy_price: u64) u64 {
    return buy_price / 2;
}
