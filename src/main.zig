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

    if (opts.ui) {
        const source = opts.pane orelse return error.MissingPane;
        overlay.run(init, source) catch |err| {
            flash_tmux.error_screen.reportStderr(init.io, err);
            return err;
        };
        return;
    }

    _ = overlay.launch(init, opts.pane) catch |err| {
        flash_tmux.error_screen.reportStderr(init.io, err);
        return err;
    };
}

fn inspect(init: std.process.Init, opts: cli.Args) !void {
    const arena = init.arena.allocator();
    const client = tmux.Client.init(arena, init.io, tmux.debugEnabled(init));
    const q = try client.query(opts.pane);
    const raw = try client.capture(q);
    const copy = if (q.in_mode) try client.queryCopy(q.pane_id) else null;
    try printSnapshot(init.io, q, copy, raw);
}

fn printVersion(init: std.process.Init) !void {
    var out_buf: [64]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stdout(), init.io, &out_buf);
    const w = &writer.interface;
    try w.print("{s}\n", .{flash_tmux.version});
    try w.flush();
}

fn printSnapshot(io: std.Io, q: tmux.PaneSnapshot, copy: ?tmux.CopyState, text: []const u8) !void {
    var out_buf: [1024]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stdout(), io, &out_buf);
    const w = &writer.interface;
    try w.print("pane_id={s}\nin_mode={}\ncursor={d},{d}\n", .{ q.pane_id, q.in_mode, q.cursor_x, q.cursor_y });
    if (copy) |state| try w.print("copy_cursor={d},{d}\nscroll_position={d}\n", .{
        state.cursor.x,
        state.cursor.y,
        state.cursor.scroll,
    });
    try w.print("--- capture ---\n{s}", .{text});
    try w.flush();
}
