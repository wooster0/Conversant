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
    defer editor.deinit();
    try editor.run();

    try deinitTerminal();
}
