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
const heap = std.heap;

const app_name = @import("main.zig").app_name;
const Cursor = @import("editor/cursor.zig").Cursor;
const background = @import("editor/background.zig");
const terminal = @import("terminal.zig");
const Position = @import("main.zig").Position;

/// A Unicode codepoint that, when required, can be decoded to bytes on the fly.
pub const Char = u21;

pub const Line = ArrayList(Char);

/// Returns whether or not the given character is full-width.
/// 'Ａ' is a full-width character.
/// 'A' is a half-width character.
pub fn isFullWidthChar(char: Char) !bool {
    switch (char) {
        0xFF60...0xFF9F => return false, // Half-width katakana
        else => {
            // Most of the time this check works pretty well for many if not most languages,
            // including Japanese (excluding half-width katakana which is handled above),
            // Korean, Chinese, European languages etc.
            return (try unicode.utf8CodepointSequenceLength(char)) >= 3;
        },
    }
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
    /// The path of the file we're editing.
    path: ?[:0]const u8,
    watch: ?Watch,

    /// Sets the terminal's title indicating the file that is currently edited.
    fn setTitle(file_name: []const u8) !void {
        try terminal.control.setTitle("{s} - {s}", .{ file_name, app_name });
    }

    pub fn new(allocator: mem.Allocator) !Self {
        try background.setTimelyBackground();

        // Start with one, empty line
        var lines = try ArrayList(Line).initCapacity(allocator, 1);
        lines.appendAssumeCapacity(Line.init(allocator));

        // To distinguish from any possible real file names, this "file name" starts with a forward slash
        // which is illegal on most systems
        try setTitle("/new file/");

        return Self{ .lines = lines, .path = null, .watch = null };
    }

    /// This is used to track changes to the currently edited file.
    const Watch = struct {
        inotify_file_descriptor: i32,
        watch_descriptor: i32,

        fn init(path: [:0]const u8) !Watch {
            const inotify_file_descriptor = try std.os.inotify_init1(0);

            const watch_descriptor = try std.os.inotify_add_watchZ(inotify_file_descriptor, path, std.os.linux.IN.CLOSE_WRITE);

            try terminal.input.addPollFileDescriptor(inotify_file_descriptor);

            return Watch{ .inotify_file_descriptor = inotify_file_descriptor, .watch_descriptor = watch_descriptor };
        }

        fn deinit(self: Watch) void {
            std.os.inotify_rm_watch(self.inotify_file_descriptor, self.watch_descriptor);
            std.os.close(self.inotify_file_descriptor);
        }
    };

    fn readFileLines(allocator: mem.Allocator, path: [:0]const u8) !ArrayList(Line) {
        return readUTF8FileLines(allocator, path) catch |err| {
            switch (err) {
                error.Utf8InvalidStartByte,
                error.EndOfStream,
                error.Utf8ExpectedContinuation,
                error.Utf8OverlongEncoding,
                error.Utf8EncodesSurrogateHalf,
                error.Utf8CodepointTooLarge,
                => {
                    // TODO: open in binary mode
                    unreachable;
                },
                else => return err,
            }
        };
    }

    fn readUTF8FileLines(allocator: mem.Allocator, path: [:0]const u8) !ArrayList(Line) {
        const file = try fs.cwd().openFileZ(path, .{});
        defer file.close();

        const file_reader = file.reader();

        var lines = ArrayList(Line).init(allocator);
        var line = Line.init(allocator);
        while (true) {
            const first_byte = file_reader.readByte() catch |err| {
                if (err == error.EndOfStream) {
                    try lines.append(line);
                    break;
                }
                return err;
            };
            // Find out how many bytes this codepoint takes, read that many bytes,
            // and then decode the bytes to a Unicode character.
            const codepoint_length = try unicode.utf8ByteSequenceLength(first_byte);
            switch (codepoint_length) {
                // ASCII
                1 => {
                    if (first_byte == '\n') {
                        try lines.append(line);
                        line = Line.init(allocator);
                    } else {
                        try line.append(@as(Char, first_byte));
                    }
                },
                // All others are non-ASCII and if any of these `readByte`s
                // reach the end of the stream, it means we have invalid UTF-8.
                2 => {
                    var bytes = [2]u8{ first_byte, try file_reader.readByte() };
                    try line.append(try unicode.utf8Decode2(&bytes));
                },
                3 => {
                    var bytes = [3]u8{ first_byte, try file_reader.readByte(), try file_reader.readByte() };
                    try line.append(try unicode.utf8Decode3(&bytes));
                },
                4 => {
                    var bytes = [4]u8{ first_byte, try file_reader.readByte(), try file_reader.readByte(), try file_reader.readByte() };
                    try line.append(try unicode.utf8Decode4(&bytes));
                },
                else => unreachable,
            }
        }
        return lines;
    }

    pub fn openFile(allocator: mem.Allocator, path: [:0]const u8) !Self {
        try background.setTimelyBackground();

        const lines = try readFileLines(allocator, path);

        try setTitle(path);

        const watch = try Watch.init(path);

        return Self{ .lines = lines, .path = path, .watch = watch };
    }

    pub fn deinit(self: *Self) !void {
        try background.resetTimelyBackground();
        for (self.lines.items) |line|
            line.deinit();
        self.lines.deinit();
        if (self.watch) |watch|
            watch.deinit();
    }

    /// This starts the main loop where drawing and updating of the editor happens.
    pub fn run(self: *Self, allocator: mem.Allocator) !void {
        while (true) {
            try self.draw();
            if (try self.update(allocator))
                break;
        }
    }

    /// Updates and returns whether or not to end the loop.
    fn update(self: *Self, allocator: mem.Allocator) !bool {
        if (try self.handleEvents(allocator)) |action|
            switch (action) {
                .exit => return true,
            };

        self.row_offset = std.math.clamp(
            self.row_offset,
            self.cursor.position.row -| (terminal.size.height -| 1),
            self.cursor.position.row,
        );

        return false;
    }

    fn handleEvents(self: *Self, allocator: mem.Allocator) !?enum { exit } {
        const polled_input = (try terminal.input.poll()) orelse return null;

        // All input related to moving the cursor and editing using the cursor is handled
        // by the cursor.
        const input_status = try self.cursor.handleInput(allocator, &self.lines, polled_input);

        if (input_status == .unhandled)
            // The input wasn't cursor-related
            switch (read_input) {
                .ctrl_s => unreachable,
                .esc => return .exit,
                .readable_file_descriptor => |file_descriptor| {
                    // Read a file notification event
                    var buffer: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
                    var byte_count = try std.os.read(file_descriptor, &buffer);

                    var index: usize = 0;
                    while (index < byte_count) {
                        var inotify_event = @ptrCast(*std.os.linux.inotify_event, @alignCast(@alignOf(std.os.linux.inotify_event), &buffer[index]));

                        index += @sizeOf(std.os.linux.inotify_event) + inotify_event.len;

                        if (inotify_event.mask & std.os.linux.IN.CLOSE_WRITE != 0) {
                            // The file has been modified externally, reload it
                            for (self.lines.items) |line|
                                line.deinit();
                            self.lines.deinit();
                            self.lines = try readFileLines(allocator, self.path.?);
                            self.cursor.correctPosition(self.lines.items);
                        }
                    }

                    return null;
                },
                else => unreachable,
            };
        return null;
    }

    fn draw(self: Self) !void {
        try terminal.control.clear();
        try terminal.cursor.reset();

        const lines = self.lines.items[self.row_offset..@minimum(self.lines.items.len, @minimum(self.lines.items.len, terminal.size.height) + self.row_offset)];

        const max_line_number_width = @intCast(u16, std.fmt.count("{}|", .{lines.len + self.row_offset}));

        if (terminal.size.width <= max_line_number_width)
            // There are certain limits at which we refuse to draw anything.
            // This happens with absurd terminal sizes.
            return;

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
            const char_width: u16 = if (try isFullWidthChar(char)) 2 else 1;
            if ((try isFullWidthChar(char)) and line_width + char_width >= terminal.size.width) {
                if (!is_last_line)
                    try terminal.cursor.setToBeginningOfNextLine();
                var space_count = max_line_number_width;
                try terminal.writeByteNTimes(' ', space_count);
                line_width = space_count;

                wrap_count += 1;
            }

            try terminal.writeChar(char);
            line_width += char_width;

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

    return Editor{ .lines = lines, .path = null, .watch = null };
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
fn input(editor: *Editor, input_to_emulate: terminal.input.Input) !void {
    const allocator = testing.allocator_instance.allocator();

    try expect((try editor.cursor.handleInput(allocator, &editor.lines, input_to_emulate)) == .handled);
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

test "Unicode" {
    const content =
        \\𒀀𒀁𒀂𒀃𒀄𒀅𒀆𒀇
        \\hello world
        \\𒀈
        \\hello editor
        \\𒀉𒀊𒀋𒀌𒀍𒀎𒀏
        \\
        \\このエディターはUnicodeに対応している。
        \\åäöÅÄÖ
    ;

    var editor = try getEditor(content);
    try expectEditor(editor, content);

    const allocator = testing.allocator_instance.allocator();

    try fs.cwd().writeFile("unicode-test", content);

    const lines = try Editor.readFileLines(allocator, "unicode-test");
    for (lines.items) |line, index|
        try expect(mem.eql(Char, line.items, editor.lines.items[index].items));

    for (lines.items) |line|
        line.deinit();
    lines.deinit();

    try fs.cwd().deleteFile("unicode-test");
    try editor.deinit();

    try expectEqual(false, try isFullWidthChar('A'));
    try expectEqual(true, try isFullWidthChar('あ'));
    try expectEqual(false, try isFullWidthChar('Z'));
    try expectEqual(true, try isFullWidthChar('〜'));
    try expectEqual(false, try isFullWidthChar('#'));
    try expectEqual(true, try isFullWidthChar('字'));
    try expectEqual(false, try isFullWidthChar('Å'));
    try expectEqual(true, try isFullWidthChar('𒀇'));
    try expectEqual(false, try isFullWidthChar('ｱ'));
    try expectEqual(true, try isFullWidthChar('𒀈'));
    try expectEqual(false, try isFullWidthChar('｡'));
    try expectEqual(true, try isFullWidthChar('Ａ'));
    try expectEqual(false, try isFullWidthChar('ﾟ'));
    try expectEqual(true, try isFullWidthChar('ㄱ'));
    try expectEqual(false, try isFullWidthChar(' '));
    try expectEqual(true, try isFullWidthChar('차'));
}
