//! The editor.
//!
//! Some terminology:
//!
//! * BOF: beginning of file.
//! * BOL: beginning of line.
//! * EOL: end of line.
//! * EOF: end of file.

const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const fs = std.fs;
const unicode = std.unicode;
const math = std.math;
const heap = std.heap;

const Cursor = @import("editor/cursor.zig").Cursor;
const background = @import("editor/background.zig");
const terminal = @import("terminal.zig");
const Position = @import("main.zig").Position;

pub const Action = enum { exit };

/// A Unicode codepoint that, when required, can be decoded to bytes on the fly.
pub const Char = u21;

pub const Line = ArrayList(Char);

/// Returns whether or not the given character is full-width.
/// 'Ａ' is a full-width character.
/// 'A' is a half-width character.
pub fn isFullWidthChar(char: Char) !bool {
    // Most of the time this works pretty well for many languages, including
    // Japanese (excluding half-width katakana (TODO: handle that?)), Korean, Chinese, and others.
    return (try unicode.utf8CodepointSequenceLength(char)) >= 3;
}

/// Returns a character's width in columns.
fn getCharWidth(char: Char) !u16 {
    return if (try isFullWidthChar(char)) 2 else 1;
}

pub const Editor = struct {
    const Self = @This();

    /// The content to be edited.
    ///
    /// There is an important performance aspect to separating all the content by lines.
    /// We frequently do insert operations on the individual `Line`s which take O(n) because
    /// we have to copy and move all data after the insert index.
    /// These operations are very fast in our case because we separate all the content
    /// and so there isn't a lot to copy.
    ///
    /// If we instead chose to have all content in one big `Line` and we have a file
    /// of 100,000 lines and we insert a character after the 50,000th character, the operation
    /// will take quite long because all data after that point has to copied and moved
    /// to make space for that one new character.
    ///
    /// In addition, to properly draw the lines, we would have to split up the content into separate lines
    /// on the fly all the time.
    ///
    /// In our case, we don't have to do any of that.
    lines: ArrayList(Line),
    cursor: Cursor = .{},
    /// This is used for vertical scrolling.
    row_offset: u16 = 0,

    /// Sets the window's title indicating the file that is currently edited.
    fn setTitle(file_name: []const u8) !void {
        try terminal.control.setTitle("{s} - Conversant", .{file_name});
    }

    pub fn new(allocator: mem.Allocator) !Self {
        try background.setTimelyBackground();

        // Start with one, empty line
        var lines = try ArrayList(Line).initCapacity(allocator, 1);
        lines.appendAssumeCapacity(Line.init(allocator));

        // To distinguish from any possible real file names, this "file name" starts with a forward slash
        // which is illegal on most systems
        try setTitle("/new file/");

        return Self{ .lines = lines };
    }

    pub fn openFile(allocator: mem.Allocator, path: [:0]const u8) !Self {
        try background.setTimelyBackground();

        const file = try fs.cwd().openFileZ(path, .{});
        defer file.close();

        var raw_lines = ArrayList(ArrayList(u8)).init(allocator);
        while (true) {
            var raw_line = ArrayList(u8).init(allocator);
            if (file.reader().readUntilDelimiterArrayList(&raw_line, '\n', math.maxInt(usize))) { // TODO: eliminate the internal max_size check
                try raw_lines.append(raw_line);
            } else |err| {
                if (err == error.EndOfStream) {
                    try raw_lines.append(raw_line);
                    break;
                } else {
                    return err;
                }
            }
        }

        // Now properly process all bytes by codepoint
        var lines = try ArrayList(Line).initCapacity(allocator, raw_lines.items.len);
        for (raw_lines.items) |raw_line| {
            var line = Line.init(allocator);
            var utf8_iterator = unicode.Utf8Iterator{ .bytes = raw_line.items, .i = 0 };
            while (utf8_iterator.nextCodepoint()) |char|
                try line.append(char);
            lines.appendAssumeCapacity(line);
        }

        raw_lines.deinit();

        try setTitle(path);

        return Self{ .lines = lines };
    }

    pub fn deinit(self: *Self) !void {
        try background.resetTimelyBackground();
        for (self.lines.items) |line|
            line.deinit();
        self.lines.deinit();
    }

    pub fn run(self: *Self, allocator: mem.Allocator) !void {
        while (true) {
            try self.draw();

            if (try self.handleEvents(allocator)) |action| {
                switch (action) {
                    .exit => break,
                }
            }

            self.row_offset = std.math.clamp(
                self.row_offset,
                self.cursor.position.row -| (terminal.size.height -| 1),
                self.cursor.position.row,
            );
        }
    }

    fn handleEvents(self: *Self, allocator: mem.Allocator) !?Action {
        const read_input = (try terminal.read()) orelse return null;

        return self.cursor.handleInput(allocator, &self.lines, read_input);
    }

    fn draw(self: Self) !void {
        try terminal.control.clear();
        try terminal.cursor.reset();

        const max_line_number_width = @intCast(u16, std.fmt.count("{}|", .{self.lines.items.len}));

        const lines = self.lines.items[self.row_offset..@minimum(self.lines.items.len, @minimum(self.lines.items.len, terminal.size.height) + self.row_offset)];

        var wrap_count: u16 = 0;
        for (lines) |line, row| {
            const is_last_line = row == lines.len - 1;
            const additional_wrap_count = try drawLine(row + self.row_offset + 1, max_line_number_width, line, is_last_line);
            const is_behind_cursor = row < self.cursor.position.row;
            if (is_behind_cursor)
                wrap_count += additional_wrap_count;
        }

        try self.cursor.draw(lines[self.cursor.position.row - self.row_offset].items, max_line_number_width, wrap_count, self.row_offset);

        try terminal.flush();
    }

    /// Draws a row's line: the line number followed by the line content.
    fn drawLine(line_number: usize, max_line_number_width: u16, line: Line, is_last_line: bool) !u16 {
        try terminal.print(
            "{[0]:>[1]}│",
            .{
                line_number,
                max_line_number_width - 1, // Minus the vertical bar
            },
        );

        var wrap_count: u16 = 0;
        var line_width = max_line_number_width;
        for (line.items) |char| {
            if ((try isFullWidthChar(char)) and line_width + try getCharWidth(char) >= terminal.size.width) {
                if (!is_last_line)
                    try terminal.cursor.setToBeginningOfNextLine();
                var space_count = max_line_number_width;
                try terminal.writeByteNTimes(' ', space_count);
                line_width = space_count;

                wrap_count += 1;
            }

            try terminal.writeChar(char);
            line_width += try getCharWidth(char);

            if (line_width >= terminal.size.width) {
                var space_count = max_line_number_width;
                try terminal.writeByteNTimes(' ', space_count);
                line_width = space_count;

                wrap_count += 1;
            }
        }

        if (!is_last_line)
            try terminal.cursor.setToBeginningOfNextLine();

        return wrap_count;
    }
};

const testing = std.testing;

fn getEditor(content: []const u8) !Editor {
    const allocator = testing.allocator_instance.allocator();

    var lines = ArrayList(Line).init(allocator);
    var line_iterator = mem.split(u8, content, "\n");
    while (line_iterator.next()) |line| {
        var allocatedLine = Line.init(allocator);
        var utf8_iterator = unicode.Utf8Iterator{ .bytes = line, .i = 0 };
        while (utf8_iterator.nextCodepoint()) |char|
            try allocatedLine.append(char);
        try lines.append(allocatedLine);
    }

    return Editor{ .lines = lines };
}

const expect = testing.expect;

fn expectEditor(editor: Editor, expected: []const u8) !void {
    var expected_line_index: usize = 0;
    var expected_line_iterator = mem.split(u8, expected, "\n");
    while (expected_line_iterator.next()) |expected_line| : (expected_line_index += 1) {
        try expect(expected_line_index < editor.lines.items.len);
        const actual_line = editor.lines.items[expected_line_index].items;

        var char_index: usize = 0;
        var utf8_iterator = unicode.Utf8Iterator{ .bytes = expected_line, .i = 0 };
        while (utf8_iterator.nextCodepoint()) |expected_char| : (char_index += 1) {
            try expect(char_index < actual_line.len);
            try expectEqual(expected_char, actual_line[char_index]);
        }
        try expectEqual(char_index, actual_line.len);
    }
    try expectEqual(expected_line_index, editor.lines.items.len);
}

/// Inputs and emulates input to the editor.
fn input(editor: *Editor, input_to_emulate: terminal.Input) !void {
    const allocator = testing.allocator_instance.allocator();

    try expect((try editor.cursor.handleInput(allocator, &editor.lines, input_to_emulate)) == null);
}

const expectEqual = testing.expectEqual;

test "insertion" {
    var editor = try getEditor(
        \\hello world
    );

    try input(&editor, .{ .bytes = "hello " });
    try expectEqual(Position{ .row = 0, .column = 6 }, editor.cursor.position);
    try expectEditor(editor,
        \\hello hello world
    );

    try input(&editor, .{ .bytes = "editor " });
    try expectEqual(Position{ .row = 0, .column = 13 }, editor.cursor.position);
    try expectEditor(editor,
        \\hello editor hello world
    );

    try input(&editor, .{ .end = .none });
    try input(&editor, .enter);
    try input(&editor, .{ .bytes = "こんにちは世界" });
    try expectEqual(Position{ .row = 1, .column = 7 }, editor.cursor.position);
    try expectEditor(editor,
        \\hello editor hello world
        \\こんにちは世界
    );

    try editor.deinit();
}

test "cursor movement" {
    var editor = try getEditor(
        \\
        \\hello
        \\
        \\world  hello editor
    );

    try input(&editor, .{ .down = .none });
    try expectEqual(Position{ .row = 1, .column = 0 }, editor.cursor.position);

    try input(&editor, .{ .right = .none });
    try expectEqual(Position{ .row = 1, .column = 1 }, editor.cursor.position);

    try input(&editor, .{ .end = .none });
    try expectEqual(Position{ .row = 1, .column = 5 }, editor.cursor.position);

    try input(&editor, .{ .down = .none });
    try expectEqual(Position{ .row = 2, .column = 0 }, editor.cursor.position);

    try input(&editor, .{ .down = .none });
    try expectEqual(Position{ .row = 3, .column = 5 }, editor.cursor.position);

    try input(&editor, .{ .home = .ctrl });
    try expectEqual(Position{ .row = 0, .column = 0 }, editor.cursor.position);

    try input(&editor, .{ .end = .ctrl });
    try expectEqual(Position{ .row = 3, .column = 19 }, editor.cursor.position);

    try input(&editor, .{ .left = .ctrl });
    try expectEqual(Position{ .row = 3, .column = 13 }, editor.cursor.position);

    try input(&editor, .{ .left = .ctrl });
    try expectEqual(Position{ .row = 3, .column = 7 }, editor.cursor.position);

    try input(&editor, .{ .left = .ctrl });
    try expectEqual(Position{ .row = 3, .column = 0 }, editor.cursor.position);

    try input(&editor, .{ .right = .ctrl });
    try expectEqual(Position{ .row = 3, .column = 5 }, editor.cursor.position);

    try input(&editor, .{ .right = .ctrl });
    try expectEqual(Position{ .row = 3, .column = 12 }, editor.cursor.position);

    try editor.deinit();

    editor = try getEditor(
        \\안녕
        \\
        \\
        \\hello editor
    );

    try input(&editor, .{ .right = .ctrl });
    try input(&editor, .{ .right = .ctrl });
    try expectEqual(Position{ .row = 3, .column = 5 }, editor.cursor.position);

    try input(&editor, .{ .left = .ctrl });
    try input(&editor, .{ .left = .ctrl });
    try expectEqual(Position{ .row = 0, .column = 0 }, editor.cursor.position);

    try editor.deinit();
}

test "movement" {
    var editor = try getEditor(
        \\this is a test
        \\hello editor
        \\
        \\こんにちは
    );

    try input(&editor, .{ .right = .ctrl });

    try input(&editor, .{ .up = .alt });
    try input(&editor, .{ .down = .alt });
    try expectEditor(editor,
        \\hello editor
        \\this is a test
        \\
        \\こんにちは
    );

    try input(&editor, .{ .down = .alt });
    try input(&editor, .{ .down = .alt });
    try input(&editor, .{ .down = .alt });
    try expectEqual(Position{ .row = 3, .column = 4 }, editor.cursor.position);
    try expectEditor(editor,
        \\hello editor
        \\
        \\こんにちは
        \\this is a test
    );

    try editor.deinit();
}

test "removal" {
    var editor = try getEditor(
        \\
        \\hello world
        \\hello editor
    );

    try input(&editor, .{ .backspace = .none });
    try expectEqual(Position{ .row = 0, .column = 0 }, editor.cursor.position);

    try input(&editor, .{ .delete = .none });
    try expectEqual(Position{ .row = 0, .column = 0 }, editor.cursor.position);

    try input(&editor, .{ .delete = .none });
    try input(&editor, .{ .delete = .none });
    try expectEqual(Position{ .row = 0, .column = 0 }, editor.cursor.position);
    try expectEditor(editor,
        \\llo world
        \\hello editor
    );

    try input(&editor, .{ .down = .none });
    try input(&editor, .{ .backspace = .none });
    try expectEqual(Position{ .row = 0, .column = 9 }, editor.cursor.position);
    try input(&editor, .{ .backspace = .none });
    try input(&editor, .{ .backspace = .none });
    try expectEqual(Position{ .row = 0, .column = 7 }, editor.cursor.position);
    try expectEditor(editor,
        \\llo worhello editor
    );

    try editor.deinit();

    editor = try getEditor(
        \\hello world
        \\
        \\
        \\
        \\
        \\hello editor
    );

    try input(&editor, .{ .down = .none });
    try input(&editor, .{ .down = .none });
    try input(&editor, .{ .down = .none });
    try input(&editor, .{ .down = .none });

    try input(&editor, .{ .backspace = .none });
    try expectEditor(editor,
        \\hello world
        \\
        \\
        \\
        \\hello editor
    );

    try input(&editor, .{ .backspace = .ctrl });
    try expectEditor(editor,
        \\hello world
        \\
        \\
        \\hello editor
    );

    try input(&editor, .{ .delete = .none });
    try expectEditor(editor,
        \\hello world
        \\
        \\hello editor
    );

    try input(&editor, .{ .up = .none });
    try input(&editor, .{ .delete = .ctrl });
    try input(&editor, .{ .delete = .ctrl });
    try input(&editor, .{ .delete = .ctrl });
    try expectEditor(editor,
        \\hello world
        \\
    );

    try input(&editor, .{ .backspace = .ctrl });
    try input(&editor, .{ .backspace = .ctrl });
    try input(&editor, .{ .backspace = .ctrl });
    try expectEditor(editor,
        \\
    );

    try editor.deinit();

    editor = try getEditor(
        \\你好
        \\我是editor
    );

    try input(&editor, .{ .delete = .none });
    try input(&editor, .{ .delete = .none });
    try expectEditor(editor,
        \\
        \\我是editor
    );

    try input(&editor, .{ .down = .none });
    try input(&editor, .{ .right = .none });
    try input(&editor, .{ .right = .none });
    try input(&editor, .{ .backspace = .none });
    try input(&editor, .{ .backspace = .none });
    try expectEqual(Position{ .row = 1, .column = 0 }, editor.cursor.position);
    try expectEditor(editor,
        \\
        \\editor
    );

    try input(&editor, .{ .delete = .shift });
    try input(&editor, .{ .delete = .shift });
    try input(&editor, .{ .bytes = "hello" });
    try input(&editor, .{ .delete = .shift });
    try expectEditor(editor,
        \\
        \\
    );

    try editor.deinit();

    editor = try getEditor(
        \\hello world
        \\hello editor
        \\hello world
        \\
        \\hello editor hello editor
        \\hello world hello world
        \\
        \\hello editor
    );

    try input(&editor, .{ .down = .none });
    try input(&editor, .{ .down = .none });
    try input(&editor, .{ .end = .none });
    try input(&editor, .{ .delete = .shift });
    try input(&editor, .{ .delete = .shift });
    try input(&editor, .{ .delete = .shift });
    try input(&editor, .{ .delete = .shift });
    try input(&editor, .{ .delete = .shift });
    try input(&editor, .{ .delete = .shift });
    try expectEqual(Position{ .row = 2, .column = 0 }, editor.cursor.position);
    try expectEditor(editor,
        \\hello world
        \\hello editor
        \\
    );

    try input(&editor, .{ .backspace = .ctrl });
    try expectEditor(editor, "hello world\nhello ");
    try input(&editor, .{ .backspace = .ctrl });
    try expectEditor(editor, "hello world\n");
    try input(&editor, .{ .backspace = .ctrl });
    try expectEditor(editor, "hello ");
    try input(&editor, .{ .backspace = .ctrl });
    try input(&editor, .{ .backspace = .none });
    try expectEditor(editor, "");

    try editor.deinit();

    editor = try getEditor(
        \\this is a test
        \\
        \\
        \\hello editor
        \\hello world
    );

    try input(&editor, .{ .down = .none });
    try input(&editor, .{ .delete = .ctrl });
    try input(&editor, .{ .delete = .ctrl });
    try expectEditor(editor,
        \\this is a test
        \\ editor
        \\hello world
    );

    try input(&editor, .{ .delete = .ctrl });
    try expectEditor(editor,
        \\this is a test
        \\
        \\hello world
    );

    try input(&editor, .{ .delete = .ctrl });
    try expectEditor(editor,
        \\this is a test
        \\ world
    );

    try input(&editor, .{ .delete = .ctrl });
    try input(&editor, .{ .delete = .none });
    try expectEditor(editor,
        \\this is a test
        \\
    );

    try editor.deinit();
}
