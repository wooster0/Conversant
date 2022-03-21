const std = @import("std");
const mem = std.mem;
const ArrayList = std.ArrayList;

const terminal = @import("../terminal.zig");
const Position = @import("root").Position;
const editor = @import("../editor.zig");
// In here the representation doesn't matter as much so we can use a type alias.
const Lines = ArrayList(ArrayList(u8));

pub const Cursor = struct {
    const Self = @This();

    position: Position = .{ .row = 0, .column = 0 },

    /// An abstraction over the actual `terminal.cursor.setPosition` with an offset.
    fn setPositionWithOffset(self: Self, offset: Position) !void {
        try terminal.cursor.setPosition(.{
            .row = self.position.row + offset.row,
            .column = self.position.column + offset.column,
        });
    }

    pub fn draw(self: Self, lines: Lines, offset: Position) !void {
        try self.setPositionWithOffset(offset);
        try terminal.control.setBlackOnWhiteBackgroundCellColor();

        // Write the character that's below the cursor
        const current_line = self.getCurrentLine(lines).items;
        if (self.position.column >= current_line.len) {
            // If the index would be out of bounds, still draw the cursor
            try terminal.writeByte(' ');
        } else {
            try terminal.writeByte(current_line[self.position.column]);
        }
        try terminal.control.resetForegroundAndBackgroundCellColor();
    }

    fn insert(self: *Self, lines: Lines, char: u8) !void {
        const current_line = self.getCurrentLine(lines);
        try current_line.insert(self.position.column, char);
        self.position.column += 1;
    }

    fn insertSlice(self: *Self, lines: Lines, slice: []const u8) !void {
        const current_line = self.getCurrentLine(lines);
        try current_line.insertSlice(self.position.column, slice);
        self.position.column += @intCast(u16, slice.len);
    }

    fn getCurrentLine(self: Self, lines: Lines) *ArrayList(u8) {
        return &lines.items[self.position.row];
    }

    /// Returns the character before the cursor.
    ///
    /// If the cursor is at BOL, this returns `null`.
    fn getPreviousCharIndex(self: Self) ?u16 {
        if (self.position.column == 0) {
            // There is no character before this
            // TODO: get the last character of the previous line
            return null;
        } else {
            return self.position.column - 1;
        }
    }

    /// Returns the character on the cursor.
    ///
    /// If the cursor is at the EOL, this returns `null`.
    fn getCurrentCharIndex(self: Self, lines: Lines) ?u16 {
        if (self.position.column == self.getCurrentLine(lines).items.len) {
            // There is no character before this
            // TODO: get the first character of the next line
            return null;
        } else {
            return self.position.column;
        }
    }

    fn removeCurrentLineChar(self: Self, lines: Lines, index: u16) void {
        const current_line = self.getCurrentLine(lines);
        _ = current_line.orderedRemove(index);
    }

    /// Removes all consecutive spaces before the cursor
    /// and returns whether or not a space was removed.
    fn removePreviousSuccessiveSpaces(self: *Self, lines: Lines) bool {
        var space_removed = false;
        const current_line = self.getCurrentLine(lines);
        while (true) {
            if (self.getPreviousCharIndex()) |char_to_remove_index| {
                if (current_line.items[char_to_remove_index] == ' ') {
                    self.removeCurrentLineChar(lines, char_to_remove_index);
                    self.position.column -= 1;
                    space_removed = true;
                    continue;
                }
            }
            break;
        }
        return space_removed;
    }

    fn correctColumn(self: *Self, lines: Lines) void {
        const current_line_len = @intCast(u16, self.getCurrentLine(lines).items.len);
        if (self.position.column > current_line_len)
            self.position.column = current_line_len;
    }

    pub fn handleKey(self: *Self, allocator: mem.Allocator, lines: *Lines, key: terminal.input.Key) !?editor.Action {
        switch (key) {
            .char => |char| try self.insert(lines.*, char),

            .up => {
                self.position.row -|= 1;
                self.correctColumn(lines.*);
            },
            .down => {
                if (self.position.row != lines.items.len - 1) {
                    self.position.row += 1;
                    self.correctColumn(lines.*);
                }
            },
            .left => |modifier| {
                switch (modifier) {
                    .none => {
                        if (self.position.column == 0) {
                            // Wrap back to the previous line's end if we're not at BOF (beginning of file)
                            if (self.position.row != 0) {
                                self.position.row -= 1;
                                self.position.column = @intCast(u16, self.getCurrentLine(lines.*).items.len);
                            }
                        } else {
                            self.position.column -|= 1;
                        }
                    },
                    .ctrl => unreachable,
                }
            },
            .right => |modifier| {
                switch (modifier) {
                    .none => {
                        if (self.position.column == self.getCurrentLine(lines.*).items.len) {
                            // Wrap to the next line's start if we're not at EOF (end of file)
                            if (self.position.row != lines.items.len - 1) {
                                self.position.row += 1;
                                self.position.column = 0;
                            }
                        } else {
                            self.position.column += 1;
                        }
                    },
                    .ctrl => unreachable,
                }
            },

            .home => self.position.column = 0,
            .end => self.position.column = @intCast(u16, self.getCurrentLine(lines.*).items.len),
            .page_up => unreachable,
            .page_down => unreachable,

            .enter => {
                //
                // 1. Split the current line at the cursor's column into two
                //
                const current_line = self.getCurrentLine(lines.*);

                const lineBeforeNewline = current_line.items[0..self.position.column];
                var allocatedLineBeforeNewline = try ArrayList(u8).initCapacity(allocator, lineBeforeNewline.len);
                allocatedLineBeforeNewline.appendSliceAssumeCapacity(lineBeforeNewline);

                const lineAfterNewline = current_line.items[self.position.column..];
                var allocatedLineAfterNewline = try ArrayList(u8).initCapacity(allocator, lineAfterNewline.len);
                allocatedLineAfterNewline.appendSliceAssumeCapacity(lineAfterNewline);

                // 2. Replace the old line with the line before the newline
                current_line.* = allocatedLineBeforeNewline;

                self.position = .{
                    .row = self.position.row + 1,
                    .column = 0,
                };

                // 3. Insert the line after the newline
                try lines.insert(self.position.row, allocatedLineAfterNewline);
            },
            .tab => try self.insertSlice(lines.*, "    "),

            .backspace => |modifier| {
                switch (modifier) {
                    .none => {
                        // Remove a single character
                        if (self.getPreviousCharIndex()) |char_to_remove_index| {
                            self.removeCurrentLineChar(lines.*, char_to_remove_index);
                            self.position.column -= 1;
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
                            if (self.getPreviousCharIndex()) |char_to_remove_index| {
                                const current_line = self.getCurrentLine(lines.*);
                                if (current_line.items[char_to_remove_index] == ' ') {
                                    if (remove_spaces) {
                                        self.removeCurrentLineChar(lines.*, char_to_remove_index);
                                        self.position.column -= 1;
                                        const space_removed = self.removePreviousSuccessiveSpaces(lines.*);
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

                                self.removeCurrentLineChar(lines.*, char_to_remove_index);
                                self.position.column -= 1;
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
                        if (self.getCurrentCharIndex(lines.*)) |char_to_remove_index|
                            self.removeCurrentLineChar(lines.*, char_to_remove_index);
                    },
                    .ctrl => {},
                }
            },

            .esc => return .Exit,
        }
        return null;
    }
};
