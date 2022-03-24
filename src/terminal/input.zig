const std = @import("std");
const io = std.io;
const assert = std.debug.assert;

const stdin = io.getStdIn();

/// The key that was pressed.
pub const Key = union(enum) {
    char: u8,

    up,
    down,
    left: Modifier,
    right: Modifier,

    home: Modifier,
    end: Modifier,
    page_up, // TODO: implement the modifiers
    page_down, // TODO: implement the modifiers

    enter,
    tab,

    backspace: Modifier,
    delete: Modifier,

    esc,
};

/// The key that was pressed in addition to the other one.
const Modifier = enum {
    none,
    ctrl,
};

const stdin_reader = stdin.reader();
pub fn read() !Key {
    var buffer = [1]u8{undefined} ** 6;
    var bytes_read = try stdin_reader.read(&buffer);
    @import("../main.zig").debug("{s}", .{buffer[0..bytes_read]});
    return parseInput(buffer[0..bytes_read]);
}

fn parseInput(buffer: []const u8) Key {
    return switch (buffer[0]) {
        '\x1b' => {
            if (buffer.len == 1)
                return .esc;
            switch (buffer[1]) {
                '[' => {
                    switch (buffer[2]) {
                        'A' => return .up,
                        'B' => return .down,
                        'C' => return .{ .right = .none },
                        'D' => return .{ .left = .none },
                        'F' => return .{ .end = .none },
                        'H' => return .{ .home = .none },
                        '1' => {
                            assert(buffer[3] == ';');
                            switch (buffer[4]) {
                                '5' => {
                                    switch (buffer[5]) {
                                        'C' => {
                                            return .{ .right = .ctrl };
                                        },
                                        'D' => {
                                            return .{ .left = .ctrl };
                                        },
                                        'F' => {
                                            return .{ .end = .ctrl };
                                        },
                                        'H' => {
                                            return .{ .home = .ctrl };
                                        },
                                        else => unreachable,
                                    }
                                },
                                else => unreachable,
                            }
                        },
                        '3' => {
                            assert(buffer[3] == '~');
                            return .{ .delete = .none };
                        },
                        '5' => {
                            assert(buffer[3] == '~');
                            return .page_up;
                        },
                        '6' => {
                            assert(buffer[3] == '~');
                            return .page_down;
                        },
                        else => unreachable,
                    }
                },
                'd' => return .{ .delete = .ctrl },
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
