const usb_cdc = @import("./platform/rp2040/transport/usb_cdc.zig");
const status_led = @import("./platform/rp2040/drivers/status_led.zig");
const board = @import("./platform/rp2040/board/pico_wh.zig");
const Incubator = @import("./app/incubator.zig");
const Display = @import("./app/display.zig");
const Readings = @import("./domain/readings.zig").Readings;

const HEARTBEAT_INTERVAL_US: u64 = 500_000;

pub fn main() !void {
    const pins = board.apply();

    try init_peripherals();

    var readings: Readings = .{};
    var incubator = try Incubator.init(pins, HEARTBEAT_INTERVAL_US, &readings);
    var display = try Display.init(pins, &readings);

    while (true) {
        usb_cdc.poll();
        incubator.poll();
        display.poll();
    }
}

pub fn init_peripherals() !void {
    try status_led.init();
    status_led.bootBlink();
    usb_cdc.init();
}
