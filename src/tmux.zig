const std = @import("std");
const Io = std.Io;

const query_format = "#{pane_id}|#{pane_width}|#{pane_height}|#{cursor_x}|#{cursor_y}|#{pane_in_mode}|#{copy_cursor_x}|#{copy_cursor_y}";

pub const PaneQuery = struct {
    pane_id: []const u8,
    width: u32,
    height: u32,
    cursor_x: u32,
    cursor_y: u32,
    in_mode: bool,
    copy_cursor_x: u32,
    copy_cursor_y: u32,
};

pub fn query(allocator: std.mem.Allocator, io: Io) !PaneQuery {
    const raw = try run(allocator, io, &.{ "tmux", "display-message", "-p", query_format }, 4096);
    return parseQuery(raw);
}

pub fn capture(allocator: std.mem.Allocator, io: Io, pane_id: []const u8) ![]u8 {
    return run(allocator, io, &.{ "tmux", "capture-pane", "-t", pane_id, "-p", "-N" }, 1024 * 1024);
}

pub fn parseQuery(raw: []const u8) !PaneQuery {
    const line = std.mem.trimEnd(u8, raw, "\r\n");
    var it = std.mem.splitScalar(u8, line, '|');
    const pane_id = it.next() orelse return error.InvalidQuery;
    const width = try parseU32(it.next() orelse return error.InvalidQuery);
    const height = try parseU32(it.next() orelse return error.InvalidQuery);
    const cursor_x = try parseU32(it.next() orelse return error.InvalidQuery);
    const cursor_y = try parseU32(it.next() orelse return error.InvalidQuery);
    const in_mode = try parseU32(it.next() orelse return error.InvalidQuery);
    const copy_cursor_x = try parseU32(it.next() orelse return error.InvalidQuery);
    const copy_cursor_y = try parseU32(it.next() orelse return error.InvalidQuery);
    if (it.next() != null) return error.InvalidQuery;
    if (pane_id.len == 0) return error.InvalidQuery;
    return .{
        .pane_id = pane_id,
        .width = width,
        .height = height,
        .cursor_x = cursor_x,
        .cursor_y = cursor_y,
        .in_mode = in_mode != 0,
        .copy_cursor_x = copy_cursor_x,
        .copy_cursor_y = copy_cursor_y,
    };
}

fn parseU32(s: []const u8) !u32 {
    if (s.len == 0) return 0;
    return std.fmt.parseUnsigned(u32, s, 10);
}

fn run(allocator: std.mem.Allocator, io: Io, argv: []const []const u8, stdout_limit: usize) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(stdout_limit),
        .stderr_limit = .limited(4096),
    });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.TmuxFailed,
        else => return error.TmuxFailed,
    }
    return result.stdout;
}

test "parse query" {
    const q = try parseQuery("%2|118|31|1|26|0||\n");
    try std.testing.expectEqualStrings("%2", q.pane_id);
    try std.testing.expectEqual(@as(u32, 118), q.width);
    try std.testing.expectEqual(@as(u32, 31), q.height);
    try std.testing.expectEqual(@as(u32, 1), q.cursor_x);
    try std.testing.expectEqual(@as(u32, 26), q.cursor_y);
    try std.testing.expectEqual(false, q.in_mode);
    try std.testing.expectEqual(@as(u32, 0), q.copy_cursor_x);
    try std.testing.expectEqual(@as(u32, 0), q.copy_cursor_y);
}

test "parse query in copy mode" {
    const q = try parseQuery("%0|80|24|0|0|1|12|7");
    try std.testing.expectEqual(true, q.in_mode);
    try std.testing.expectEqual(@as(u32, 12), q.copy_cursor_x);
    try std.testing.expectEqual(@as(u32, 7), q.copy_cursor_y);
}
