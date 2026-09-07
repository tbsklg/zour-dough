const std = @import("std");
const rp2xxx = @import("microzig").hal;
const time = rp2xxx.time;
const usb_cdc = @import("../platform/rp2040/transport/usb_cdc.zig");
const board = @import("../platform/rp2040/board/pico.zig");
const status_led = @import("../platform/rp2040/drivers/status_led.zig");
const timing = @import("../support/timing.zig");
const Ticker = timing.Ticker;
const heater = @import("../platform/rp2040/drivers/heater.zig");
const heater_control = @import("../domain/heater_control.zig");
const temp_sensor = @import("../platform/rp2040/drivers/temp_sensor.zig");
const ultrasonic = @import("../platform/rp2040/drivers/ultrasonic.zig");
const power_switch = @import("../platform/rp2040/drivers/power_switch.zig");
const power_switch_control = @import("../domain/power_switch_control.zig");
const PowerSwitch = power_switch_control.PowerSwitch;
const PowerState = power_switch_control.PowerState;
const rotary = @import("../platform/rp2040/drivers/rotary.zig");
const rotary_control = @import("../domain/rotary_control.zig");
const Blink = @import("../domain/blink.zig");
const Readings = @import("../domain/readings.zig").Readings;

const Self = @This();

const DISTANCE_INTERVAL_US: u64 = 250_000;
const TELEMETRY_INTERVAL_US: u64 = 1_000_000;
const HEARTBEAT_INTERVAL_US: u64 = 500_000;

pub const Snapshot = struct {
    temp: ?f32,
    distance: ?f32,
    target: f32,
    power: PowerState,
};

readings: *Readings,
temp_sampler: timing.Sampler = .{},
distance_ticker: Ticker = .{ .interval_us = DISTANCE_INTERVAL_US },
telemetry_ticker: Ticker = .{ .interval_us = TELEMETRY_INTERVAL_US },
heartbeat_ticker: Ticker = .{ .interval_us = HEARTBEAT_INTERVAL_US },
led_state: Blink.LedState = .off,
heater_state: heater_control.HeaterState = .power_off,
power_switch_state: PowerSwitch = .{},
button_state: rotary_control.Button = .{},

pub fn init(pins: board.Pins, readings: *Readings) !Self {
    try temp_sensor.init(pins.temp);
    temp_sensor.configure() catch |err| {
        usb_cdc.write("ds18b20 init failed: {s}\r\n", .{@errorName(err)});
    };

    ultrasonic.init(pins.ultra_sound_trigger, pins.ultra_sound_echo);
    heater.init(pins.heater);
    power_switch.init(pins.power_switch);
    rotary.init(pins.rotary_sw, pins.rotary_clk, pins.rotary_dt);

    const self = Self{ .readings = readings };
    heater.set(self.heater_state) catch |err| {
        usb_cdc.write("heater init failed: {s}\r\n", .{@errorName(err)});
    };

    return self;
}

pub fn poll(self: *Self) void {
    const now = time.get_time_since_boot().to_us();

    const snapshot = self.sense(now);
    const heat = self.control(snapshot, now);
    self.actuate(snapshot, heat, now);
}

fn sense(self: *Self, now_us: u64) Snapshot {
    self.sensePowerSwitch();
    self.senseRotary();
    self.senseTemp(now_us);
    self.senseDistance(now_us);

    return .{
        .temp = self.readings.freshTemp(now_us),
        .distance = self.readings.distance_cm,
        .target = self.readings.target_temp,
        .power = self.power_switch_state.state,
    };
}

fn sensePowerSwitch(self: *Self) void {
    power_switch.read(&self.power_switch_state);
}

fn senseRotary(self: *Self) void {
    const counts = rotary.takeCounts();
    if (counts != 0) {
        self.readings.recordTarget(rotary_control.adjust(self.readings.target_temp, counts));
    }

    if (self.button_state.update(rotary.readSw())) {
        self.readings.recordTarget(rotary_control.DEFAULT_TEMP);
    }
}

fn senseTemp(self: *Self, now_us: u64) void {
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

fn senseDistance(self: *Self, now_us: u64) void {
    if (!self.distance_ticker.ready(now_us)) return;

    const distance_cm = ultrasonic.measure(usb_cdc.poll) catch |err| {
        usb_cdc.write("ultrasonic read failed: {s}\r\n", .{@errorName(err)});
        self.readings.recordDistanceTimeout();
        return;
    };
    self.readings.recordDistance(distance_cm);
}

fn control(self: *Self, snapshot: Snapshot, now_us: u64) heater_control.HeaterState {
    self.heater_state = heater_control.decide(
        snapshot.temp,
        snapshot.target,
        snapshot.power,
        self.heater_state,
        now_us,
    );
    return self.heater_state;
}

fn actuate(self: *Self, snapshot: Snapshot, heat: heater_control.HeaterState, now_us: u64) void {
    self.actuateHeater(heat);
    self.actuateLed(heat, now_us);
    self.report(snapshot, heat, now_us);
}

fn actuateHeater(self: *Self, heat: heater_control.HeaterState) void {
    self.readings.recordHeat(switch (heat) {
        .heating => .heating,
        else => .idle,
    });

    heater.set(heat) catch |err| {
        usb_cdc.write("heater write failed: {s}\r\n", .{@errorName(err)});
    };
}

fn actuateLed(self: *Self, heat: heater_control.HeaterState, now_us: u64) void {
    const desired: Blink.LedState = if (heat == .heating)
        .on
    else if (self.heartbeat_ticker.ready(now_us))
        self.led_state.toggled()
    else
        self.led_state;

    if (desired == self.led_state) return;

    self.led_state = desired;
    status_led.set(desired);
}

fn report(self: *Self, snapshot: Snapshot, heat: heater_control.HeaterState, now_us: u64) void {
    if (!self.telemetry_ticker.ready(now_us)) return;

    usb_cdc.write("temp: {?} dist: {?} target: {} power: {s} heater: {s}\r\n", .{
        snapshot.temp,
        snapshot.distance,
        snapshot.target,
        @tagName(snapshot.power),
        @tagName(heat),
    });
}

fn heatingSnapshot(target: f32) Snapshot {
    return .{ .temp = target - 1, .distance = null, .target = target, .power = .on };
}

test "control latches the heater on while the temperature is below target" {
    var readings: Readings = .{};
    var incubator = Self{ .readings = &readings };

    const heat = incubator.control(heatingSnapshot(readings.target_temp), 100);
    try std.testing.expectEqual(heater_control.HeaterState{ .heating = .{ .since_us = 100 } }, heat);
    try std.testing.expectEqual(heat, incubator.heater_state);
}

test "control turns the heater off after the power switch is switched off" {
    var readings: Readings = .{};
    var incubator = Self{ .readings = &readings };

    _ = incubator.control(heatingSnapshot(readings.target_temp), 100);

    var off = heatingSnapshot(readings.target_temp);
    off.power = .off;

    const heat = incubator.control(off, 200);
    try std.testing.expectEqual(heater_control.HeaterState.power_off, heat);
}

test "control does not heat without a temperature reading" {
    var readings: Readings = .{};
    var incubator = Self{ .readings = &readings };

    var blind = heatingSnapshot(readings.target_temp);
    blind.temp = null;

    const heat = incubator.control(blind, 100);
    try std.testing.expectEqual(heater_control.HeaterState.idle, heat);
}
