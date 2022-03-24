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

const Cursor = @import("editor/cursor.zig").Cursor;
const background = @import("editor/background.zig");

const terminal = @import("terminal.zig");
const Position = @import("main.zig").Position;

pub const Action = enum { exit };

pub const Editor = struct {
    const Self = @This();

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
    lines: ArrayList(ArrayList(u8)),
    cursor: Cursor = .{},

    pub fn new(allocator: mem.Allocator) !Self {
        try background.setTimelyBackground();

        // Start with one, empty line
        var lines = try ArrayList(ArrayList(u8)).initCapacity(allocator, 1);
        lines.appendAssumeCapacity(ArrayList(u8).init(allocator));

        return Self{ .lines = lines };
    }

    pub fn openFile(allocator: mem.Allocator, path: [:0]const u8) !Self {
        try background.setTimelyBackground();

        const file = try fs.cwd().openFileZ(path, .{});

        var lines = ArrayList(ArrayList(u8)).init(allocator);
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
        const input = try terminal.input.read();

        return self.cursor.handleKey(allocator, &self.lines, input);
    }

    fn draw(self: Self) !void {
        try terminal.control.clear();
        try terminal.cursor.reset();

        const padding = std.fmt.count("{}", .{self.lines.items.len});
        const line_number_count = @minimum(terminal.size.height - 1, self.lines.items.len);

        var row: usize = 0;
        while (row < line_number_count) : (row += 1) {
            const line_number = row + 1;
            const line = self.lines.items[row].items;
            try drawLine(line_number, padding, line);
        }

        const offset = Position{ .row = 0, .column = @intCast(u16, padding) + 1 };

        try self.cursor.draw(self.lines, offset);

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
};

const testing = std.testing;

fn getEditor(content: []const u8) !Editor {
    const allocator = testing.allocator_instance.allocator();

    var lines = ArrayList(ArrayList(u8)).init(allocator);
    var line_iterator = mem.split(u8, content, "\n");
    while (line_iterator.next()) |line| {
        var allocatedLine = try ArrayList(u8).initCapacity(allocator, line.len);
        allocatedLine.appendSliceAssumeCapacity(line);

        try lines.append(allocatedLine);
    }

    return Editor{ .lines = lines };
}

const expect = testing.expect;

fn expectEditor(editor: Editor, expected: []const u8) !void {
    var index: usize = 0;
    var line_iterator = mem.split(u8, expected, "\n");
    while (line_iterator.next()) |line| : (index += 1) {
        const expected_line = line;
        const actual_line = editor.lines.items[index].items;
        try expect(mem.eql(u8, expected_line, actual_line));
    }
}

fn press(editor: *Editor, key: terminal.input.Key) !void {
    const allocator = testing.allocator_instance.allocator();

    try expect((try editor.cursor.handleKey(allocator, &editor.lines, key)) == null);
}

const expectEqual = testing.expectEqual;

test "insertion" {
    var editor = try getEditor(
        \\hello world
    );

    try press(&editor, .{ .char = 'A' });
    try press(&editor, .{ .char = 'B' });
    try press(&editor, .{ .char = 'C' });
    try expectEqual(Position{ .row = 0, .column = 3 }, editor.cursor.position);
    try expectEditor(editor,
        \\ABChello world
    );

    try press(&editor, .{ .right = .none });
    try press(&editor, .{ .right = .none });
    try press(&editor, .{ .right = .none });
    try press(&editor, .{ .char = 'D' });
    try press(&editor, .{ .char = 'E' });
    try press(&editor, .{ .char = 'F' });
    try expectEqual(Position{ .row = 0, .column = 9 }, editor.cursor.position);
    try expectEditor(editor,
        \\ABChelDEFlo world
    );

    try press(&editor, .{ .end = .none });
    try press(&editor, .{ .char = '1' });
    try expectEqual(Position{ .row = 0, .column = 18 }, editor.cursor.position);
    try expectEditor(editor,
        \\ABChelDEFlo world1
    );

    try editor.deinit();
}

test "cursor movement" {
    var editor = try getEditor(
        \\
        \\hello
        \\
        \\world
    );

    try press(&editor, .down);
    try expectEqual(Position{ .row = 1, .column = 0 }, editor.cursor.position);

    try press(&editor, .{ .right = .none });
    try expectEqual(Position{ .row = 1, .column = 1 }, editor.cursor.position);

    try press(&editor, .{ .end = .none });
    try expectEqual(Position{ .row = 1, .column = 5 }, editor.cursor.position);

    try press(&editor, .down);
    try expectEqual(Position{ .row = 2, .column = 0 }, editor.cursor.position);

    try press(&editor, .down);
    try expectEqual(Position{ .row = 3, .column = 5 }, editor.cursor.position);

    try press(&editor, .{ .home = .ctrl });
    try expectEqual(Position{ .row = 0, .column = 0 }, editor.cursor.position);

    try press(&editor, .{ .end = .ctrl });
    try expectEqual(Position{ .row = 3, .column = 5 }, editor.cursor.position);

    try editor.deinit();
}

test "removal" {
    var editor = try getEditor(
        \\
        \\hello world
        \\
    );

    try press(&editor, .{ .backspace = .none });
    try expectEqual(Position{ .row = 0, .column = 0 }, editor.cursor.position);

    try press(&editor, .{ .delete = .none });
    try expectEqual(Position{ .row = 0, .column = 0 }, editor.cursor.position);

    try press(&editor, .{ .delete = .none });
    try press(&editor, .{ .delete = .none });
    try expectEqual(Position{ .row = 0, .column = 0 }, editor.cursor.position);
    try expectEditor(editor,
        \\llo world
        \\
    );

    try press(&editor, .{ .end = .ctrl });
    try press(&editor, .{ .backspace = .none });
    try expectEqual(Position{ .row = 0, .column = 9 }, editor.cursor.position);
    try press(&editor, .{ .backspace = .none });
    try press(&editor, .{ .backspace = .none });
    try expectEqual(Position{ .row = 0, .column = 7 }, editor.cursor.position);
    try expectEditor(editor,
        \\llo wor
    );

    try editor.deinit();
}
