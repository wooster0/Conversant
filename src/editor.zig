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

pub const Line = ArrayList(u21);

pub const Editor = struct {
    const Self = @This();

    /// The content to be edited.
    ///
    /// There is an important performance aspect of separating all the content by lines.
    /// We frequently do insert operations on the individual `Line`s that take O(n) because
    /// we have to copy and move all data after the insert index.
    /// These operations are very fast in our case because we separate all the content
    /// and so there isn't a lot to copy.
    ///
    /// But if we instead choose to have all content in one big `Line` and we have a file
    /// of 100,000 lines and we insert a character after the 50,000th character, the operation
    /// will take quite long because all data after that point has to copied and moved
    /// to make space for that one new character.
    ///
    /// In addition, to properly draw the lines, we would have to split up the content into separate lines
    /// on the fly all the time.
    /// In our case, we don't have to do any of that.
    lines: ArrayList(Line),
    cursor: Cursor = .{},

    pub fn new(allocator: mem.Allocator) !Self {
        try background.setTimelyBackground();

        // Start with one, empty line
        var lines = try ArrayList(Line).initCapacity(allocator, 1);
        lines.appendAssumeCapacity(Line.init(allocator));

        return Self{ .lines = lines };
    }

    pub fn openFile(allocator: mem.Allocator, path: [:0]const u8) !Self {
        try background.setTimelyBackground();

        const file = try fs.cwd().openFileZ(path, .{});

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
        }
    }

    fn handleEvents(self: *Self, allocator: mem.Allocator) !?Action {
        const read_input = (try terminal.read()) orelse return null;

        return self.cursor.handleInput(allocator, &self.lines, read_input);
    }

    fn draw(self: Self) !void {
        try terminal.control.clear();
        try terminal.cursor.reset();

        const padding = std.fmt.count("{}", .{self.lines.items.len});
        const line_number_count = @minimum(terminal.size.height - 1, self.lines.items.len);

        var row: usize = 0;
        while (row < line_number_count) : (row += 1) {
            const line_number = row + 1;
            const line = self.lines.items[row];
            try drawLine(line_number, padding, line);
        }

        const offset = Position{ .row = 0, .column = @intCast(u16, padding) + 1 };

        try self.cursor.draw(self.lines, offset);

        try terminal.flush();
    }

    /// Draws a row's line: the line number followed by the line content.
    fn drawLine(line_number: usize, padding: usize, line: Line) !void {
        try terminal.print(
            "{[0]:>[1]}│",
            .{
                line_number,
                padding,
            },
        );

        for (line.items) |char| {
            var bytes: [4]u8 = undefined;
            const byte_count = try unicode.utf8Encode(char, &bytes);
            try terminal.write(bytes[0..byte_count]);
        }

        try terminal.writeByte('\r'); // Go to BOL
        try terminal.writeByte('\n'); // Go to next line
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
    }
}

/// Inputs and emulates input to the editor.
fn input(editor: *Editor, input_to_emulate: terminal.input.Input) !void {
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

    try input(&editor, .down);
    try expectEqual(Position{ .row = 1, .column = 0 }, editor.cursor.position);

    try input(&editor, .{ .right = .none });
    try expectEqual(Position{ .row = 1, .column = 1 }, editor.cursor.position);

    try input(&editor, .{ .end = .none });
    try expectEqual(Position{ .row = 1, .column = 5 }, editor.cursor.position);

    try input(&editor, .down);
    try expectEqual(Position{ .row = 2, .column = 0 }, editor.cursor.position);

    try input(&editor, .down);
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

    try input(&editor, .down);
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

    try input(&editor, .down);
    try input(&editor, .down);
    try input(&editor, .down);
    try input(&editor, .down);

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

    try input(&editor, .up);
    try input(&editor, .{ .delete = .ctrl });
    try expectEditor(editor,
        \\hello world
        \\hello editor
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

    try input(&editor, .down);
    try input(&editor, .{ .right = .none });
    try input(&editor, .{ .right = .none });
    try input(&editor, .{ .backspace = .none });
    try input(&editor, .{ .backspace = .none });
    try expectEqual(Position{ .row = 1, .column = 0 }, editor.cursor.position);
    try expectEditor(editor,
        \\
        \\editor
    );

    try editor.deinit();
}
