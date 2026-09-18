const std = @import("std");
const flash = @import("flash_tmux").flash;

fn initLine(allocator: std.mem.Allocator, lines: []const []const u8, opts: flash.Opts) !flash.State {
    return flash.State.init(allocator, .{ .lines = lines, .width = 80, .cursor = .{} }, opts);
}

test "step label jump" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{"wow"};
    var state = try initLine(gpa, &lines, .{});
    defer state.deinit();

    try std.testing.expect(try state.step('w'));
    try std.testing.expectEqualStrings("w", state.pattern.items);
    try std.testing.expectEqual(@as(usize, 2), state.results.items.len);
    try std.testing.expectEqual(@as(?u8, 'a'), state.results.items[0].label);
    try std.testing.expectEqual(@as(?u8, 's'), state.results.items[1].label);

    try std.testing.expect(!try state.step('a'));
    try std.testing.expectEqual(flash.Pos{ .row = 0, .col = 0 }, state.jumped.?.pos);
}

test "step extends when next char is skipped as label" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{"wow"};
    var state = try initLine(gpa, &lines, .{});
    defer state.deinit();

    try std.testing.expect(try state.step('w'));
    for (state.results.items) |m| try std.testing.expect(m.label != 'o');

    try std.testing.expect(try state.step('o'));
    try std.testing.expectEqualStrings("wo", state.pattern.items);
    try std.testing.expect(state.jumped == null);
    try std.testing.expectEqual(@as(usize, 1), state.results.items.len);
    try std.testing.expectEqual(flash.Pos{ .row = 0, .col = 0 }, state.results.items[0].pos);
}

test "autojump single match" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{"hello"};
    var state = try initLine(gpa, &lines, .{ .autojump = true });
    defer state.deinit();

    try std.testing.expect(!try state.step('h'));
    try std.testing.expectEqual(flash.Pos{ .row = 0, .col = 0 }, state.jumped.?.pos);
}

test "cursorRights tabs and wide" {
    try std.testing.expectEqual(@as(u32, 0), flash.cursorRights("\tmodified:", 0));
    try std.testing.expectEqual(@as(u32, 1), flash.cursorRights("\tmodified:", 8));
    try std.testing.expectEqual(@as(u32, 2), flash.cursorRights("\tmodified:", 9));
    try std.testing.expectEqual(@as(u32, 3), flash.cursorRights("hello", 3));
    try std.testing.expectEqual(@as(u32, 1), flash.cursorRights("あa", 2));
    try std.testing.expectEqual(@as(u32, 2), flash.cursorRights("あa", 3));
}

test "tab expands to tabstop; label sits after match" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{"\tmodified:"};
    var state = try initLine(gpa, &lines, .{});
    defer state.deinit();

    try std.testing.expect(try state.step('m'));
    try std.testing.expectEqual(@as(usize, 1), state.results.items.len);
    try std.testing.expectEqual(@as(u32, 8), state.results.items[0].pos.col);
    try std.testing.expectEqual(@as(u32, 9), flash.labelCol(state.results.items[0], 80));
}

test "displayCol utf8 vs bytes" {
    try std.testing.expectEqual(@as(u32, 0), flash.displayCol("abc", 0));
    try std.testing.expectEqual(@as(u32, 2), flash.displayCol("abc", 2));
    const lambda_zig = "\u{03bb} zig";
    try std.testing.expectEqual(@as(u32, 2), flash.displayCol(lambda_zig, 3));
    const box = "\u{2502} dir";
    try std.testing.expectEqual(@as(u32, 2), flash.displayCol(box, 4));
}

test "esc aborts; enter jumps target" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{"wow"};
    {
        var state = try initLine(gpa, &lines, .{});
        defer state.deinit();
        try std.testing.expect(!try state.step(null));
        try std.testing.expect(state.aborted);
        try std.testing.expect(state.jumped == null);
    }
    {
        var state = try initLine(gpa, &lines, .{});
        defer state.deinit();
        try std.testing.expect(try state.step('w'));
        try std.testing.expect(!try state.step(flash.CR));
        try std.testing.expectEqual(state.target.?.pos, state.jumped.?.pos);
    }
}
