const std = @import("std");
const Io = std.Io;
const flash = @import("flash.zig");

const query_format = "#{pane_id}|#{pane_width}|#{pane_height}|#{cursor_x}|#{cursor_y}|#{?pane_in_mode,1,0}|#{copy_cursor_x}|#{copy_cursor_y}|#{?selection_present,1,0}|#{scroll_position}";

pub const PaneQuery = struct {
    pane_id: []const u8,
    width: u32,
    height: u32,
    cursor_x: u32,
    cursor_y: u32,
    in_mode: bool,
    copy_cursor_x: u32,
    copy_cursor_y: u32,
    selection_present: bool,
    scroll_position: u32,
};

pub fn swapPanes(allocator: std.mem.Allocator, io: Io, a: []const u8, b: []const u8) void {
    _ = run(allocator, io, &.{ "tmux", "swap-pane", "-s", a, "-t", b }, 64) catch {};
}

pub fn killSession(allocator: std.mem.Allocator, io: Io, session: []const u8) void {
    _ = run(allocator, io, &.{ "tmux", "kill-session", "-t", session }, 64) catch {};
}

pub fn launchOverlay(
    allocator: std.mem.Allocator,
    io: Io,
    bin: []const u8,
    pane: []const u8,
    width: u32,
    height: u32,
    session: []const u8,
) !void {
    var wbuf: [16]u8 = undefined;
    var hbuf: [16]u8 = undefined;
    const w = std.fmt.bufPrint(&wbuf, "{d}", .{width}) catch unreachable;
    const h = std.fmt.bufPrint(&hbuf, "{d}", .{height}) catch unreachable;
    const pane_arg = try std.fmt.allocPrint(allocator, "--pane={s}", .{pane});
    const session_arg = try std.fmt.allocPrint(allocator, "--session={s}", .{session});
    _ = run(allocator, io, &.{
        "tmux",
        "new-session",
        "-d",
        "-s",
        session,
        "-x",
        w,
        "-y",
        h,
        bin,
        pane_arg,
        session_arg,
        ";",
        "set-option",
        "-t",
        session,
        "status",
        "off",
    }, 64) catch {
        killSession(allocator, io, session);
        return error.TmuxFailed;
    };
}

pub fn query(allocator: std.mem.Allocator, io: Io, pane_id: ?[]const u8) !PaneQuery {
    const raw = if (pane_id) |id|
        try run(allocator, io, &.{ "tmux", "display-message", "-t", id, "-p", query_format }, 4096)
    else
        try run(allocator, io, &.{ "tmux", "display-message", "-p", query_format }, 4096);
    return parseQuery(raw);
}

pub fn capture(allocator: std.mem.Allocator, io: Io, q: PaneQuery) ![]u8 {
    if (!q.in_mode) {
        return run(allocator, io, &.{ "tmux", "capture-pane", "-t", q.pane_id, "-p", "-e", "-N" }, 1024 * 1024);
    }

    const start: i64 = -@as(i64, @intCast(q.scroll_position));
    const end = start + @as(i64, @intCast(q.height)) - 1;
    var start_buf: [16]u8 = undefined;
    var end_buf: [16]u8 = undefined;
    const start_arg = std.fmt.bufPrint(&start_buf, "{d}", .{start}) catch unreachable;
    const end_arg = std.fmt.bufPrint(&end_buf, "{d}", .{end}) catch unreachable;
    return run(allocator, io, &.{
        "tmux", "capture-pane", "-t", q.pane_id, "-p", "-e", "-N",
        "-S", start_arg, "-E", end_arg,
    }, 1024 * 1024);
}

pub const JumpKind = enum { enter, move, extend };

pub fn jumpKind(in_mode: bool, selection_present: bool) JumpKind {
    if (!in_mode) return .enter;
    if (selection_present) return .extend;
    return .move;
}

pub fn jump(
    allocator: std.mem.Allocator,
    io: Io,
    pane_id: []const u8,
    row: u32,
    col: u32,
    snap: PaneQuery,
    still_in_mode: bool,
    lines: []const []const u8,
) !void {
    const to = flash.cursorRights(lineAt(lines, row), col);
    const from = flash.cursorRights(lineAt(lines, snap.copy_cursor_y), snap.copy_cursor_x);
    switch (jumpKind(snap.in_mode, snap.selection_present)) {
        .enter => try enterAt(allocator, io, pane_id, row, to, 0),
        .move => {
            if (!still_in_mode) {
                try enterAt(allocator, io, pane_id, snap.copy_cursor_y, from, snap.scroll_position);
            }
            try moveDelta(allocator, io, pane_id, snap.copy_cursor_y, row, to);
        },
        .extend => {
            if (!still_in_mode) {
                try enterAt(allocator, io, pane_id, snap.copy_cursor_y, from, snap.scroll_position);
                try sendX(allocator, io, pane_id, &.{ "begin-selection" });
            }
            try moveDelta(allocator, io, pane_id, snap.copy_cursor_y, row, to);
        },
    }
}

fn lineAt(lines: []const []const u8, row: u32) []const u8 {
    if (row >= lines.len) return "";
    return lines[row];
}

fn enterAt(allocator: std.mem.Allocator, io: Io, pane_id: []const u8, row: u32, col: u32, scroll: u32) !void {
    _ = try run(allocator, io, &.{ "tmux", "copy-mode", "-t", pane_id }, 64);
    try moveN(allocator, io, pane_id, scroll, "scroll-up");
    try sendX(allocator, io, pane_id, &.{ "top-line" });
    try sendX(allocator, io, pane_id, &.{ "start-of-line" });
    try moveN(allocator, io, pane_id, row, "cursor-down");
    try gotoCol(allocator, io, pane_id, col);
}

fn moveDelta(
    allocator: std.mem.Allocator,
    io: Io,
    pane_id: []const u8,
    from_row: u32,
    to_row: u32,
    to_col: u32,
) !void {
    if (to_row > from_row) try moveN(allocator, io, pane_id, to_row - from_row, "cursor-down");
    if (to_row < from_row) try moveN(allocator, io, pane_id, from_row - to_row, "cursor-up");
    try gotoCol(allocator, io, pane_id, to_col);
}

fn gotoCol(allocator: std.mem.Allocator, io: Io, pane_id: []const u8, col: u32) !void {
    try sendX(allocator, io, pane_id, &.{ "start-of-line" });
    try moveN(allocator, io, pane_id, col, "cursor-right");
}

fn moveN(allocator: std.mem.Allocator, io: Io, pane_id: []const u8, n: u32, motion: []const u8) !void {
    if (n == 0) return;
    const count = try std.fmt.allocPrint(allocator, "{d}", .{n});
    try sendX(allocator, io, pane_id, &.{ "-N", count, motion });
}

fn sendX(allocator: std.mem.Allocator, io: Io, pane_id: []const u8, extra: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "tmux", "send-keys", "-t", pane_id, "-X" });
    try argv.appendSlice(allocator, extra);
    _ = try run(allocator, io, argv.items, 64);
}

pub fn parseQuery(raw: []const u8) !PaneQuery {
    const line = blk: {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.indexOfScalar(u8, trimmed, '\n')) |nl|
            break :blk std.mem.trim(u8, trimmed[0..nl], " \t\r");
        break :blk trimmed;
    };
    var fields: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, line, '|');
    while (it.next()) |f| {
        if (n >= fields.len) return error.InvalidQuery;
        fields[n] = std.mem.trim(u8, f, " \t");
        n += 1;
    }
    if (n < 6 or fields[0].len == 0) return error.InvalidQuery;
    return .{
        .pane_id = fields[0],
        .width = try parseU32(fields[1]),
        .height = try parseU32(fields[2]),
        .cursor_x = try parseU32(fields[3]),
        .cursor_y = try parseU32(fields[4]),
        .in_mode = try parseU32(fields[5]) != 0,
        .copy_cursor_x = if (n > 6) try parseU32(fields[6]) else 0,
        .copy_cursor_y = if (n > 7) try parseU32(fields[7]) else 0,
        .selection_present = if (n > 8) try parseU32(fields[8]) != 0 else false,
        .scroll_position = if (n > 9) try parseU32(fields[9]) else 0,
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
    const q = try parseQuery("%2|118|31|1|26|0|||0\n");
    try std.testing.expectEqualStrings("%2", q.pane_id);
    try std.testing.expectEqual(@as(u32, 118), q.width);
    try std.testing.expectEqual(@as(u32, 31), q.height);
    try std.testing.expectEqual(@as(u32, 1), q.cursor_x);
    try std.testing.expectEqual(@as(u32, 26), q.cursor_y);
    try std.testing.expectEqual(false, q.in_mode);
    try std.testing.expectEqual(@as(u32, 0), q.copy_cursor_x);
    try std.testing.expectEqual(@as(u32, 0), q.copy_cursor_y);
    try std.testing.expectEqual(false, q.selection_present);
}

test "parse query trailing empty fields" {
    const q = try parseQuery("%0|121|31|1|26|0|||\n");
    try std.testing.expectEqualStrings("%0", q.pane_id);
    try std.testing.expectEqual(@as(u32, 121), q.width);
    try std.testing.expectEqual(false, q.in_mode);
    try std.testing.expectEqual(false, q.selection_present);
}

test "parse query in copy mode" {
    const q = try parseQuery("%0|80|24|0|0|1|12|7|1");
    try std.testing.expectEqual(true, q.in_mode);
    try std.testing.expectEqual(@as(u32, 12), q.copy_cursor_x);
    try std.testing.expectEqual(@as(u32, 7), q.copy_cursor_y);
    try std.testing.expectEqual(true, q.selection_present);
    try std.testing.expectEqual(@as(u32, 0), q.scroll_position);
}

test "parse query scroll" {
    const q = try parseQuery("%0|80|24|0|0|1|12|7|0|15");
    try std.testing.expectEqual(@as(u32, 15), q.scroll_position);
}

test "jumpKind" {
    try std.testing.expectEqual(JumpKind.enter, jumpKind(false, false));
    try std.testing.expectEqual(JumpKind.enter, jumpKind(false, true));
    try std.testing.expectEqual(JumpKind.move, jumpKind(true, false));
    try std.testing.expectEqual(JumpKind.extend, jumpKind(true, true));
}


