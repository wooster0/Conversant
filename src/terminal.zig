//! This abstracts everything related to the terminal and provides everything needed for
//! display  and manipulation.

const std = @import("std");
const io = std.io;
const os = std.os;
const fmt = std.fmt;
const builtin = @import("builtin");

const Position = @import("root").Position;
const Size = @import("root").Size;

const stdin = io.getStdIn();
const stdout = io.getStdOut();

const writing = struct {
    const stdout_writer = stdout.writer();
    var buffered_writer = (io.BufferedWriter(4096, @TypeOf(stdout_writer)){ .unbuffered_writer = stdout_writer });
    const writer = buffered_writer.writer();

    fn write(bytes: []const u8) !void {
        try writer.writeAll(bytes);
    }
    fn flush() !void {
        try buffered_writer.flush();
    }
};
pub const write = writing.write;
pub const writeByte = writing.writer.writeByte;
pub const writeByteNTimes = writing.writer.writeByteNTimes;
pub const print = writing.writer.print;
pub const flush = writing.flush;

pub var size: Size = undefined;

fn isSupported() bool {
    return stdout.supportsAnsiEscapeCodes();
}

/// Checks whether the terminal is supported and initializes the terminal into raw mode.
pub fn init() !void {
    if (!isSupported())
        return error.Unsupported;
    size = try getSize();
    try config.init();
}
/// Makes the terminal mode cooked (i.e. not raw).
pub fn deinit() !void {
    try config.deinit();
}

/// Returns the size of the terminal.
fn getSize() !Size {
    var winsize: os.system.winsize = undefined;
    switch (os.errno(os.system.ioctl(stdout.handle, os.system.T.IOCGWINSZ, @ptrToInt(&winsize)))) {
        .SUCCESS => return Size{ .width = winsize.ws_col, .height = winsize.ws_row },
        else => |err| return os.unexpectedErrno(err),
    }
}

const stdin_reader = stdin.reader();
pub fn readInput() !Input {
    var buffer = [1]u8{undefined} ** 4;
    var bytes_read = try stdin_reader.read(&buffer);
    // debug("{any}", .{buffer[0..bytes_read]});

    return parseInput(buffer[0..bytes_read]);
}

const Input = union(enum) {
    char: u8,

    up,
    down,
    left,
    right,

    enter,
    tab,
    backspace,
    esc,
};

fn parseInput(buffer: []const u8) Input {
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
        0x7F => .backspace,
        else => .{ .char = buffer[0] },
    };
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    if (builtin.mode != .Debug)
        @compileError("this function is only available in debug mode");

    // Position it in the top right
    const output_length = fmt.count(format, args);
    cursor.setPosition(.{ .row = 0, .column = @intCast(u16, size.width - output_length) }) catch {};

    print(format, args) catch {};
}

const CSI = "\x1b[";

pub const config = struct {
    var original_termios: os.termios = undefined;

    /// Initializes the terminal into raw mode.
    fn init() !void {
        original_termios = try getTermios();

        var current_termios = original_termios;
        makeTermiosRaw(&current_termios);
        try setTermios(current_termios);
    }

    fn deinit() !void {
        try setTermios(original_termios);

        try disableAlternativeScreenBuffer();
        try showCursor();
    }

    fn getTermios() !os.termios {
        return os.tcgetattr(stdout.handle);
    }
    fn setTermios(termios: os.termios) !void {
        try os.tcsetattr(stdout.handle, .FLUSH, termios);
    }
    fn makeTermiosRaw(termios: *os.termios) void {
        termios.iflag &= ~(os.system.IGNBRK | os.system.BRKINT | os.system.PARMRK | os.system.ISTRIP | os.system.INLCR | os.system.IGNCR | os.system.ICRNL | os.system.IXON);
        termios.oflag &= ~os.system.OPOST;
        termios.lflag &= ~(os.system.ECHO | os.system.ECHONL | os.system.ICANON | os.system.ISIG | os.system.IEXTEN);
        termios.cflag &= ~(os.system.CSIZE | os.system.PARENB);
        termios.cflag |= os.system.CS8;
    }

    pub fn showCursor() !void {
        try write(CSI ++ "?25h");
    }
    pub fn hideCursor() !void {
        try write(CSI ++ "?25l");
    }

    pub fn enableAlternativeScreenBuffer() !void {
        try write(CSI ++ "?1049h");
    }
    pub fn disableAlternativeScreenBuffer() !void {
        try write(CSI ++ "?1049l");
    }
};

pub const cursor = struct {
    pub fn setPosition(position: Position) !void {
        // This is one-based
        try print(CSI ++ "{};{}H", .{ position.row + 1, position.column + 1 });
    }

    /// Moves the cursor to (0, 0).
    pub fn reset() !void {
        try write(CSI ++ ";H");
    }
};

pub const control = struct {
    /// Clears the entire screen.
    pub fn clear() !void {
        try write("\x1b[2J");
    }

    pub fn setBlackOnWhiteBackgroundColor() !void {
        try write(CSI ++ "30;107m");
    }

    pub fn resetForegroundAndBackgroundColor() !void {
        try write(CSI ++ "39;49m");
    }
};
