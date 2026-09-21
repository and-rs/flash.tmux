const std = @import("std");
const Io = std.Io;
const flash = @import("flash.zig");

const pane_query_format = "#{pane_id}|#{pane_width}|#{pane_height}|#{cursor_x}|#{cursor_y}|#{?pane_in_mode,1,0}|#{session_name}";
const copy_query_format = "#{pane_id}|#{pane_width}|#{pane_height}|#{?pane_in_mode,1,0}|#{copy_cursor_x}|#{copy_cursor_y}|#{scroll_position}|#{?selection_active,1,0}|#{?selection_present,1,0}|#{selection_start_x}|#{selection_start_y}|#{selection_end_x}|#{selection_end_y}|#{?rectangle_toggle,1,0}|#{refresh_active}|#{copy_position_limit}";
const overlay_option = "@flash-overlay";
const command_output_limit = 64;
const query_output_limit = 4096;
const capture_output_limit = 1024 * 1024;
const max_query_fields = 20;

pub fn debugEnabled(init: std.process.Init) bool {
    const value = init.minimal.environ.getPosix("FLASH_TMUX_DEBUG") orelse return false;
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

const QueryField = enum(usize) {
    pane_id,
    width,
    height,
    cursor_x,
    cursor_y,
    in_mode,
    session_name,
};

const required_query_field_count = @intFromEnum(QueryField.in_mode) + 1;

pub const PaneSnapshot = struct {
    pane_id: []const u8,
    width: u32,
    height: u32,
    cursor_x: u32,
    cursor_y: u32,
    in_mode: bool,
    session_name: []const u8,
};

pub const CopyPoint = struct { x: u32, y: u32, scroll: u32 };

pub const CopyState = struct {
    pane_id: []const u8,
    width: u32,
    height: u32,
    cursor: CopyPoint,
    selection_active: bool,
    selection_present: bool,
    selection_anchor_x: ?u32,
    selection_anchor_y: ?u32,
    rectangle: bool,
    refresh_active: ?bool,
    position_limit: ?u32,

    pub fn eqlPosition(a: CopyState, b: CopyState) bool {
        return a.cursor.x == b.cursor.x and a.cursor.y == b.cursor.y and a.cursor.scroll == b.cursor.scroll;
    }
};

pub fn cursorAt(state: CopyState, row: u32, col: u32) bool {
    return state.cursor.y == row and state.cursor.x == col;
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    debug: bool,

    pub fn init(allocator: std.mem.Allocator, io: Io, debug: bool) Client {
        return .{ .allocator = allocator, .io = io, .debug = debug };
    }

    pub fn killSession(self: Client, session: []const u8) !void {
        _ = try self.run(&.{ "tmux", "kill-session", "-t", session }, command_output_limit);
    }

    pub fn launchOverlay(self: Client, bin: []const u8, pane: []const u8, width: u32, height: u32, session: []const u8) !void {
        var width_buffer: [16]u8 = undefined;
        var height_buffer: [16]u8 = undefined;
        const width_arg = std.fmt.bufPrint(&width_buffer, "{d}", .{width}) catch unreachable;
        const height_arg = std.fmt.bufPrint(&height_buffer, "{d}", .{height}) catch unreachable;
        const pane_arg = try std.fmt.allocPrint(self.allocator, "--pane={s}", .{pane});
        const session_arg = try std.fmt.allocPrint(self.allocator, "--session={s}", .{session});

        if (self.debug) {
            _ = try self.run(&.{
                "tmux",   "new-session",        "-d", "-s",                                 session, "-x",    width_arg,                            "-y",         height_arg,
                "-e",     "FLASH_TMUX_DEBUG=1", "-e", "FLASH_TMUX_LOG=/tmp/flash.tmux.log", "sh",    "-c",    "exec \"$@\" 2>>\"$FLASH_TMUX_LOG\"", "flash_tmux", bin,
                pane_arg, session_arg,          ";",  "set-option",                         "-t",    session, "status",                             "off",
            }, command_output_limit);
        } else {
            _ = try self.run(&.{
                "tmux", "new-session", "-d",        "-s", session,      "-x", width_arg, "-y",     height_arg,
                bin,    pane_arg,      session_arg, ";",  "set-option", "-t", session,   "status", "off",
            }, command_output_limit);
        }
        if (self.debug) {
            const message = try std.fmt.allocPrint(self.allocator, "flash.tmux dev: jump mode ({s})", .{pane});
            _ = try self.run(&.{ "tmux", "display-message", "-d", "3000", message }, command_output_limit);
        }
    }

    pub fn hasSession(self: Client, session: []const u8) !bool {
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "tmux", "has-session", "-t", session },
            .stdout_limit = .limited(command_output_limit),
            .stderr_limit = .limited(4096),
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        return switch (result.term) {
            .exited => |code| code == 0,
            else => error.TmuxFailed,
        };
    }

    pub fn showOverlay(self: Client, pane: []const u8, session: []const u8, source: []const u8) !void {
        const value = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ session, source });
        var commands = CommandBatch.init(self);
        defer commands.deinit();
        try commands.append(&.{ "set-option", "-p", "-t", pane, "remain-on-exit", "on" });
        try commands.append(&.{ "set-option", "-p", "-t", pane, overlay_option, value });
        try commands.append(&.{ "swap-pane", "-Z", "-s", pane, "-t", source });
        _ = try commands.execute(command_output_limit);
    }

    pub fn overlayReference(self: Client, pane: []const u8) ![]u8 {
        return self.run(&.{ "tmux", "display-message", "-t", pane, "-p", "#{@flash-overlay}" }, query_output_limit);
    }

    pub fn clearOverlay(self: Client, pane: []const u8) !void {
        _ = try self.run(&.{ "tmux", "set-option", "-pu", "-t", pane, overlay_option }, command_output_limit);
    }

    pub fn paneDead(self: Client, pane: []const u8) !bool {
        const raw = try self.run(&.{ "tmux", "display-message", "-t", pane, "-p", "#{pane_dead}" }, command_output_limit);
        return std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "1");
    }

    pub fn freeze(self: Client, pane: []const u8, enter_copy_mode: bool) !PaneSnapshot {
        var commands = CommandBatch.init(self);
        defer commands.deinit();
        if (enter_copy_mode) try commands.append(&.{ "copy-mode", "-t", pane });
        try commands.append(&.{ "display-message", "-t", pane, "-p", pane_query_format });
        return parseQuery(try commands.execute(query_output_limit));
    }

    /// Swap the replica into view, then freeze and capture its now-hidden source in one tmux batch.
    pub fn showAndFreezeCapture(self: Client, replica: []const u8, source: []const u8, session: []const u8, enter_copy_mode: bool) !FrozenFrame {
        const marker = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ session, source });
        var commands = CommandBatch.init(self);
        defer commands.deinit();
        try commands.append(&.{ "set-option", "-p", "-t", replica, "remain-on-exit", "on" });
        try commands.append(&.{ "set-option", "-p", "-t", replica, overlay_option, marker });
        try commands.append(&.{ "swap-pane", "-Z", "-s", replica, "-t", source });
        if (enter_copy_mode) try commands.append(&.{ "copy-mode", "-t", source });
        try appendCopyModeCommand(&commands, source, &.{"refresh-off"});
        try commands.append(&.{ "display-message", "-t", source, "-p", copy_query_format });
        const state = try parseCopyQuery(try commands.execute(query_output_limit));
        const raw = try self.captureView(state.pane_id, state.cursor.scroll, state.height);
        return .{ .state = state, .raw = raw };
    }

    pub fn restoreOverlay(self: Client, pane: []const u8, source: []const u8, cancel_copy_mode: bool, resume_refresh: bool) !void {
        var commands = CommandBatch.init(self);
        defer commands.deinit();
        if (cancel_copy_mode) try commands.append(&.{ "copy-mode", "-q", "-t", source });
        if (resume_refresh) try appendCopyModeCommand(&commands, source, &.{"refresh-on"});
        try commands.append(&.{ "swap-pane", "-Z", "-s", pane, "-t", source });
        _ = try commands.execute(command_output_limit);
    }

    pub fn recoverOverlay(self: Client, pane: []const u8, source: []const u8, session: []const u8) !void {
        var commands = CommandBatch.init(self);
        defer commands.deinit();
        try commands.append(&.{ "swap-pane", "-Z", "-s", pane, "-t", source });
        try commands.append(&.{ "set-option", "-pu", "-t", pane, overlay_option });
        try commands.append(&.{ "kill-session", "-t", session });
        _ = try commands.execute(command_output_limit);
    }

    pub fn query(self: Client, pane_id: ?[]const u8) !PaneSnapshot {
        const raw = if (pane_id) |id|
            try self.run(&.{ "tmux", "display-message", "-t", id, "-p", pane_query_format }, query_output_limit)
        else
            try self.run(&.{ "tmux", "display-message", "-p", pane_query_format }, query_output_limit);
        return parseQuery(raw);
    }

    pub fn queryCopy(self: Client, pane_id: []const u8) !CopyState {
        return parseCopyQuery(try self.run(&.{ "tmux", "display-message", "-t", pane_id, "-p", copy_query_format }, query_output_limit));
    }

    pub fn capture(self: Client, snapshot: PaneSnapshot) ![]u8 {
        if (!snapshot.in_mode) {
            return self.run(&.{ "tmux", "capture-pane", "-t", snapshot.pane_id, "-p", "-e", "-N" }, capture_output_limit);
        }
        const copy = try self.queryCopy(snapshot.pane_id);
        return self.captureView(copy.pane_id, copy.cursor.scroll, copy.height);
    }

    fn captureView(self: Client, pane_id: []const u8, scroll: u32, height: u32) ![]u8 {
        const start: i64 = -@as(i64, @intCast(scroll));
        const end = start + @as(i64, @intCast(height)) - 1;
        var start_buffer: [16]u8 = undefined;
        var end_buffer: [16]u8 = undefined;
        const start_arg = std.fmt.bufPrint(&start_buffer, "{d}", .{start}) catch unreachable;
        const end_arg = std.fmt.bufPrint(&end_buffer, "{d}", .{end}) catch unreachable;
        return self.run(&.{ "tmux", "capture-pane", "-t", pane_id, "-p", "-e", "-N", "-S", start_arg, "-E", end_arg }, capture_output_limit);
    }

    pub fn jump(self: Client, request: JumpRequest, lines: []const []const u8) !void {
        if (request.target_row >= lines.len) return error.UnaddressableTarget;
        const original = request.snapshot;
        const target_line = motionLine(lines, request.target_row);
        const target_rights = flash.cursorRights(target_line, request.target_col);
        var vertical = CommandBatch.init(self);
        defer vertical.deinit();
        try appendCopyModeCommand(&vertical, original.pane_id, &.{"top-line"});
        try motion(&vertical, original.pane_id, "cursor-down", request.target_row);
        try vertical.append(&.{ "display-message", "-t", original.pane_id, "-p", copy_query_format });
        const positioned = try parseCopyQuery(try vertical.execute(query_output_limit));
        if (positioned.width != original.width or positioned.height != original.height or
            positioned.cursor.scroll != original.cursor.scroll or positioned.cursor.y != request.target_row)
            return error.CursorDidNotReachTarget;

        var horizontal = CommandBatch.init(self);
        defer horizontal.deinit();
        try motion(&horizontal, original.pane_id, "cursor-left", flash.cursorRights(target_line, positioned.cursor.x));
        try motion(&horizontal, original.pane_id, "cursor-right", target_rights);
        try horizontal.append(&.{ "display-message", "-t", original.pane_id, "-p", copy_query_format });
        const landed = try parseCopyQuery(try horizontal.execute(query_output_limit));
        if (landed.width != original.width or landed.height != original.height or
            landed.cursor.scroll != original.cursor.scroll or
            !cursorAt(landed, request.target_row, request.target_col))
            return error.CursorDidNotReachTarget;
    }

    fn run(self: Client, argv: []const []const u8, stdout_limit: usize) ![]u8 {
        if (self.debug) {
            std.debug.print("flash.tmux tmux", .{});
            for (argv) |arg| std.debug.print(" [{s}]", .{arg});
            std.debug.print("\n", .{});
        }
        const result = try std.process.run(self.allocator, self.io, .{
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
};

pub const JumpRequest = struct {
    snapshot: CopyState,
    target_row: u32,
    target_col: u32,
};

pub const FrozenFrame = struct { state: CopyState, raw: []const u8 };

fn appendCopyModeCommand(commands: *CommandBatch, pane_id: []const u8, extra: []const []const u8) !void {
    try commands.appendParts(&.{ "send-keys", "-t", pane_id, "-X" }, extra);
}

pub fn parseQuery(raw: []const u8) !PaneSnapshot {
    const line = blk: {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.indexOfScalar(u8, trimmed, '\n')) |nl|
            break :blk std.mem.trim(u8, trimmed[0..nl], " \t\r");
        break :blk trimmed;
    };
    var fields: [max_query_fields][]const u8 = undefined;
    var field_count: usize = 0;
    var it = std.mem.splitScalar(u8, line, '|');
    while (it.next()) |f| {
        if (field_count >= fields.len) return error.InvalidQuery;
        fields[field_count] = std.mem.trim(u8, f, " \t");
        field_count += 1;
    }
    if (field_count < required_query_field_count or requiredField(&fields, .pane_id).len == 0 or requiredField(&fields, .session_name).len == 0) return error.InvalidQuery;
    return .{
        .pane_id = requiredField(&fields, .pane_id),
        .width = try parseU32(requiredField(&fields, .width)),
        .height = try parseU32(requiredField(&fields, .height)),
        .cursor_x = try parseU32(requiredField(&fields, .cursor_x)),
        .cursor_y = try parseU32(requiredField(&fields, .cursor_y)),
        .in_mode = try parseU32(requiredField(&fields, .in_mode)) != 0,
        .session_name = requiredField(&fields, .session_name),
    };
}

fn requiredField(fields: []const []const u8, field: QueryField) []const u8 {
    return fields[@intFromEnum(field)];
}

fn parseU32(s: []const u8) !u32 {
    if (s.len == 0) return error.InvalidQuery;
    return std.fmt.parseUnsigned(u32, s, 10);
}

fn parseOptionalU32(s: []const u8) !?u32 {
    if (s.len == 0) return null;
    return try parseU32(s);
}

pub fn parseCopyQuery(raw: []const u8) !CopyState {
    const line = firstLine(raw);
    var fields: [max_query_fields][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, line, '|');
    while (it.next()) |field| {
        if (count >= fields.len) return error.InvalidCopyState;
        fields[count] = std.mem.trim(u8, field, " \t");
        count += 1;
    }
    if (count != 16) return error.InvalidCopyState;
    if (fields[0].len == 0 or !std.mem.eql(u8, fields[3], "1")) return error.CopyModeLost;
    const active = try parseBool(fields[7]);
    const present = try parseBool(fields[8]);
    const has_anchor = active or present;
    return .{
        .pane_id = fields[0],
        .width = try parseU32(fields[1]),
        .height = try parseU32(fields[2]),
        .cursor = .{ .x = try parseU32(fields[4]), .y = try parseU32(fields[5]), .scroll = try parseU32(fields[6]) },
        .selection_active = active,
        .selection_present = present,
        .selection_anchor_x = if (has_anchor) try parseU32(fields[9]) else null,
        .selection_anchor_y = if (has_anchor) try parseU32(fields[10]) else null,
        .rectangle = try parseBool(fields[13]),
        .refresh_active = try parseOptionalBool(fields[14]),
        .position_limit = try parseOptionalU32(fields[15]),
    };
}

fn firstLine(raw: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, raw, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..end], " \t\r");
}

fn parseBool(s: []const u8) !bool {
    const value = try parseU32(s);
    if (value > 1) return error.InvalidCopyState;
    return value == 1;
}

fn parseOptionalBool(s: []const u8) !?bool {
    if (s.len == 0) return null;
    return try parseBool(s);
}

fn motion(commands: *CommandBatch, pane: []const u8, name: []const u8, count: u32) !void {
    if (count == 0) return;
    // CommandBatch retains argument slices until execute, so this cannot point
    // at a stack buffer owned by this helper.
    const count_arg = try std.fmt.allocPrint(commands.client.allocator, "{d}", .{count});
    try appendCopyModeCommand(commands, pane, &.{ "-N", count_arg, name });
}

fn motionLine(lines: []const []const u8, row: u32) []const u8 {
    if (row >= lines.len) return "";
    return std.mem.trimEnd(u8, lines[row], " ");
}

const CommandBatch = struct {
    client: Client,
    argv: std.ArrayList([]const u8) = .empty,

    fn init(client: Client) CommandBatch {
        return .{ .client = client };
    }

    fn deinit(self: *CommandBatch) void {
        self.argv.deinit(self.client.allocator);
    }

    fn append(self: *CommandBatch, args: []const []const u8) !void {
        try self.appendParts(args, &.{});
    }

    fn appendParts(self: *CommandBatch, first: []const []const u8, second: []const []const u8) !void {
        if (self.argv.items.len == 0) {
            try self.argv.append(self.client.allocator, "tmux");
        } else {
            try self.argv.append(self.client.allocator, ";");
        }
        try self.argv.appendSlice(self.client.allocator, first);
        try self.argv.appendSlice(self.client.allocator, second);
    }

    fn execute(self: *CommandBatch, stdout_limit: usize) ![]u8 {
        return self.client.run(self.argv.items, stdout_limit);
    }
};
