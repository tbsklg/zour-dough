const std = @import("std");
const rp2xxx = @import("microzig").hal;
const time = rp2xxx.time;
const usb_cdc = @import("../platform/rp2040/transport/usb_cdc.zig");
const board = @import("../platform/rp2040/board/pico_wh.zig");
const status_led = @import("../platform/rp2040/drivers/status_led.zig");
const timing = @import("../support/timing.zig");
const Ticker = timing.Ticker;
const heater = @import("../platform/rp2040/drivers/heater.zig");
const heater_control = @import("../domain/heater_control.zig");
const temp_sensor = @import("../platform/rp2040/drivers/temp_sensor.zig");
const ultrasonic = @import("../platform/rp2040/drivers/ultrasonic.zig");
const power_switch = @import("../platform/rp2040/drivers/power_switch.zig");
const PowerSwitch = @import("../domain/power_switch_control.zig").PowerSwitch;
const rotary = @import("../platform/rp2040/drivers/rotary.zig");
const rotary_control = @import("../domain/rotary_control.zig");
const Blink = @import("../domain/blink.zig");
const Readings = @import("../domain/readings.zig").Readings;
const MAX_TEMP_AGE_US = @import("../domain/readings.zig").MAX_TEMP_AGE_US;

const Self = @This();

const DISTANCE_INTERVAL_US: u64 = 250_000;
const TELEMETRY_INTERVAL_US: u64 = 1_000_000;

readings: *Readings,
temp_sampler: timing.Sampler = .{},
distance_ticker: Ticker = .{ .interval_us = DISTANCE_INTERVAL_US },
telemetry_ticker: Ticker = .{ .interval_us = TELEMETRY_INTERVAL_US },
heartbeat_ticker: Ticker,
polls_since_telemetry: u32 = 0,
led_state: Blink.LedState = .off,
heater_state: heater_control.HeaterState = .power_off,
power_switch_state: PowerSwitch = .{},
rotary_state: rotary_control.Rotary = .{ .last_clk = .high, .last_sw = .high },

pub fn init(pins: board.Pins, heartbeat_interval_us: u64, readings: *Readings) !Self {
    try temp_sensor.init(pins.temp);
    temp_sensor.configure() catch |err| {
        usb_cdc.write("ds18b20 init failed: {s}\r\n", .{@errorName(err)});
    };

    ultrasonic.init(pins.ultra_sound_trigger, pins.ultra_sound_echo);
    heater.init(pins.heater);
    power_switch.init(pins.power_switch);
    rotary.init(pins.rotary_sw, pins.rotary_clk, pins.rotary_dt);

    const self = Self{
        .readings = readings,
        .heartbeat_ticker = .{ .interval_us = heartbeat_interval_us },
    };
    heater.set(self.heater_state) catch |err| {
        usb_cdc.write("heater init failed: {s}\r\n", .{@errorName(err)});
    };

    return self;
}

pub fn poll(self: *Self) void {
    const now = time.get_time_since_boot().to_us();
    self.polls_since_telemetry += 1;

    power_switch.read(&self.power_switch_state);
    self.pollRotary();
    self.pollHeater(now);
    self.pollTemp(now);
    self.pollDistance(now);
    self.pollHeartbeat(now);
    self.pollTelemetry(now);
}

fn pollRotary(self: *Self) void {
    const delta = self.rotary_state.update(rotary.readClk(), rotary.readDt());
    if (delta != 0) {
        self.readings.recordTarget(rotary_control.clamp(self.readings.target_temp + delta));
    }

    if (self.rotary_state.updateButton(rotary.readSw())) {
        self.readings.recordTarget(rotary_control.DEFAULT_TEMP);
    }
}

fn pollHeater(self: *Self, now_us: u64) void {
    self.decideHeaterState(now_us);

    self.readings.recordHeat(switch (self.heater_state) {
        .heating => .heating,
        else => .idle,
    });

    heater.set(self.heater_state) catch |err| {
        usb_cdc.write("heater write failed: {s}\r\n", .{@errorName(err)});
    };
}

fn decideHeaterState(self: *Self, now_us: u64) void {
    self.heater_state = heater_control.decide(
        self.readings.freshTemp(now_us),
        self.readings.target_temp,
        self.power_switch_state.state,
        self.heater_state,
        now_us,
    );
}

fn pollTemp(self: *Self, now_us: u64) void {
    switch (self.temp_sampler.poll(now_us)) {
        .none => {},
        .start_conversion => temp_sensor.startConversion() catch |err| {
            usb_cdc.write("temp conversion failed: {s}\r\n", .{@errorName(err)});
        },
        .read_conversion => {
            const temp = temp_sensor.readTemperature() catch |err| {
                usb_cdc.write("temp read failed: {s}\r\n", .{@errorName(err)});
                return;
            };
            self.readings.recordTemp(temp, now_us);
        },
    }
}

fn pollDistance(self: *Self, now_us: u64) void {
    if (!self.distance_ticker.ready(now_us)) return;

    const distance_cm = ultrasonic.measure(usb_cdc.poll) catch |err| {
        usb_cdc.write("ultrasonic read failed: {s}\r\n", .{@errorName(err)});
        self.readings.recordDistanceTimeout();
        return;
    };
    self.readings.recordDistance(distance_cm);
}

fn pollHeartbeat(self: *Self, now_us: u64) void {
    const desired: Blink.LedState = if (self.heater_state == .heating)
        .on
    else if (self.heartbeat_ticker.ready(now_us))
        self.led_state.toggled()
    else
        self.led_state;

    if (desired == self.led_state) return;

    self.led_state = desired;
    status_led.set(desired);
}

fn pollTelemetry(self: *Self, now_us: u64) void {
    if (!self.telemetry_ticker.ready(now_us)) return;

    usb_cdc.write("polls/s: {} temp: {?} dist: {?} power: {s} heater: {s}\r\n", .{
        self.polls_since_telemetry,
        self.readings.current_temp,
        self.readings.distance_cm,
        @tagName(self.power_switch_state.state),
        @tagName(self.heater_state),
    });
    self.polls_since_telemetry = 0;
}

fn testIncubator(readings: *Readings) Self {
    var incubator = Self{
        .readings = readings,
        .heartbeat_ticker = .{ .interval_us = 1 },
    };
    incubator.power_switch_state.switchOn();
    return incubator;
}

test "incubator turns off the heater command after the power switch is switched off" {
    var readings: Readings = .{};
    readings.recordTemp(readings.target_temp - 1, 100);
    var incubator = testIncubator(&readings);

    incubator.decideHeaterState(100);
    try std.testing.expectEqual(
        heater_control.HeaterState{ .heating = .{ .since_us = 100 } },
        incubator.heater_state,
    );

    incubator.power_switch_state.switchOff();
    incubator.decideHeaterState(200);
    try std.testing.expectEqual(heater_control.HeaterState.power_off, incubator.heater_state);
}

test "incubator does not heat before the first temperature reading" {
    var readings: Readings = .{};
    var incubator = testIncubator(&readings);

    incubator.decideHeaterState(100);
    try std.testing.expectEqual(heater_control.HeaterState.idle, incubator.heater_state);
}

test "incubator stops heating once the temperature reading goes stale" {
    var readings: Readings = .{};
    readings.recordTemp(readings.target_temp - 1, 100);
    var incubator = testIncubator(&readings);

    incubator.decideHeaterState(100);
    try std.testing.expectEqual(
        heater_control.HeaterState{ .heating = .{ .since_us = 100 } },
        incubator.heater_state,
    );

    incubator.decideHeaterState(100 + MAX_TEMP_AGE_US + 1);
    try std.testing.expectEqual(heater_control.HeaterState.idle, incubator.heater_state);
}
