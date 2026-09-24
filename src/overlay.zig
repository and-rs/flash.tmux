const std = @import("std");
const builtin = @import("builtin");
const error_screen = @import("error.zig");
const flash = @import("flash.zig");
const sgr = @import("sgr.zig");
const tmux = @import("tmux.zig");
const ui = @import("ui.zig");

pub const LaunchResult = enum { started, already_active, recovered };

pub fn launch(init: std.process.Init, pane: ?[]const u8) !LaunchResult {
    const allocator = init.arena.allocator();
    const client = tmux.Client.init(allocator, init.io, tmux.debugEnabled(init));
    const query = try client.query(pane);
    var recovered = false;
    if (parseRef(try client.overlayReference(query.pane_id))) |ref| {
        try client.restore(query.pane_id, ref.owns_copy_mode, ref.refresh_was_active);
        recovered = true;
    }
    const raw = client.capture(query) catch |err| {
        if (recovered) return .recovered;
        return err;
    };
    const cursor = try frameCursor(client, query);
    const dimmed = try sgr.dim(allocator, raw);
    const frame_path = try writeFrame(init, query.pane_id, dimmed);
    defer std.Io.Dir.deleteFileAbsolute(init.io, frame_path) catch {};
    const bin = try std.process.executablePathAlloc(init.io, allocator);
    const log_path = init.minimal.environ.getPosix("FLASH_TMUX_LOG") orelse "/tmp/flash.tmux.log";
    client.launchPopup(bin, query, frame_path, cursor, log_path) catch |err| {
        if (recovered) return .recovered;
        return err;
    };
    return .started;
}

pub fn run(init: std.process.Init, source: []const u8, frame_path: ?[]const u8, cursor: ?flash.Pos) !void {
    redirectStderr(init);
    var overlay = Overlay{ .init = init, .source = source };
    const client = tmux.Client.init(init.arena.allocator(), init.io, tmux.debugEnabled(init));
    const prepared = if (frame_path) |path| try readFrame(init, path) else null;

    var screen = if (prepared) |text| blk: {
        const parked = cursor orelse return error.MissingCursor;
        break :blk ui.Session.present(init.io, text, .{ .row = parked.row, .col = parked.col }) catch |err| {
            overlay.cleanup() catch |cleanup_err| error_screen.reportStderr(init.io, cleanup_err);
            return err;
        };
    } else ui.Session.enter(init.io) catch |err| {
        overlay.cleanup() catch |cleanup_err| error_screen.reportStderr(init.io, cleanup_err);
        return err;
    };
    if (frame_path) |path| std.Io.Dir.deleteFileAbsolute(init.io, path) catch {};

    if (client.overlayReference(source)) |raw_ref| {
        if (parseRef(raw_ref)) |ref| client.restore(source, ref.owns_copy_mode, ref.refresh_was_active) catch |err| {
            screen.close();
            handleFailure(init, &overlay, err) catch |handled_err| return handled_err;
            unreachable;
        };
    } else |err| {
        screen.close();
        handleFailure(init, &overlay, err) catch |handled_err| return handled_err;
        return;
    }

    const allocator = init.arena.allocator();
    const Prepared = struct {
        outcome: ui.Outcome,
        frozen: tmux.FrozenFrame,
        lines: []const []const u8,
    };
    const prepared_ui: Prepared = blk: {
        const warm = client.query(source) catch |err| {
            screen.close();
            handleFailure(init, &overlay, err) catch |handled_err| return handled_err;
            unreachable;
        };
        if (prepared == null) {
            const warm_raw = client.capture(warm) catch |err| {
                screen.close();
                handleFailure(init, &overlay, err) catch |handled_err| return handled_err;
                unreachable;
            };
            screen.showWarmFrame(warm_raw) catch |err| {
                screen.close();
                handleFailure(init, &overlay, err) catch |handled_err| return handled_err;
                unreachable;
            };
        }
        const frozen_frame = overlay.freeze(warm) catch |err| {
            screen.close();
            handleFailure(init, &overlay, err) catch |handled_err| return handled_err;
            unreachable;
        };
        const plain = sgr.strip(allocator, frozen_frame.raw) catch |err| {
            screen.close();
            handleFailure(init, &overlay, err) catch |handled_err| return handled_err;
            unreachable;
        };
        const visible_lines = splitLines(allocator, plain) catch |err| {
            screen.close();
            handleFailure(init, &overlay, err) catch |handled_err| return handled_err;
            unreachable;
        };
        const dim = sgr.dim(allocator, frozen_frame.raw) catch |err| {
            screen.close();
            handleFailure(init, &overlay, err) catch |handled_err| return handled_err;
            unreachable;
        };
        const result = screen.run(allocator, dim, .{
            .lines = visible_lines,
            .width = frozen_frame.state.width,
            .cursor = cursorOf(frozen_frame.state),
        }) catch |err| {
            screen.close();
            handleFailure(init, &overlay, err) catch |handled_err| return handled_err;
            unreachable;
        };
        break :blk .{ .outcome = result, .frozen = frozen_frame, .lines = visible_lines };
    };
    screen.close();
    overlay.phase = .tty_closed;

    switch (prepared_ui.outcome) {
        .abort => return cleanupWithErrorScreen(init, &overlay),
        .jump => |match| {
            overlay.commit(match, prepared_ui.frozen.state, prepared_ui.lines, prepared_ui.frozen.raw) catch |err| {
                return handleFailure(init, &overlay, err);
            };
        },
    }
}

fn handleFailure(init: std.process.Init, overlay: *Overlay, primary: anyerror) !void {
    error_screen.showAndWait(init.io, primary) catch |screen_err| {
        error_screen.reportStderr(init.io, screen_err);
        error_screen.reportStderr(init.io, primary);
    };

    cleanupWithErrorScreen(init, overlay) catch |cleanup_err| {
        error_screen.reportStderr(init.io, cleanup_err);
        return primary;
    };
    return primary;
}

fn cleanupWithErrorScreen(init: std.process.Init, overlay: *Overlay) !void {
    while (true) {
        overlay.cleanup() catch |cleanup_err| {
            error_screen.showAndWait(init.io, cleanup_err) catch |screen_err| {
                error_screen.reportStderr(init.io, screen_err);
                return cleanup_err;
            };
            continue;
        };
        return;
    }
}

const Overlay = struct {
    init: std.process.Init,
    source: []const u8,
    phase: Phase = .started,
    owns_copy_mode: bool = false,
    refresh_was_active: bool = false,

    fn freeze(self: *Overlay, warm: tmux.PaneSnapshot) !tmux.FrozenFrame {
        const before = try self.client().query(self.source);
        if (!before.in_mode) {
            self.owns_copy_mode = true;
        } else {
            const state = try self.client().queryCopy(self.source);
            self.refresh_was_active = state.refresh_active orelse false;
        }
        if (before.width != warm.width or before.height != warm.height) return error.GeometryChanged;
        const frozen = try self.client().freezeAndCapture(self.source, self.owns_copy_mode, self.refresh_was_active);
        self.phase = .frozen;
        if (frozen.state.width != warm.width or frozen.state.height != warm.height) return error.GeometryChanged;
        return frozen;
    }

    fn commit(self: *Overlay, match: flash.Match, snapshot: tmux.CopyState, lines: []const []const u8, raw: []const u8) !void {
        const tmux_client = self.client();
        if (tmux_client.debug) std.debug.print("flash.tmux match start={d},{d} end={d},{d}\n", .{
            match.pos.row,
            match.pos.col,
            match.end_pos.row,
            match.end_pos.col,
        });
        if (tmux_client.debug) writeSnapshot(self.init.io, raw, snapshot.pane_id);
        try tmux_client.jump(.{
            .snapshot = snapshot,
            .target_row = match.pos.row,
            .target_col = match.pos.col,
        }, lines);
        self.phase = .jump_verified;
        try self.restore();
    }

    fn cleanup(self: *Overlay) !void {
        if (self.phase != .restored) try self.restore();
    }

    fn restore(self: *Overlay) !void {
        if (self.phase == .restored) return;
        try self.client().restore(
            self.source,
            self.owns_copy_mode and self.phase != .jump_verified,
            !self.owns_copy_mode and self.refresh_was_active,
        );
        self.phase = .restored;
    }

    fn client(self: *const Overlay) tmux.Client {
        return .init(self.init.arena.allocator(), self.init.io, tmux.debugEnabled(self.init));
    }
};

fn writeSnapshot(io: std.Io, raw: []const u8, pane_id: []const u8) void {
    var tmp = std.Io.Dir.openDirAbsolute(io, "/tmp", .{}) catch return;
    defer tmp.close(io);
    tmp.createDirPath(io, "flash.tmux-history") catch return;

    var path: [160]u8 = undefined;
    const suffix = std.mem.trimStart(u8, pane_id, "%");
    const name = std.fmt.bufPrint(&path, "flash.tmux-history/{d}-pane-{s}.txt", .{ std.Io.Clock.real.now(io).nanoseconds, suffix }) catch return;
    tmp.writeFile(io, .{ .sub_path = name, .data = raw }) catch return;
    std.debug.print("flash.tmux snapshot=/tmp/{s}\n", .{name});
}

const Ref = struct {
    owns_copy_mode: bool,
    refresh_was_active: bool,
};

fn parseRef(raw: []const u8) ?Ref {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    var fields: [2][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, value, '|');
    while (it.next()) |field| {
        if (count == fields.len) return null;
        fields[count] = field;
        count += 1;
    }
    if (count != fields.len) return null;
    if ((fields[0].len != 1 or (fields[0][0] != '0' and fields[0][0] != '1')) or
        (fields[1].len != 1 or (fields[1][0] != '0' and fields[1][0] != '1'))) return null;
    return .{
        .owns_copy_mode = fields[0][0] == '1',
        .refresh_was_active = fields[1][0] == '1',
    };
}

const Phase = enum { started, frozen, jump_verified, tty_closed, restored };

fn cursorOf(state: tmux.CopyState) flash.Pos {
    return .{ .row = state.cursor.y, .col = state.cursor.x };
}

fn frameCursor(client: tmux.Client, query: tmux.PaneSnapshot) !flash.Pos {
    if (!query.in_mode) return .{ .row = query.cursor_y, .col = query.cursor_x };
    return cursorOf(try client.queryCopy(query.pane_id));
}

fn writeFrame(init: std.process.Init, pane_id: []const u8, data: []const u8) ![]u8 {
    const allocator = init.arena.allocator();
    const tmp = init.minimal.environ.getPosix("TMPDIR") orelse "/tmp";
    const name = try std.fmt.allocPrint(allocator, "flash.tmux.{d}.{s}.frame", .{ std.Io.Clock.real.now(init.io).nanoseconds, pane_id });
    var dir = try std.Io.Dir.openDirAbsolute(init.io, tmp, .{});
    defer dir.close(init.io);
    try dir.writeFile(init.io, .{ .sub_path = name, .data = data });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, name });
}

fn readFrame(init: std.process.Init, path: []const u8) ![]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.MissingFrame;
    const dir_path = if (slash == 0) "/" else path[0..slash];
    const name = path[slash + 1 ..];
    if (name.len == 0) return error.MissingFrame;
    var dir = try std.Io.Dir.openDirAbsolute(init.io, dir_path, .{});
    defer dir.close(init.io);
    return dir.readFileAlloc(init.io, name, init.arena.allocator(), .limited(4 * 1024 * 1024));
}

fn dup2(old: std.posix.fd_t, new: std.posix.fd_t) void {
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        _ = std.os.linux.dup2(old, new);
        return;
    }
    _ = std.c.dup2(old, new);
}

fn redirectStderr(init: std.process.Init) void {
    const path = init.minimal.environ.getPosix("FLASH_TMUX_LOG") orelse return;
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    }, 0o644) catch return;
    dup2(fd, std.posix.STDERR_FILENO);
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.close(init.io);
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
