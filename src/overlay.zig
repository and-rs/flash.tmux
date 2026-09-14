const std = @import("std");
const flash = @import("flash.zig");
const sgr = @import("sgr.zig");
const tmux = @import("tmux.zig");
const ui = @import("ui.zig");

pub const LaunchResult = enum { started, already_active, recovered };

pub fn launch(init: std.process.Init, pane: ?[]const u8) !LaunchResult {
    const allocator = init.arena.allocator();
    const client = tmux.Client.init(allocator, init.io);
    const query = try client.query(pane);

    if (parseRef(client.overlayReference(query.pane_id) catch "")) |ref| {
        if (!client.hasSession(ref.session)) {
            client.clearOverlay(query.pane_id);
        } else if (!client.paneDead(query.pane_id)) {
            return .already_active;
        } else {
            try client.recoverOverlay(query.pane_id, ref.source, ref.session);
            return .recovered;
        }
    }

    const bin = try std.process.executablePathAlloc(init.io, allocator);
    const suffix = std.mem.trimStart(u8, query.pane_id, "%");
    const session = try std.fmt.allocPrint(allocator, "flash-overlay-{s}", .{suffix});
    return startReplica(client, bin, query, session);
}

pub fn run(init: std.process.Init, source: []const u8, session: []const u8) !void {
    var overlay = Overlay{ .init = init, .source = source, .session = session };
    defer overlay.close();

    var screen = try ui.Session.enter(init.io);
    defer screen.close();

    const allocator = init.arena.allocator();
    const client = tmux.Client.init(allocator, init.io);
    const warm = try client.query(source);
    try screen.showWarmFrame(try client.capture(warm), cursorOf(warm));
    try overlay.show();

    const snapshot = try overlay.freeze();
    const raw = try client.capture(snapshot);
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
        try self.client().showOverlay(pane, self.session, self.source);
        self.shown = true;
    }

    fn freeze(self: *Overlay) !tmux.PaneSnapshot {
        const before = try self.client().query(self.source);
        if (!before.in_mode) {
            self.owns_copy_mode = true;
        }
        const snapshot = try self.client().freeze(self.source, !before.in_mode);
        if (!snapshot.in_mode) return error.CopyModeNotEntered;
        return snapshot;
    }

    fn commit(self: *Overlay, match: flash.Match, snapshot: tmux.PaneSnapshot, lines: []const []const u8) !void {
        const tmux_client = self.client();
        const now = try tmux_client.query(snapshot.pane_id);
        try tmux_client.jump(.{
            .snapshot = snapshot,
            .target_row = match.pos.row,
            .target_col = match.pos.col,
            .still_in_mode = now.in_mode,
        }, lines);
        self.committed = true;
    }

    fn close(self: *Overlay) void {
        if (self.shown) {
            const pane = self.init.minimal.environ.getPosix("TMUX_PANE") orelse return;
            self.client().restoreOverlay(
                pane,
                self.source,
                self.session,
                self.owns_copy_mode and !self.committed,
            ) catch return;
            return;
        }
        self.client().killSession(self.session);
    }

    fn client(self: *const Overlay) tmux.Client {
        return .init(self.init.arena.allocator(), self.init.io);
    }
};

const Ref = struct { session: []const u8, source: []const u8 };

fn parseRef(raw: []const u8) ?Ref {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    const sep = std.mem.lastIndexOfScalar(u8, value, ':') orelse return null;
    if (sep == 0 or sep + 1 >= value.len) return null;
    return .{ .session = value[0..sep], .source = value[sep + 1 ..] };
}

fn startReplica(client: tmux.Client, bin: []const u8, query: tmux.PaneSnapshot, session: []const u8) !LaunchResult {
    if (client.hasSession(session)) {
        if (!client.paneDead(session)) return .already_active;
        client.killSession(session);
    }

    client.launchOverlay(bin, query.pane_id, query.width, query.height, session) catch |err| {
        client.killSession(session);
        return err;
    };
    return .started;
}

fn cursorOf(query: tmux.PaneSnapshot) flash.Pos {
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
