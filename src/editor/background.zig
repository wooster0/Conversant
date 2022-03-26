const std = @import("std");
const assert = std.debug.assert;

const terminal = @import("../terminal.zig");

const tm = extern struct {
    sec: i32,
    min: i32,
    hour: i32,
    mday: i32,
    mon: i32,
    year: i32,
    wday: i32,
    yday: i32,
    isdst: i32,
};
extern fn localtime(timer: *const std.os.time_t) *tm;

const Time = struct {
    hour: u5,
    minute: u6,
};

/// Returns the current local time.
///
/// This is not thread-safe.
fn getCurrentLocalTime() Time {
    // And here we come upon a sad state of affairs.
    //
    // It's easy to get the current UTC time with only the `std`
    // but in our case we need the local time, taking the timezone into account.
    //
    // Unfortunately, there is no way to get the timezone
    // with only the `std`. There is `std.os.gettimeofday` that can supposedly
    // give you the timezone but its `tz` parameter is actually useless
    // and stays zero after the call.
    //
    // Then there is the option to parse a file like `/etc/localtime`
    // to get the timezone. There is https://github.com/leroycep/zig-tzif
    // for that but as of writing it's outdated and pretty big.
    // It doesn't seem reasonable to add it as a dependency because as time goes on,
    // it will possibly further outdate and will have to be maintained.
    //
    // From my tests I concluded that linking with C and using `localtime`
    // results in a much smaller binary size than using `tzif`.
    //
    // Maybe this can be changed someday.

    const timestamp = std.time.timestamp();
    const local_time = localtime(&timestamp);

    return Time{ .hour = @intCast(u5, local_time.hour), .minute = @intCast(u6, local_time.min) };
}

/// Normalizes the given value in the given range, such that:
/// * For 0, this returns -1.0.
/// * For `range / 2`, this returns 0.0.
/// * For `range`, this returns +1.0.
/// The return value will be in range -1.0 to +1.0.
fn normalizeInRange(value: f16, range: f16) f16 {
    assert(value >= 0 and value <= range);

    return (value / range) * 2 - 1;
}

/// Normalizes the given time such that
/// the start of the day is 0.0, the middle of the day 1.0, and the end of the day 0.0.
fn normalizeTime(time: Time) f16 {
    const current_minute_of_day = @as(u32, time.hour) * 60 + @as(u32, time.minute);
    return 1 - @fabs(normalizeInRange(@intToFloat(f16, current_minute_of_day), @intToFloat(f16, 24 * 60)));
}

fn brightnessToHexColor(hex_color: *[6]u8, brightness: f16) void {
    const byte_count = std.fmt.formatIntBuf(
        hex_color,
        @floatToInt(u8, brightness * 0xff),
        16,
        .lower,
        .{ .width = 2, .fill = '0' },
    );
    assert(byte_count == 2);

    // Fill out the rest with the first two bytes
    hex_color[2] = hex_color[0];
    hex_color[3] = hex_color[1];
    hex_color[4] = hex_color[0];
    hex_color[5] = hex_color[1];
}

/// Sets a black-white background with a brightness according to daytime.
// TODO: this is currently called only once and the background is never actually updated.
//       At some point change the event loop to a polling one and then re-set the background
//       every once in a while.
pub fn setTimelyBackground() !void {
    const current_local_time = getCurrentLocalTime();
    const normalized_time = normalizeTime(current_local_time);

    var hex_color: [6]u8 = undefined;

    const background_brightness = normalized_time / 2.5; // Dampen it a bit
    brightnessToHexColor(&hex_color, background_brightness);
    try terminal.control.setScreenBackgroundColor(&hex_color);

    const foreground_brightness = 1 - background_brightness / 5; // Dampen this a bit more
    brightnessToHexColor(&hex_color, foreground_brightness);
    try terminal.control.setScreenForegroundColor(&hex_color);
}

pub fn resetTimelyBackground() !void {
    try terminal.control.resetScreenBackgroundColor();
    try terminal.control.resetScreenForegroundColor();
}

const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "normalizeTime" {
    try expectEqual(@as(f16, 0.0), normalizeTime(.{ .hour = 0, .minute = 0 }));
    try expectEqual(@as(f16, 0.5), normalizeTime(.{ .hour = 6, .minute = 0 }));
    try expectEqual(@as(f16, 1.0), normalizeTime(.{ .hour = 12, .minute = 0 }));
    try expectEqual(@as(f16, 0.5), normalizeTime(.{ .hour = 18, .minute = 0 }));
    try expectApproxEqAbs(@as(f16, 0.0), normalizeTime(.{ .hour = 23, .minute = 59 }), 1);
}
