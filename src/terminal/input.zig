const std = @import("std");
const os = std.os;
const assert = std.debug.assert;

const stdin = std.io.getStdIn();

/// A key that was pressed in addition to the `Input`.
const AltModifier = enum {
    none,
    alt,
};
/// A key that was pressed in addition to the `Input`.
const CTRLModifier = enum {
    none,
    ctrl,
};
/// A key that was pressed in addition to the `Input`.
const ShiftCTRLModifier = enum {
    none,
    shift,
    ctrl,
};

pub const Input = union(enum) {
    bytes: []const u8,

    up: AltModifier,
    down: AltModifier,
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

    ctrl_s,

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
    // will be updated and we want to stop blocking any potential redraws using the updated
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
    return parseInput(buffer[0..byte_count]);
}

fn parseInput(buffer: []const u8) Input {
    return switch (buffer[0]) {
        '\x1b' => {
            if (buffer.len == 1)
                return .esc;
            return switch (buffer[1]) {
                '[' => {
                    return switch (buffer[2]) {
                        'A' => .{ .up = .none },
                        'B' => .{ .down = .none },
                        'C' => .{ .right = .none },
                        'D' => .{ .left = .none },
                        'F' => .{ .end = .none },
                        'H' => .{ .home = .none },
                        '1' => {
                            assert(buffer[3] == ';');
                            switch (buffer[4]) {
                                '3' => {
                                    return switch (buffer[5]) {
                                        'A' => .{ .up = .alt },
                                        'B' => .{ .down = .alt },
                                        else => unreachable,
                                    };
                                },
                                '5' => {
                                    return switch (buffer[5]) {
                                        'C' => .{ .right = .ctrl },
                                        'D' => .{ .left = .ctrl },
                                        'F' => .{ .end = .ctrl },
                                        'H' => .{ .home = .ctrl },
                                        else => unreachable,
                                    };
                                },
                                else => unreachable,
                            }
                        },
                        '3' => {
                            return switch (buffer[3]) {
                                '~' => .{ .delete = .none },
                                ';' => {
                                    return switch (buffer[4]) {
                                        '5' => {
                                            // For XTerm
                                            assert(buffer[5] == '~');
                                            return .{ .delete = .ctrl };
                                        },
                                        '2' => .{ .delete = .shift },
                                        else => unreachable,
                                    };
                                },
                                else => unreachable,
                            };
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
                    };
                },
                'd' => .{ .delete = .ctrl },
                else => unreachable,
            };
        },
        '\r' => .enter,
        '\t' => .tab,
        0x7F => .{ .backspace = .none },
        0x17 => .{ .backspace = .ctrl },
        0x08 => .{ .backspace = .ctrl }, // For XTerm
        19 => .ctrl_s,
        else => .{ .bytes = buffer },
    };
}
