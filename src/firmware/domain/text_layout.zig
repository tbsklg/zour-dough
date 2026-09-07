const std = @import("std");

pub const ROW_LEN = 16;

pub fn line(buf: []u8, first: []const u8, second: []const u8) ?[]const u8 {
    if (buf.len < ROW_LEN) return null;
    if (first.len + second.len > ROW_LEN) return null;

    const row = buf[0..ROW_LEN];

    @memset(row, ' ');
    @memcpy(row[0..first.len], first);
    @memcpy(row[ROW_LEN - second.len ..], second);

    return row;
}

test "line left-aligns first and right-aligns second" {
    var buf: [ROW_LEN]u8 = undefined;
    const row = line(&buf, "Zour-Dough", "v2026").?;
    try std.testing.expectEqualStrings("Zour-Dough v2026", row);
}
