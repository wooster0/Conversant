const std = @import("std");
const os = std.os;
const assert = std.debug.assert;

const stdin = std.io.getStdIn();

/// This represents a key that was pressed in addition to the `Input`.
const CTRLModifier = enum {
    none,
    ctrl,
};
/// This represents a key that was pressed in addition to the `Input`.
const ShiftCTRLModifier = enum {
    none,
    shift,
    ctrl,
};

pub const Input = union(enum) {
    bytes: []const u8,

    up,
    down,
    left: CTRLModifier,
    right: CTRLModifier,

    home: CTRLModifier,
    end: CTRLModifier,
    page_up, // TODO: implement the modifiers
    page_down, // TODO: implement the modifiers

    enter, // It seems this has no modifiers in many if not most terminals
    tab,

    backspace: CTRLModifier,
    delete: ShiftCTRLModifier,

    esc,
};

var file_descriptors = [_]os.pollfd{os.pollfd{
    .fd = stdin.handle,
    .events = os.POLL.IN, // Await input
    .revents = 0,
}};
pub fn read() !?Input {
    // `std.os.ppoll` will block until there's terminal input or a signal was received.
    // We specify no timeout and no signal mask.
    //
    // A signal mask specifies the signals to block during this `std.os.ppoll`.
    //
    // Having no signal mask means that we will get `std.os.E.INTR` ("interrupt") if any signals
    // are received.
    // This is important for `std.os.SIG.WINCH` because if we receive it, `terminal.size`
    // will be updated and we want to stop blocking any potential screen redraws using the updated
    // `terminal.size` after this.
    //
    // We could make it so that we block all signals except `std.os.SIG.WINCH` by setting the
    // signal mask using `sigfillset` and `sigdelset` but we don't have to.
    //
    // We don't get the same behavior with `std.os.poll`.
    //
    // For an alternative solution to this, see the comment in `terminal.setTermios`.
    _ = std.os.ppoll(&file_descriptors, null, null) catch |err| {
        if (err == std.os.PPollError.SignalInterrupt)
            // Stop blocking
            return null;
        return err;
    };

    // We are ready to read data
    var buffer: [6]u8 = undefined;
    var byte_count = try stdin.read(&buffer);
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
                            switch (buffer[3]) {
                                '~' => return .{ .delete = .none },
                                ';' => {
                                    switch (buffer[4]) {
                                        '5' => {
                                            // For XTerm
                                            assert(buffer[5] == '~');
                                            return .{ .delete = .ctrl };
                                        },
                                        '2' => {
                                            return .{ .delete = .shift };
                                        },
                                        else => unreachable,
                                    }
                                },
                                else => unreachable,
                            }
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
        0x08 => .{ .backspace = .ctrl }, // For XTerm
        else => .{ .bytes = buffer },
    };
}
