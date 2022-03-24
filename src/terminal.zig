//! This abstracts everything related to the terminal and provides everything needed for
//! display, manipulation, and input events.
//!
//! One great reference for this is <https://invisible-island.net/xterm/ctlseqs/ctlseqs.html>.

const std = @import("std");
const io = std.io;
const os = std.os;
const linux = os.linux;
const fmt = std.fmt;

pub const input = @import("terminal/input.zig");

const Position = @import("main.zig").Position;
const Size = @import("main.zig").Size;

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
    var winsize: linux.winsize = undefined;
    switch (os.errno(linux.ioctl(stdout.handle, linux.T.IOCGWINSZ, @ptrToInt(&winsize)))) {
        .SUCCESS => return Size{ .width = winsize.ws_col, .height = winsize.ws_row },
        else => |err| return os.unexpectedErrno(err),
    }
}

/// Control Sequence Indicator.
const CSI = "\x1b[";

/// Operating System Command.
const OSC = "\x1b]";

/// Alert/beep/bell escape sequence.
const alert = "\x07";

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
        termios.iflag &= ~(linux.IGNBRK | linux.BRKINT | linux.PARMRK | linux.ISTRIP | linux.INLCR | linux.IGNCR | linux.ICRNL | linux.IXON);
        termios.oflag &= ~linux.OPOST;
        termios.lflag &= ~(linux.ECHO | linux.ECHONL | linux.ICANON | linux.ISIG | linux.IEXTEN);
        termios.cflag &= ~(linux.CSIZE | linux.PARENB);
        termios.cflag |= linux.CS8;
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
        try write(CSI ++ "2J");
    }

    pub fn setBlackOnWhiteBackgroundCellColor() !void {
        try write(CSI ++ "30;107m");
    }

    pub fn resetForegroundAndBackgroundCellColor() !void {
        try write(CSI ++ "39;49m");
    }

    /// Sets the background color of the whole screen.
    ///
    /// `hex_color` is a hexadecimal color that does not start with a number sign.
    pub fn setScreenBackgroundColor(hex_color: []const u8) !void {
        try print(OSC ++ "11;#{s}" ++ alert, .{hex_color});
    }
    pub fn resetScreenBackgroundColor() !void {
        try write(OSC ++ "111" ++ alert);
    }

    /// Sets the foreground color of the whole screen.
    ///
    /// `hex_color` is a hexadecimal color that does not start with a number sign.
    pub fn setScreenForegroundColor(hex_color: []const u8) !void {
        try print(OSC ++ "10;#{s}" ++ alert, .{hex_color});
    }
    pub fn resetScreenForegroundColor() !void {
        try write(OSC ++ "110" ++ alert);
    }

    pub fn setTitle(title: []const u8) !void {
        try print(OSC ++ "0;{s}" ++ alert, .{title});
    }
};
