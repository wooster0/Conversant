const std = @import("std");
const heap = std.heap;
const fs = std.fs;
const math = std.math;
const ArrayList = std.ArrayList;
const mem = std.mem;

const terminal = @import("terminal.zig");
const Position = @import("root").Position;

/// This is used for all data that needs to persist throughout the program,
/// such as the lines to edit.
var arena_allocator = heap.ArenaAllocator.init(heap.page_allocator);
var lines: ArrayList(ArrayList(u8)) = undefined;

pub fn open(path: [:0]const u8) !void {
    const allocator = arena_allocator.allocator();

    const file = try fs.cwd().openFileZ(path, .{});

    lines = ArrayList(ArrayList(u8)).init(allocator);
    while (true) {
        var line = ArrayList(u8).init(allocator);
        if (file.reader().readUntilDelimiterArrayList(&line, '\n', math.maxInt(usize))) { // TODO: eliminate the internal max_size check
            try lines.append(line);
        } else |err| {
            if (err == error.EndOfStream) {
                try lines.append(line);
                break;
            } else {
                return err;
            }
        }
    }
}

pub fn new_file() !void {
    const allocator = arena_allocator.allocator();

    // Start with one, empty line.
    lines = try ArrayList(ArrayList(u8)).initCapacity(allocator, 1);
    lines.appendAssumeCapacity(ArrayList(u8).init(allocator));
}

pub fn deinit() void {
    arena_allocator.deinit();
}

pub fn run() !void {
    const allocator = arena_allocator.allocator();

    while (true) {
        try draw();
        if (try handleEvents(allocator)) |action| {
            switch (action) {
                .Exit => break,
            }
        }
    }
}

const Action = enum { Exit };

fn handleEvents(allocator: mem.Allocator) !?Action {
    const input = try terminal.readInput();

    switch (input) {
        .char => |char| try cursor.insert(char),

        .up => cursor.position.row -|= 1,
        .down => cursor.position.row += 1,
        .left => cursor.position.column -|= 1,
        .right => cursor.position.column += 1,

        .enter => {
            //
            // 1. Split the current line at the cursor's column into two
            //
            const current_line = cursor.getCurrentLine();

            const lineBeforeNewline = current_line.items[0..cursor.position.column];
            var allocatedLineBeforeNewline = try ArrayList(u8).initCapacity(allocator, lineBeforeNewline.len);
            allocatedLineBeforeNewline.appendSliceAssumeCapacity(lineBeforeNewline);

            const lineAfterNewline = current_line.items[cursor.position.column..];
            var allocatedLineAfterNewline = try ArrayList(u8).initCapacity(allocator, lineAfterNewline.len);
            allocatedLineAfterNewline.appendSliceAssumeCapacity(lineAfterNewline);

            // 2. Replace the old line with the line before the newline
            current_line.* = allocatedLineBeforeNewline;

            cursor.position = .{
                .row = cursor.position.row + 1,
                .column = 0,
            };

            // 3. Insert the line after the newline
            try lines.insert(cursor.position.row, allocatedLineAfterNewline);
        },
        .tab => try cursor.insertSlice("    "),
        .esc => return .Exit,
    }
    return null;
}

fn draw() !void {
    try terminal.control.clear();
    try terminal.cursor.reset();

    const padding = getDigitCount(lines.items.len);
    const line_number_count = @minimum(terminal.size.height - 1, lines.items.len);

    var row: usize = 0;
    while (row < line_number_count) : (row += 1) {
        const line_number = row + 1;
        const line = lines.items[row].items;
        try drawLine(line_number, padding, line);
    }

    const offset = Position{ .row = 0, .column = @intCast(u16, padding) + 1 };

    try cursor.draw(offset);

    try terminal.flush();
}

/// Draws a row's line: the line number followed by the line content.
fn drawLine(line_number: usize, padding: usize, line: []const u8) !void {
    try terminal.print(
        "{[0]:>[1]}│{[2]s}\r\n",
        .{
            line_number,
            padding,
            line,
        },
    );
}

/// Returns the amount of digits in this number.
fn getDigitCount(number: anytype) @TypeOf(number) {
    if (number == 0) {
        return 1;
    } else {
        return math.log10(number) + 1;
    }
}

const cursor = struct {
    var position = Position{ .row = 0, .column = 0 };

    /// An abstraction over the actual `setPosition` with an offset.
    fn setPositionWithOffset(offset: Position) !void {
        try terminal.cursor.setPosition(.{
            .row = position.row + offset.row,
            .column = position.column + offset.column,
        });
    }

    fn draw(offset: Position) !void {
        try setPositionWithOffset(offset);
        try terminal.control.setBlackOnWhiteBackgroundColor();

        // Write the character that's below the cursor
        const current_line = getCurrentLine().items;
        if (current_line.len == 0) {
            try terminal.write(" ");
        } else {
            try terminal.write(&[1]u8{current_line[position.column]});
        }
        try terminal.control.resetForegroundAndBackgroundColor();
    }

    fn insert(char: u8) !void {
        var current_line = getCurrentLine();
        try current_line.insert(position.column, char);
        position.column += 1;
    }

    fn insertSlice(slice: []const u8) !void {
        var current_line = getCurrentLine();
        try current_line.insertSlice(position.column, slice);
        position.column += @intCast(u16,slice.len);
    }

    fn getCurrentLine() *ArrayList(u8) {
        return &lines.items[position.row];
    }
};

const expectEqual = std.testing.expectEqual;

test "getDigitCount" {
    try expectEqual(1, getDigitCount(0));
    try expectEqual(1, getDigitCount(5));
    try expectEqual(3, getDigitCount(100));
    try expectEqual(5, getDigitCount(12345));
    try expectEqual(9, getDigitCount(123456789));
}
