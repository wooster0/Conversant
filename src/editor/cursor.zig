const std = @import("std");

const terminal = @import("../terminal.zig");
const Position = @import("../main.zig").Position;
const editor = @import("../editor.zig");
const Char = editor.Char;
const Line = editor.Line;

pub const Cursor = struct {
    const Self = @This();

    position: Position = .{ .row = 0, .column = 0 },
    /// This is the column that the cursor will try to be on, if possible.
    /// You could also say this column wants to be the one that the cursor is on.
    ///
    /// Here is an example showcasing correct behavior of cursor movement,
    /// where `|` is the cursor:
    ///
    /// 1. Initial state:
    ///    ```
    ///    hello| world
    ///
    ///    ```
    /// 2. Pressing down key:
    ///    ```
    ///    hello world
    ///    |
    ///    ```
    /// 3. Pressing up key: back to 1.
    ///
    /// This effect is achieved using the ambitious column.
    ambitiousColumn: u16 = 0,

    /// Counts all full-width characters in the string.
    fn countFullWidthChars(string: []const Char) !u16 {
        var full_width_char_count: u16 = 0;
        for (string) |char| {
            if (try editor.isFullWidthChar(char))
                full_width_char_count += 1;
        }
        return full_width_char_count;
    }

    pub fn draw(self: Self, current_line_chars: []const Char, max_line_number_width: u16, wrap_count: u16, row_offset: u16) !void {
        // TODO: Cursor positioning doesn't work well if a double width character is the one that causes a wrap to the next line
        const columns = self.position.column + try countFullWidthChars(current_line_chars[0..self.position.column]);
        const max_line_content_width = terminal.size.width - max_line_number_width;
        try terminal.cursor.setPosition(Position{
            .row = (self.position.row -| row_offset) + wrap_count + columns / max_line_content_width,
            .column = max_line_number_width + columns % max_line_content_width,
        });

        try terminal.control.setBlackOnWhiteBackgroundCellColor();

        if (self.position.column >= current_line_chars.len) {
            // If there is no character on the cursor, still draw it
            try terminal.writeByte(' ');
        } else {
            // Write the character that's below the cursor
            try terminal.writeChar(current_line_chars[self.position.column]);
        }

        try terminal.control.resetForegroundAndBackgroundCellColor();
    }

    /// Inserts content into a line.
    fn insertSlice(self: *Self, line: *Line, bytes: []const u8) !void {
        var utf8_iterator = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
        while (utf8_iterator.nextCodepoint()) |char| {
            try line.insert(self.position.column, char);
            self.position.column += 1;
        }
        self.setAmbitiousColumn();
    }

    /// Returns the index of character before the cursor, on the current line.
    ///
    /// If the cursor is at BOL, this returns `null`.
    fn getPreviousCharIndex(self: Self) ?u16 {
        if (self.position.column == 0) {
            // There is no character before this
            return null;
        } else {
            return self.position.column - 1;
        }
    }

    /// Returns the index of the character on the cursor, on the current line.
    ///
    /// If the cursor is at the EOL, this returns `null`.
    fn getCurrentCharIndex(self: Self, lines: []const Line) ?u16 {
        const current_line_chars = lines[self.position.row].items;
        if (self.position.column == current_line_chars.len) {
            // There is no character before this
            return null;
        } else {
            return self.position.column;
        }
    }

    /// Removes all consecutive spaces before the cursor
    /// and returns whether or not a space was removed.
    fn removePreviousSuccessiveSpaces(self: *Self, line: *Line) bool {
        var space_removed = false;
        while (self.getPreviousCharIndex()) |char_to_remove_index| {
            if (line.items[char_to_remove_index] == ' ') {
                _ = line.orderedRemove(char_to_remove_index);
                self.position.column -= 1;
                space_removed = true;
                continue;
            } else {
                break;
            }
        }
        return space_removed;
    }

    fn tryToReachAmbitiousColumn(self: *Self, lines: []const Line) void {
        const current_line_len = @intCast(u16, lines[self.position.row].items.len);
        if (current_line_len < self.ambitiousColumn) {
            // If the ambitious column is out of reach,
            // at least go to this line's end.
            self.position.column = current_line_len;
        } else {
            self.position.column = self.ambitiousColumn;
        }
    }

    fn setAmbitiousColumn(self: *Self) void {
        self.ambitiousColumn = self.position.column;
    }

    fn goToEOL(self: *Self, line: Line) void {
        self.position.column = @intCast(u16, line.items.len);
    }

    // TODO: Currently all blocks of successive non-space characters are treated as one "word".
    //       This could be improved to treat e.g. "hello.world" as 2 words instead of 1.

    fn goToNextLeftWholeWord(self: *Self, lines: []const Line) void {
        const current_line_chars = lines[self.position.row].items;
        if (self.getPreviousCharIndex()) |current_char_index| {
            self.position.column -= 1;
            if (current_line_chars[current_char_index] == ' ') {
                // Go to the right until we hit a non-space or EOL
                while (self.getPreviousCharIndex()) |char_index| : (self.position.column -= 1)
                    if (current_line_chars[char_index] != ' ')
                        break;
            }
            // Go to the right until we hit a space or EOL
            while (self.getPreviousCharIndex()) |char_index| : (self.position.column -= 1)
                if (current_line_chars[char_index] == ' ')
                    break;
        } else if (self.position.row != 0) {
            self.position.row -= 1;
            self.goToEOL(lines[self.position.row]);
            // Try again
            return self.goToNextLeftWholeWord(lines);
        }
        self.setAmbitiousColumn();
    }
    fn goToNextRightWholeWord(self: *Self, lines: []const Line) void {
        const current_line_chars = lines[self.position.row].items;
        if (self.getCurrentCharIndex(lines)) |current_char_index| {
            self.position.column += 1;
            if (current_line_chars[current_char_index] == ' ') {
                // Go to the right until we hit a non-space or EOL
                while (self.getCurrentCharIndex(lines)) |char_index| : (self.position.column += 1)
                    if (current_line_chars[char_index] != ' ')
                        break;
            }
            // Go to the right until we hit a space or EOL
            while (self.getCurrentCharIndex(lines)) |char_index| : (self.position.column += 1)
                if (current_line_chars[char_index] == ' ')
                    break;
        } else if (self.position.row != lines.len - 1) {
            self.position.row += 1;
            self.position.column = 0;
            // Try again
            return self.goToNextRightWholeWord(lines);
        }
        self.setAmbitiousColumn();
    }

    pub fn handleInput(self: *Self, allocator: std.mem.Allocator, allocated_lines: *std.ArrayList(Line), input: terminal.Input) !?editor.Action {
        const lines = allocated_lines.items;
        switch (input) {
            .bytes => |bytes| try self.insertSlice(&lines[self.position.row], bytes),

            .up => |modifier| {
                switch (modifier) {
                    .none => {
                        if (self.position.row == 0) {
                            // We are at BOF
                            self.position.column = 0;
                        } else {
                            self.position.row -= 1;
                            self.tryToReachAmbitiousColumn(lines);
                        }
                    },
                    .alt => {
                        // Swap lines
                        const current_line_chars = lines[self.position.row];
                        const upper_line_chars = lines[self.position.row -| 1];
                        lines[self.position.row] = upper_line_chars;
                        lines[self.position.row -| 1] = current_line_chars;
                        self.position.row -|= 1;
                    },
                }
            },
            .down => |modifier| {
                switch (modifier) {
                    .none => {
                        if (self.position.row == lines.len - 1) {
                            // We are at EOF
                            const last_line_index = @intCast(u16, lines.len - 1);
                            const last_line = lines[last_line_index];
                            self.goToEOL(last_line);
                        } else {
                            self.position.row += 1;
                            self.tryToReachAmbitiousColumn(lines);
                        }
                    },
                    .alt => {
                        if (self.position.row != lines.len - 1) {
                            // Swap lines
                            const current_line_chars = lines[self.position.row];
                            const lower_line_chars = lines[self.position.row + 1];
                            lines[self.position.row] = lower_line_chars;
                            lines[self.position.row + 1] = current_line_chars;
                            self.position.row += 1;
                        }
                    },
                }
            },
            .left => |modifier| {
                switch (modifier) {
                    .none => {
                        if (self.position.column == 0) {
                            // Wrap back to the previous line's end if we're not at BOF
                            if (self.position.row != 0) {
                                self.position.row -= 1;
                                self.goToEOL(lines[self.position.row]);
                            }
                        } else {
                            self.position.column -|= 1;
                        }
                    },
                    .ctrl => self.goToNextLeftWholeWord(lines),
                }
                self.setAmbitiousColumn();
            },
            .right => |modifier| {
                switch (modifier) {
                    .none => {
                        const current_line_chars = lines[self.position.row].items;
                        if (self.position.column == current_line_chars.len) {
                            // Wrap to the next line's start if we're not at EOF
                            if (self.position.row != lines.len - 1) {
                                self.position.row += 1;
                                self.position.column = 0;
                            }
                        } else {
                            self.position.column += 1;
                        }
                    },
                    .ctrl => self.goToNextRightWholeWord(lines),
                }
                self.setAmbitiousColumn();
            },

            .home => |modifier| {
                switch (modifier) {
                    .none => self.position.column = 0,
                    .ctrl => self.position = .{ .row = 0, .column = 0 },
                }
                self.setAmbitiousColumn();
            },
            .end => |modifier| {
                switch (modifier) {
                    .none => self.goToEOL(lines[self.position.row]),
                    .ctrl => {
                        const last_line_index = @intCast(u16, lines.len - 1);
                        const last_line = lines[last_line_index];

                        self.position.row = last_line_index;
                        self.goToEOL(last_line);
                    },
                }
                self.setAmbitiousColumn();
            },
            .page_up => unreachable,
            .page_down => unreachable,

            .enter => {
                // 1. Split the current line at the cursor's column into two
                const current_line = &lines[self.position.row];

                const line_before_newline = current_line.items[0..self.position.column];

                const line_after_newline = current_line.items[self.position.column..];
                var allocated_line_after_newline = try Line.initCapacity(allocator, line_after_newline.len);
                allocated_line_after_newline.appendSliceAssumeCapacity(line_after_newline);

                // 2. Replace the old line with the line before the newline
                try current_line.replaceRange(0, current_line.items.len, line_before_newline);

                self.position = .{
                    .row = self.position.row + 1,
                    .column = 0,
                };

                // 3. Insert the new line after the newline
                try allocated_lines.insert(self.position.row, allocated_line_after_newline);
            },
            .tab => try self.insertSlice(&lines[self.position.row], "    "),

            .backspace => |modifier| {
                if (self.getPreviousCharIndex() == null) {
                    // We are at BOL and there is no character on the left of the cursor to remove
                    if (self.position.row != 0) { // Not BOF?
                        // Remove the leading newline
                        self.position.row -= 1;
                        const removed_line = allocated_lines.orderedRemove(self.position.row);
                        if (removed_line.items.len != 0) {
                            try lines[self.position.row].insertSlice(0, removed_line.items);
                            self.position.column = @intCast(u16, removed_line.items.len);
                        }
                        removed_line.deinit();
                    }
                } else {
                    switch (modifier) {
                        .none => {
                            // Remove a single character
                            _ = lines[self.position.row].orderedRemove(self.getPreviousCharIndex().?);
                            self.position.column -= 1;
                        },
                        .ctrl => {
                            // Remove a whole word

                            // Go backwards from this point and remove all characters
                            // until we hit a space or BOL.
                            var remove_spaces = true;
                            while (self.getPreviousCharIndex()) |char_to_remove_index| {
                                const current_line = &lines[self.position.row];
                                if (current_line.items[char_to_remove_index] == ' ') {
                                    if (remove_spaces) {
                                        _ = lines[self.position.row].orderedRemove(char_to_remove_index);
                                        self.position.column -= 1;
                                        const space_removed = self.removePreviousSuccessiveSpaces(current_line);
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

                                _ = lines[self.position.row].orderedRemove(char_to_remove_index);
                                self.position.column -= 1;
                            }
                        },
                    }
                }
                self.setAmbitiousColumn();
            },
            .delete => |modifier| {
                if (modifier == .shift) {
                    // Remove the current line
                    if (self.position.row != lines.len - 1) {
                        const line = allocated_lines.orderedRemove(self.position.row);
                        line.deinit();
                        self.position.column = 0;
                    } else {
                        // This is our only line so clear it
                        lines[self.position.row].clearRetainingCapacity();
                    }
                } else if (self.getCurrentCharIndex(lines) == null) {
                    // We are at EOL and there is no character on the cursor to remove
                    if (self.position.row != lines.len - 1) { // Not EOF?
                        // Remove the trailing newline
                        const removed_line = allocated_lines.orderedRemove(self.position.row + 1);
                        if (removed_line.items.len != 0) {
                            const current_line = &lines[self.position.row];
                            try current_line.appendSlice(removed_line.items);
                        }
                        removed_line.deinit();
                    }
                } else {
                    switch (modifier) {
                        .none => {
                            // Remove the character the cursor is on
                            _ = lines[self.position.row].orderedRemove(self.getCurrentCharIndex(lines).?);
                        },
                        .shift => unreachable,
                        .ctrl => {
                            // Remove a whole word

                            // Go backwards from this point and remove all characters
                            // until we hit a space or BOL.
                            var remove_spaces = true;
                            while (self.getCurrentCharIndex(lines)) |char_to_remove_index| {
                                const current_line = &lines[self.position.row];
                                if (current_line.items[char_to_remove_index] == ' ') {
                                    if (remove_spaces) {
                                        _ = current_line.orderedRemove(char_to_remove_index);
                                        const space_removed = self.removePreviousSuccessiveSpaces(current_line);
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

                                _ = current_line.orderedRemove(char_to_remove_index);
                            }
                        },
                    }
                }
            },

            .esc => return .exit,
        }
        return null;
    }
};
