const std = @import("std");
const io = std.io;

const stdin = io.getStdIn();

/// The key that was pressed.
const Key = union(enum) {
    char: u8,

    up,
    down,
    left,
    right,

    enter,
    tab,
    backspace: Modifier,
    esc,
};

/// The key that was pressed in addition to the other one.
const Modifier = enum {
    ctrl,
    none,
};

const stdin_reader = stdin.reader();
pub fn readInput() !Key {
    var buffer = [1]u8{undefined} ** 4;
    var bytes_read = try stdin_reader.read(&buffer);
    // debug("{any}", .{buffer[0..bytes_read]});
    return parseInput(buffer[0..bytes_read]);
}

fn parseInput(buffer: []const u8) Key {
    if (buffer.len == 0)
        unreachable;
    return switch (buffer[0]) {
        '\x1b' => {
            if (buffer.len == 1)
                return .esc;
            switch (buffer[1]) {
                '[' => {
                    if (buffer.len < 3)
                        unreachable;
                    switch (buffer[2]) {
                        'A' => return .up,
                        'B' => return .down,
                        'C' => return .right,
                        'D' => return .left,
                        else => unreachable,
                    }
                },
                else => unreachable,
            }
        },
        '\r' => .enter,
        '\t' => .tab,
        0x7F => .{ .backspace = .none },
        0x17 => .{ .backspace = .ctrl },
        else => .{ .char = buffer[0] },
    };
}
