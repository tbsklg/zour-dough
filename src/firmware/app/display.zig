const board = @import("../platform/rp2040/board/pico_wh.zig");
const oled = @import("../platform/rp2040/drivers/oled.zig");
const display_content = @import("../domain/display_content.zig");

const Self = @This();

pub fn init(pins: board.Pins) !Self {
    try oled.init(pins.oled_sda, pins.oled_scl);
    oled.clear();
    oled.textRow(2, &display_content.SPLASH_TOP);
    oled.textRow(4, &display_content.SPLASH_VER);
    try oled.flush();
    return .{};
}

pub fn poll(self: *Self) void {
    _ = self;
}
