const std = @import("std");

const flash_tmux = @import("flash_tmux");
const flash = flash_tmux.flash;

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        holdError(init, err);
        return err;
    };
}

fn swapIn(init: std.process.Init, source: []const u8) void {
    const ov = init.minimal.environ.getPosix("TMUX_PANE") orelse return;
    flash_tmux.tmux.swapPanes(init.arena.allocator(), init.io, ov, source);
}

fn run(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const opts = try parseArgs(args);

    const q = try flash_tmux.tmux.query(arena, io, opts.pane);
    const pane_id = q.pane_id;
    const raw = try flash_tmux.tmux.capture(arena, io, q);
    if (opts.inspect) return printSnapshot(io, q, raw);
    const plain = try flash_tmux.sgr.strip(arena, raw);
    const dim = try flash_tmux.sgr.dim(arena, raw);
    const lines = try splitLines(arena, plain);

    const cursor: flash.Pos = if (q.in_mode)
        .{ .row = q.copy_cursor_y, .col = q.copy_cursor_x }
    else
        .{ .row = q.cursor_y, .col = q.cursor_x };

    var state = try flash.State.init(arena, .{
        .lines = lines,
        .width = q.width,
        .cursor = cursor,
    }, .{});
    defer state.deinit();

    {
        var screen = try flash_tmux.tty.Screen.enter(io);
        defer screen.restore();
        try paint(&screen, dim, &state);
        swapIn(init, pane_id);

        while (true) {
            const b = try screen.readByte();
            if (b == 0x03) break;
            if (!try state.step(b)) break;
            try paint(&screen, dim, &state);
        }
    }

    if (state.jumped) |m| {
        const now = try flash_tmux.tmux.query(arena, io, pane_id);
        try flash_tmux.tmux.jump(arena, io, pane_id, m.pos.row, m.pos.col, q, now.in_mode, lines);
    }
}

fn holdError(init: std.process.Init, err: anyerror) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch &.{};
    if (parseArgs(args)) |opts| {
        if (opts.pane) |p| swapIn(init, p);
    } else |_| {}
    const io = init.io;
    var out_buf: [1024]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stderr(), io, &out_buf);
    const w = &writer.interface;
    w.print("flash.tmux error: {s}\nargs:\n", .{@errorName(err)}) catch {};
    for (args) |a| w.print("  {s}\n", .{a}) catch {};
    w.print("press enter\n", .{}) catch {};
    w.flush() catch {};

    var in_buf: [64]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(.stdin(), io, &in_buf);
    while (reader.interface.takeByte()) |b| {
        if (b == '\n' or b == '\r' or b == 0x03) break;
    } else |_| {}
}

const Args = struct {
    pane: ?[]const u8 = null,
    inspect: bool = false,
};

fn parseArgs(args: []const []const u8) !Args {
    var out: Args = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--inspect")) {
            out.inspect = true;
        } else if (std.mem.startsWith(u8, a, "--pane=")) {
            const v = a["--pane=".len..];
            if (v.len == 0) return error.MissingPane;
            out.pane = v;
        } else if (std.mem.eql(u8, a, "--pane")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingPane;
            out.pane = args[i];
        }
    }
    return out;
}

fn printSnapshot(io: std.Io, q: flash_tmux.tmux.PaneQuery, text: []const u8) !void {
    var out_buf: [1024]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stdout(), io, &out_buf);
    const w = &writer.interface;
    try w.print(
        "pane_id={s}\nin_mode={}\ncopy_cursor={d},{d}\nscroll_position={d}\n--- capture ---\n{s}",
        .{ q.pane_id, q.in_mode, q.copy_cursor_x, q.copy_cursor_y, q.scroll_position, text },
    );
    try w.flush();
}

fn paint(screen: *flash_tmux.tty.Screen, text: []const u8, state: *flash.State) !void {
    try screen.paint(text);
    for (state.results.items) |m| {
        const lab = m.label orelse continue;
        if (m.pos.row >= state.grid.lines.len) continue;
        try screen.stamp(m.pos.row, flash.labelCol(m, state.grid.width), lab);
    }
    try screen.park(state.grid.cursor.row, state.grid.cursor.col);
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
