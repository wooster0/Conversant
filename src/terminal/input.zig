const std = @import("std");
const io = std.io;
const assert = std.debug.assert;

const stdin = io.getStdIn();

pub const Input = union(enum) {
    bytes: []const u8,

    up,
    down,
    left: Modifier,
    right: Modifier,

    home: Modifier,
    end: Modifier,
    page_up, // TODO: implement the modifiers
    page_down, // TODO: implement the modifiers

    enter, // It seems this has no modifiers in many if not most terminals
    tab,

    backspace: Modifier,
    delete: Modifier,

    esc,
};

/// A key that was pressed in addition to the `Input`.
const Modifier = enum {
    none,
    ctrl,
};

const stdin_reader = stdin.reader();
pub fn read() !Input {
    var buffer: [6]u8 = undefined;
    var byte_count = try stdin_reader.read(&buffer);
    @import("../main.zig").debug("{s}", .{buffer[0..byte_count]});
    return parseInput(buffer[0..byte_count]);
}

fn parseInput(buffer: []const u8) Input {
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
        else => .{ .bytes = buffer },
    };
}
