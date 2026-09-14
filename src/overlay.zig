const std = @import("std");
const flash = @import("flash.zig");
const sgr = @import("sgr.zig");
const tmux = @import("tmux.zig");
const ui = @import("ui.zig");

pub const LaunchResult = enum { started, already_active, recovered };

pub fn launch(init: std.process.Init, pane: ?[]const u8) !LaunchResult {
    const allocator = init.arena.allocator();
    const query = try tmux.query(allocator, init.io, pane);

    if (parseRef(tmux.getOverlay(allocator, init.io, query.pane_id) catch "")) |ref| {
        if (!tmux.hasSession(allocator, init.io, ref.session)) {
            tmux.clearOverlay(allocator, init.io, query.pane_id);
        } else if (!tmux.paneDead(allocator, init.io, query.pane_id)) {
            return .already_active;
        } else {
            try tmux.recoverOverlay(allocator, init.io, query.pane_id, ref.source, ref.session);
            return .recovered;
        }
    }

    const bin = try std.process.executablePathAlloc(init.io, allocator);
    const suffix = std.mem.trimStart(u8, query.pane_id, "%");
    const session = try std.fmt.allocPrint(allocator, "flash-overlay-{s}", .{suffix});
    return startReplica(allocator, init.io, bin, query, session);
}

pub fn run(init: std.process.Init, source: []const u8, session: []const u8) !void {
    var overlay = Overlay{ .init = init, .source = source, .session = session };
    defer overlay.close();

    var screen = try ui.Session.enter(init.io);
    defer screen.close();

    const allocator = init.arena.allocator();
    const warm = try tmux.query(allocator, init.io, source);
    try screen.showWarmFrame(try tmux.capture(allocator, init.io, warm), cursorOf(warm));
    try overlay.show();

    const snapshot = try overlay.freeze();
    const raw = try tmux.capture(allocator, init.io, snapshot);
    const plain = try sgr.strip(allocator, raw);
    const lines = try splitLines(allocator, plain);
    const dim = try sgr.dim(allocator, raw);

    switch (try screen.run(allocator, dim, .{
        .lines = lines,
        .width = snapshot.width,
        .cursor = cursorOf(snapshot),
    })) {
        .abort => {},
        .jump => |match| try overlay.commit(match, snapshot, lines),
    }
}

const Overlay = struct {
    init: std.process.Init,
    source: []const u8,
    session: []const u8,
    owns_copy_mode: bool = false,
    committed: bool = false,
    shown: bool = false,

    fn show(self: *Overlay) !void {
        const pane = self.init.minimal.environ.getPosix("TMUX_PANE") orelse return error.MissingOverlayPane;
        try tmux.showOverlay(self.init.arena.allocator(), self.init.io, pane, self.session, self.source);
        self.shown = true;
    }

    fn freeze(self: *Overlay) !tmux.PaneQuery {
        const before = try tmux.query(self.init.arena.allocator(), self.init.io, self.source);
        if (!before.in_mode) {
            self.owns_copy_mode = true;
        }
        const snapshot = try tmux.freeze(self.init.arena.allocator(), self.init.io, self.source, !before.in_mode);
        if (!snapshot.in_mode) return error.CopyModeNotEntered;
        return snapshot;
    }

    fn commit(self: *Overlay, match: flash.Match, snapshot: tmux.PaneQuery, lines: []const []const u8) !void {
        const now = try tmux.query(self.init.arena.allocator(), self.init.io, snapshot.pane_id);
        try tmux.jump(self.init.arena.allocator(), self.init.io, snapshot.pane_id, match.pos.row, match.pos.col, snapshot, now.in_mode, lines);
        self.committed = true;
    }

    fn close(self: *Overlay) void {
        if (self.shown) {
            const pane = self.init.minimal.environ.getPosix("TMUX_PANE") orelse return;
            tmux.restoreOverlay(
                self.init.arena.allocator(),
                self.init.io,
                pane,
                self.source,
                self.session,
                self.owns_copy_mode and !self.committed,
            ) catch return;
            return;
        }
        tmux.killSession(self.init.arena.allocator(), self.init.io, self.session);
    }
};

const Ref = struct { session: []const u8, source: []const u8 };

fn parseRef(raw: []const u8) ?Ref {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    const sep = std.mem.lastIndexOfScalar(u8, value, ':') orelse return null;
    if (sep == 0 or sep + 1 >= value.len) return null;
    return .{ .session = value[0..sep], .source = value[sep + 1 ..] };
}

fn startReplica(allocator: std.mem.Allocator, io: std.Io, bin: []const u8, query: tmux.PaneQuery, session: []const u8) !LaunchResult {
    if (tmux.hasSession(allocator, io, session)) {
        if (!tmux.paneDead(allocator, io, session)) return .already_active;
        tmux.killSession(allocator, io, session);
    }

    tmux.launchOverlay(allocator, io, bin, query.pane_id, query.width, query.height, session) catch |err| {
        tmux.killSession(allocator, io, session);
        return err;
    };
    return .started;
}

fn cursorOf(query: tmux.PaneQuery) flash.Pos {
    return if (query.in_mode)
        .{ .row = query.copy_cursor_y, .col = query.copy_cursor_x }
    else
        .{ .row = query.cursor_y, .col = query.cursor_x };
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    if (trimmed.len == 0) return &.{};
    var count: usize = 1;
    for (trimmed) |byte| {
        if (byte == '\n') count += 1;
    }
    const lines = try allocator.alloc([]const u8, count);
    var index: usize = 0;
    var iterator = std.mem.splitScalar(u8, trimmed, '\n');
    while (iterator.next()) |line| : (index += 1) lines[index] = line;
    return lines;
}
