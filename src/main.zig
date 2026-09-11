const std = @import("std");

const flash_tmux = @import("flash_tmux");
const flash = flash_tmux.flash;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const opts = try parseArgs(args);

    if (opts.inspect) {
        try inspect(init, opts);
        return;
    }

    if (opts.session == null) {
        try launch(init, opts.pane);
        return;
    }

    const source = opts.pane orelse return error.MissingPane;
    var overlay = Overlay{
        .init = init,
        .source = source,
        .session = opts.session.?,
    };
    defer overlay.close();

    runUi(init, opts, &overlay) catch |err| {
        overlay.reveal();
        holdError(init, err);
        return err;
    };
}

const Overlay = struct {
    init: std.process.Init,
    source: []const u8,
    session: []const u8,
    shown: bool = false,

    fn reveal(self: *Overlay) void {
        if (self.shown) return;
        swapIn(self.init, self.source);
        self.shown = true;
    }

    fn close(self: *Overlay) void {
        if (self.shown) {
            swapIn(self.init, self.source);
            self.shown = false;
        }
        flash_tmux.tmux.killSession(self.init.arena.allocator(), self.init.io, self.session);
    }
};

fn swapIn(init: std.process.Init, source: []const u8) void {
    const ov = init.minimal.environ.getPosix("TMUX_PANE") orelse return;
    flash_tmux.tmux.swapPanes(init.arena.allocator(), init.io, ov, source);
}

fn launch(init: std.process.Init, pane: ?[]const u8) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const q = try flash_tmux.tmux.query(arena, io, pane);
    const bin = try std.process.executablePathAlloc(io, arena);
    const session = try std.fmt.allocPrint(arena, "flash{d}", .{std.posix.system.getpid()});
    try flash_tmux.tmux.launchOverlay(arena, io, bin, q.pane_id, q.width, q.height, session);
}

fn inspect(init: std.process.Init, opts: Args) !void {
    const arena = init.arena.allocator();
    const q = try flash_tmux.tmux.query(arena, init.io, opts.pane);
    const raw = try flash_tmux.tmux.capture(arena, init.io, q);
    try printSnapshot(init.io, q, raw);
}

fn runUi(init: std.process.Init, opts: Args, overlay: *Overlay) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const q = try flash_tmux.tmux.query(arena, io, opts.pane);
    const pane_id = q.pane_id;
    const raw = try flash_tmux.tmux.capture(arena, io, q);
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
        overlay.reveal();

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
    session: ?[]const u8 = null,
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
        } else if (std.mem.startsWith(u8, a, "--session=")) {
            const v = a["--session=".len..];
            if (v.len == 0) return error.MissingSession;
            out.session = v;
        } else if (std.mem.eql(u8, a, "--session")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingSession;
            out.session = args[i];
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
