const std = @import("std");

pub const MIN_TEMP: f32 = 20.0;
pub const MAX_TEMP: f32 = 30.0;
pub const DEFAULT_TEMP: f32 = 22.0;

pub const STEP: f32 = 0.5;

pub fn clamp(temp: f32) f32 {
    return @max(MIN_TEMP, @min(MAX_TEMP, temp));
}

pub const Level = enum { low, high };

pub const Rotary = struct {
    last_clk: Level,
    last_sw: Level,

    pub fn update(self: *Rotary, clk: Level, dt: Level) f32 {
        defer self.last_clk = clk;
        if (self.last_clk == .high and clk == .low) {
            return if (dt != clk) STEP else -STEP;
        }
        return 0;
    }

    pub fn updateButton(self: *Rotary, sw: Level) bool {
        defer self.last_sw = sw;
        return self.last_sw == .high and sw == .low;
    }
};

test "clamp raises a temperature below the minimum to the minimum" {
    try std.testing.expectEqual(@as(f32, 20.0), clamp(3.0));
}

test "clamp lowers a temperature above the maximum to the maximum" {
    try std.testing.expectEqual(@as(f32, 30.0), clamp(40.0));
}

test "clamp keeps a temperature inside the range unchanged" {
    try std.testing.expectEqual(@as(f32, 25.0), clamp(25.0));
}

test "update returns +STEP on a CLK falling edge when dt differs from clk" {
    var rotary = Rotary{ .last_clk = .high, .last_sw = .high };
    try std.testing.expectEqual(@as(f32, 0.5), rotary.update(.low, .high));
}

test "update returns -STEP on a CLK falling edge when dt equals clk" {
    var rotary = Rotary{ .last_clk = .high, .last_sw = .high };
    try std.testing.expectEqual(@as(f32, -0.5), rotary.update(.low, .low));
}

test "update returns 0 without a CLK falling edge" {
    var rotary = Rotary{ .last_clk = .high, .last_sw = .high };
    try std.testing.expectEqual(@as(f32, 0), rotary.update(.high, .high));
    try std.testing.expectEqual(@as(f32, 0), rotary.update(.high, .low));
}

test "update counts one detent only once while CLK dwells low" {
    var rotary = Rotary{ .last_clk = .high, .last_sw = .high };
    try std.testing.expectEqual(@as(f32, 0.5), rotary.update(.low, .high));
    try std.testing.expectEqual(@as(f32, 0), rotary.update(.low, .high));
    try std.testing.expectEqual(@as(f32, 0), rotary.update(.low, .high));
}

test "updateButton returns true on a SW falling edge" {
    var rotary = Rotary{ .last_clk = .high, .last_sw = .high };
    try std.testing.expectEqual(true, rotary.updateButton(.low));
}

test "updateButton returns false while SW is held or released" {
    var rotary = Rotary{ .last_clk = .high, .last_sw = .high };
    try std.testing.expectEqual(true, rotary.updateButton(.low));
    try std.testing.expectEqual(false, rotary.updateButton(.low));
    try std.testing.expectEqual(false, rotary.updateButton(.high));
    try std.testing.expectEqual(false, rotary.updateButton(.high));
}
