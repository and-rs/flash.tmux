const std = @import("std");

const flash_tmux = @import("flash_tmux");
const flash = flash_tmux.flash;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const q = try flash_tmux.tmux.query(arena, io);
    const text = try flash_tmux.tmux.capture(arena, io, q.pane_id);
    const lines = try splitLines(arena, text);

    var state = try flash.State.init(arena, .{
        .lines = lines,
        .width = q.width,
        .cursor = .{ .row = q.cursor_y, .col = q.cursor_x },
    }, .{});
    defer state.deinit();

    var screen = try flash_tmux.tty.Screen.enter(io);
    defer screen.restore();
    try paint(&screen, text, &state);

    while (true) {
        const b = try screen.readByte();
        if (b == 0x03) break;
        if (!try state.step(b)) break;
        try paint(&screen, text, &state);
    }
}

fn paint(screen: *flash_tmux.tty.Screen, text: []const u8, state: *flash.State) !void {
    try screen.paint(text);
    for (state.results.items) |m| {
        const lab = m.label orelse continue;
        if (m.pos.row >= state.grid.lines.len) continue;
        try screen.stamp(m.pos.row, flash.labelCol(m, state.grid.width), lab);
    }
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    if (trimmed.len == 0) return &.{};
    var n: usize = 1;
    for (trimmed) |c| {
        if (c == '\n') n += 1;
    }
    const lines = try allocator.alloc([]const u8, n);
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| : (i += 1) lines[i] = line;
    return lines;
}
