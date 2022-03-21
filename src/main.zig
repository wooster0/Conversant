const std = @import("std");

const terminal = @import("terminal.zig");
const editor = @import("editor.zig");

pub const Position = struct { row: u16, column: u16 };
pub const Size = struct { width: u16, height: u16 };

fn initTerminal() !void {
    try terminal.init();
    try terminal.config.enableAlternativeScreenBuffer();

    // We don't need the inbuilt cursor because there could be
    // multiple cursors (e.g. multi-cursor select) and so we need to draw them by ourselves
    try terminal.config.hideCursor();

    // A flush for this will follow later
}

fn deinitTerminal() !void {
    try terminal.deinit();
    try terminal.config.disableAlternativeScreenBuffer();
    try terminal.config.showCursor();
    try terminal.flush();
}

pub fn main() anyerror!void {
    try initTerminal();

    var args = std.process.args();

    _ = args.skip(); // Skip the program name

    if (args.nextPosix()) |path| {
        try editor.open(path);
    } else {
        try editor.new_file();
    }
    try editor.run();

    try editor.deinit();
    try deinitTerminal();
}

/// Prints to a local file "debug-output" to debug with, ignoring any errors.
///
/// This is used as an alternative to printing to the terminal
/// because that one is more or less occupied with the editor.
pub fn debug(comptime format: []const u8, args: anytype) void {
    if (@import("builtin").mode != .Debug)
        @compileError("this function is only available in debug mode");

    const file = std.fs.cwd().createFile("debug-output", .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writer().print(format, args) catch return;
}
