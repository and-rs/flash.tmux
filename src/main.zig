const std = @import("std");

const flash_tmux = @import("flash_tmux");
const flash = flash_tmux.flash;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const pane_arg = try parsePane(args);

    const q = try flash_tmux.tmux.query(arena, io, pane_arg);
    const pane_id = pane_arg orelse q.pane_id;
    const text = try flash_tmux.tmux.capture(arena, io, pane_id);
    const lines = try splitLines(arena, text);

    var state = try flash.State.init(arena, .{
        .lines = lines,
        .width = q.width,
        .cursor = .{ .row = q.cursor_y, .col = q.cursor_x },
    }, .{});
    defer state.deinit();

    {
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

    if (state.jumped) |m| {
        try flash_tmux.tmux.jump(arena, io, pane_id, m.pos.row, m.pos.col);
    }
}

fn parsePane(args: []const []const u8) !?[]const u8 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--pane")) {
            i += 1;
            if (i >= args.len) return error.MissingPane;
            return args[i];
        }
    }
    return null;
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
