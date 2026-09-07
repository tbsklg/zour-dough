const rp2xxx = @import("microzig").hal;
const Level = @import("../../../domain/rotary_control.zig").Level;

var sw_gpio: rp2xxx.drivers.GPIO_Device = undefined;
var clk_gpio: rp2xxx.drivers.GPIO_Device = undefined;
var dt_gpio: rp2xxx.drivers.GPIO_Device = undefined;

pub fn init(sw_pin: anytype, clk_pin: anytype, dt_pin: anytype) void {
    sw_gpio = rp2xxx.drivers.GPIO_Device.init(sw_pin);
    clk_gpio = rp2xxx.drivers.GPIO_Device.init(clk_pin);
    dt_gpio = rp2xxx.drivers.GPIO_Device.init(dt_pin);
}

pub fn readSw() Level {
    return read(sw_gpio);
}

pub fn readClk() Level {
    return read(clk_gpio);
}

pub fn readDt() Level {
    return read(dt_gpio);
}

fn read(gpio: rp2xxx.drivers.GPIO_Device) Level {
    const level = gpio.read() catch return .high;
    return switch (level) {
        .low => .low,
        .high => .high,
    };
}
