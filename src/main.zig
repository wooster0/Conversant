const std = @import("std");
const process = std.process;
const heap = std.heap;

const terminal = @import("terminal.zig");
const Editor = @import("editor.zig").Editor;

// From what I've seen, 16 bit generally serves as the maximum cell range in many if not most terminals
pub const Position = struct { row: u16, column: u16 };
pub const Size = struct { width: u16, height: u16 };

fn initTerminal() !void {
    try terminal.init();
    try terminal.control.enableAlternativeScreenBuffer();

    // We don't need the inbuilt cursor because there could be
    // multiple cursors (e.g. multi-cursor select) and so we need to draw them by ourselves.
    try terminal.cursor.hide();

    // A flush for this will follow later
}

fn deinitTerminal() !void {
    try terminal.deinit();
    try terminal.control.disableAlternativeScreenBuffer();
    try terminal.cursor.show();
    try terminal.flush();
}

pub fn main() anyerror!void {
    try initTerminal();

    var args = process.args();

    _ = args.skip(); // Skip the program name

    var arena_allocator = heap.ArenaAllocator.init(heap.page_allocator);
    const allocator = arena_allocator.allocator();

    var editor: Editor = undefined;
    if (args.nextPosix()) |path| {
        editor = try Editor.openFile(allocator, path);
    } else {
        editor = try Editor.new(allocator);
    }
    try editor.run(allocator);

    try editor.deinit();
    try deinitTerminal();
}

/// Prints to a local file "debug-output" for debugging, ignoring any errors.
///
/// This is used as an alternative to printing to the terminal
/// because it's more or less occupied with the editor.
pub fn debug(comptime format: []const u8, args: anytype) void {
    if (@import("builtin").mode != .Debug)
        @compileError("this function can only be used in debug mode");

    const file = std.fs.cwd().createFile("debug-output", .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writer().print(format ++ "\n", args) catch return;
}
