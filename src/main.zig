const std = @import("std");

const flash_tmux = @import("flash_tmux");
const cli = flash_tmux.args;
const overlay = flash_tmux.overlay;
const tmux = flash_tmux.tmux;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const opts = try cli.parse(args);

    if (opts.version) {
        try printVersion(init);
        return;
    }

    if (opts.inspect) {
        try inspect(init, opts);
        return;
    }

    if (opts.session == null) {
        _ = try overlay.launch(init, opts.pane);
        return;
    }

    const source = opts.pane orelse return error.MissingPane;
    overlay.run(init, source, opts.session.?) catch |err| {
        holdError(init, err);
        return err;
    };
}

fn inspect(init: std.process.Init, opts: cli.Args) !void {
    const arena = init.arena.allocator();
    const q = try tmux.query(arena, init.io, opts.pane);
    const raw = try tmux.capture(arena, init.io, q);
    try printSnapshot(init.io, q, raw);
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

fn printVersion(init: std.process.Init) !void {
    var out_buf: [64]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stdout(), init.io, &out_buf);
    const w = &writer.interface;
    try w.print("{s}\n", .{flash_tmux.version});
    try w.flush();
}

fn printSnapshot(io: std.Io, q: tmux.PaneQuery, text: []const u8) !void {
    var out_buf: [1024]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stdout(), io, &out_buf);
    const w = &writer.interface;
    try w.print(
        "pane_id={s}\nin_mode={}\ncopy_cursor={d},{d}\nscroll_position={d}\n--- capture ---\n{s}",
        .{ q.pane_id, q.in_mode, q.copy_cursor_x, q.copy_cursor_y, q.scroll_position, text },
    );
    try w.flush();
}
