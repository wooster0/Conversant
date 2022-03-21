//! The editor.
//!
//! Some terminology:
//!
//! * BOF: beginning of file.
//! * BOL: beginning of line.
//! * EOL: end of line.
//! * EOF: end of file.

const std = @import("std");
const heap = std.heap;
const fs = std.fs;
const math = std.math;
const ArrayList = std.ArrayList;
const mem = std.mem;

const background = @import("editor/background.zig");

const terminal = @import("terminal.zig");
const Position = @import("root").Position;

/// This is used for all data that needs to persist throughout the program,
/// such as `lines`.
var arena_allocator = heap.ArenaAllocator.init(heap.page_allocator);
/// The content to be edited.
///
/// There is an important performance aspect of separating all the content by lines.
/// We frequently do insert operations on the individual `ArrayList(u8)`s that take O(n) because
/// we have to copy and move all data after the insert index.
/// These operations are very fast in our case because we separate all the content
/// and so there isn't a lot to copy.
///
/// But if we instead choose to have all content in one big `ArrayList(u8)` and we have a file
/// of 100,000 lines and we insert a character after the 50,000th character, the operation
/// will take quite long because all data after that point has to copied and moved
/// to make space for that one new character.
///
/// In addition, to properly draw the lines, we would have to split up the content into separate lines
/// on the fly all the time.
/// In our case, we don't have to do any of that.
var lines: ArrayList(ArrayList(u8)) = undefined;

pub fn open(path: [:0]const u8) !void {
    try background.setTimelyBackground();

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
    try background.setTimelyBackground();

    const allocator = arena_allocator.allocator();

    // Start with one, empty line
    lines = try ArrayList(ArrayList(u8)).initCapacity(allocator, 1);
    lines.appendAssumeCapacity(ArrayList(u8).init(allocator));
}

pub fn deinit() !void {
    try background.resetTimelyBackground();
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

        .up => {
            cursor.position.row -|= 1;
            cursor.correctColumn();
        },
        .down => {
            if (cursor.position.row != lines.items.len - 1) {
                cursor.position.row += 1;
                cursor.correctColumn();
            }
        },
        .left => |modifier| {
            switch (modifier) {
                .none => {
                    if (cursor.position.column == 0) {
                        // Wrap back to the previous line's end if we're not at BOF (beginning of file)
                        if (cursor.position.row != 0) {
                            cursor.position.row -= 1;
                            cursor.position.column = @intCast(u16, cursor.getCurrentLine().items.len);
                        }
                    } else {
                        cursor.position.column -|= 1;
                    }
                },
                .ctrl => unreachable,
            }
        },
        .right => |modifier| {
            switch (modifier) {
                .none => {
                    if (cursor.position.column == cursor.getCurrentLine().items.len) {
                        // Wrap to the next line's start if we're not at EOF (end of file)
                        if (cursor.position.row != lines.items.len - 1) {
                            cursor.position.row += 1;
                            cursor.position.column = 0;
                        }
                    } else {
                        cursor.position.column += 1;
                    }
                },
                .ctrl => unreachable,
            }
        },

        .home => cursor.position.column = 0,
        .end => cursor.position.column = @intCast(u16, cursor.getCurrentLine().items.len),
        .page_up => unreachable,
        .page_down => unreachable,

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

        .backspace => |modifier| {
            switch (modifier) {
                .none => {
                    // Remove a single character
                    if (cursor.getPreviousCharIndex()) |char_to_remove_index| {
                        cursor.removeCurrentLineChar(char_to_remove_index);
                    }
                },
                .ctrl => {
                    // Remove a whole word

                    // TODO: Currently all blocks of successive non-space characters are treated as one "word".
                    //       This could be improved to treat e.g. "hello.world" as 2 words instead of 1.

                    // Go backwards from this point and remove all characters
                    // until we hit a space or BOL (beginning of line)
                    //
                    // We expect the amount of characters until that happens
                    // to be small enough that a linear search is appropriate
                    var remove_spaces = true;
                    while (true) {
                        if (cursor.getPreviousCharIndex()) |char_to_remove_index| {
                            const current_line = cursor.getCurrentLine();
                            if (current_line.items[char_to_remove_index] == ' ') {
                                if (remove_spaces) {
                                    cursor.removeCurrentLineChar(char_to_remove_index);
                                    cursor.position.column -= 1;
                                    const space_removed = cursor.removePreviousSuccessiveSpaces();
                                    if (space_removed) {
                                        break;
                                    } else {
                                        continue;
                                    }
                                } else {
                                    break;
                                }
                            } else {
                                remove_spaces = false;
                            }

                            cursor.removeCurrentLineChar(char_to_remove_index);
                            cursor.position.column -= 1;
                        } else {
                            break;
                        }
                    }
                },
            }
        },
        .delete => |modifier| {
            switch (modifier) {
                .none => {
                    // Remove a single character
                    if (cursor.getCurrentCharIndex()) |char_to_remove_index| {
                        const current_line = cursor.getCurrentLine();
                        _ = current_line.orderedRemove(char_to_remove_index);
                    }
                },
                .ctrl => {},
            }
        },

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
        try terminal.control.setBlackOnWhiteBackgroundCellColor();

        // Write the character that's below the cursor
        const current_line = getCurrentLine().items;
        if (position.column >= current_line.len) {
            // If the index would be out of bounds, still draw the cursor
            try terminal.writeByte(' ');
        } else {
            try terminal.writeByte(current_line[position.column]);
        }
        try terminal.control.resetForegroundAndBackgroundCellColor();
    }

    fn insert(char: u8) !void {
        const current_line = getCurrentLine();
        try current_line.insert(position.column, char);
        position.column += 1;
    }

    fn insertSlice(slice: []const u8) !void {
        const current_line = getCurrentLine();
        try current_line.insertSlice(position.column, slice);
        position.column += @intCast(u16, slice.len);
    }

    fn getCurrentLine() *ArrayList(u8) {
        return &lines.items[position.row];
    }

    /// Returns the character before the cursor.
    ///
    /// If the cursor is at BOL, this returns `null`.
    fn getPreviousCharIndex() ?u16 {
        if (cursor.position.column == 0) {
            // There is no character before this
            // TODO: get the last character of the previous line
            return null;
        } else {
            return cursor.position.column - 1;
        }
    }

    /// Returns the character on the cursor.
    ///
    /// If the cursor is at the EOL, this returns `null`.
    fn getCurrentCharIndex() ?u16 {
        if (cursor.position.column == getCurrentLine().items.len) {
            // There is no character before this
            // TODO: get the first character of the next line
            return null;
        } else {
            return cursor.position.column;
        }
    }

    fn removeCurrentLineChar(index: u16) void {
        const current_line = cursor.getCurrentLine();
        _ = current_line.orderedRemove(index);
    }

    /// Removes all consecutive spaces before the cursor
    /// and returns whether or not a space was removed.
    fn removePreviousSuccessiveSpaces() bool {
        var space_removed = false;
        const current_line = getCurrentLine();
        while (true) {
            if (cursor.getPreviousCharIndex()) |char_to_remove_index| {
                if (current_line.items[char_to_remove_index] == ' ') {
                    cursor.removeCurrentLineChar(char_to_remove_index);
                    position.column -= 1;
                    space_removed = true;
                    continue;
                }
            }
            break;
        }
        return space_removed;
    }

    fn correctColumn() void {
        const current_line_len = @intCast(u16, getCurrentLine().items.len);
        if (position.column > current_line_len)
            position.column = current_line_len;
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
