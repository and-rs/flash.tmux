const std = @import("std");
const Io = std.Io;
const flash = @import("flash.zig");

const pane_query_format = "#{pane_id}|#{pane_width}|#{pane_height}|#{cursor_x}|#{cursor_y}|#{?pane_in_mode,1,0}|#{copy_cursor_x}|#{copy_cursor_y}|#{?selection_present,1,0}|#{scroll_position}";
const overlay_option = "@flash-overlay";
const command_output_limit = 64;
const query_output_limit = 4096;
const capture_output_limit = 1024 * 1024;
const max_query_fields = 16;

const QueryField = enum(usize) {
    pane_id,
    width,
    height,
    cursor_x,
    cursor_y,
    in_mode,
    copy_cursor_x,
    copy_cursor_y,
    selection_present,
    scroll_position,
};

const required_query_field_count = @intFromEnum(QueryField.in_mode) + 1;

pub const PaneSnapshot = struct {
    pane_id: []const u8,
    width: u32,
    height: u32,
    cursor_x: u32,
    cursor_y: u32,
    in_mode: bool,
    copy_cursor_x: u32,
    copy_cursor_y: u32,
    selection_present: bool,
    scroll_position: u32,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) Client {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn killSession(self: Client, session: []const u8) void {
        _ = self.run(&.{ "tmux", "kill-session", "-t", session }, command_output_limit) catch {};
    }

    pub fn launchOverlay(self: Client, bin: []const u8, pane: []const u8, width: u32, height: u32, session: []const u8) !void {
        var width_buffer: [16]u8 = undefined;
        var height_buffer: [16]u8 = undefined;
        const width_arg = std.fmt.bufPrint(&width_buffer, "{d}", .{width}) catch unreachable;
        const height_arg = std.fmt.bufPrint(&height_buffer, "{d}", .{height}) catch unreachable;
        const pane_arg = try std.fmt.allocPrint(self.allocator, "--pane={s}", .{pane});
        const session_arg = try std.fmt.allocPrint(self.allocator, "--session={s}", .{session});

        _ = try self.run(&.{
            "tmux", "new-session", "-d",        "-s", session,      "-x", width_arg, "-y",     height_arg,
            bin,    pane_arg,      session_arg, ";",  "set-option", "-t", session,   "status", "off",
        }, command_output_limit);
    }

    pub fn hasSession(self: Client, session: []const u8) bool {
        _ = self.run(&.{ "tmux", "has-session", "-t", session }, command_output_limit) catch return false;
        return true;
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

    pub fn clearOverlay(self: Client, pane: []const u8) void {
        _ = self.run(&.{ "tmux", "set-option", "-pu", "-t", pane, overlay_option }, command_output_limit) catch {};
    }

    pub fn paneDead(self: Client, pane: []const u8) bool {
        const raw = self.run(&.{ "tmux", "display-message", "-t", pane, "-p", "#{pane_dead}" }, command_output_limit) catch return false;
        return std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "1");
    }

    pub fn freeze(self: Client, pane: []const u8, enter_copy_mode: bool) !PaneSnapshot {
        var commands = CommandBatch.init(self);
        defer commands.deinit();
        if (enter_copy_mode) try commands.append(&.{ "copy-mode", "-t", pane });
        try appendCopyModeCommand(&commands, pane, &.{"refresh-off"});
        try commands.append(&.{ "display-message", "-t", pane, "-p", pane_query_format });
        return parseQuery(try commands.execute(query_output_limit));
    }

    pub fn restoreOverlay(self: Client, pane: []const u8, source: []const u8, session: []const u8, cancel_copy_mode: bool) !void {
        var commands = CommandBatch.init(self);
        defer commands.deinit();
        if (cancel_copy_mode) try commands.append(&.{ "copy-mode", "-q", "-t", source });
        try commands.append(&.{ "swap-pane", "-Z", "-s", pane, "-t", source });
        try commands.append(&.{ "kill-session", "-t", session });
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

    pub fn capture(self: Client, snapshot: PaneSnapshot) ![]u8 {
        if (!snapshot.in_mode) {
            return self.run(&.{ "tmux", "capture-pane", "-t", snapshot.pane_id, "-p", "-e", "-N" }, capture_output_limit);
        }

        const start: i64 = -@as(i64, @intCast(snapshot.scroll_position));
        const end = start + @as(i64, @intCast(snapshot.height)) - 1;
        var start_buffer: [16]u8 = undefined;
        var end_buffer: [16]u8 = undefined;
        const start_arg = std.fmt.bufPrint(&start_buffer, "{d}", .{start}) catch unreachable;
        const end_arg = std.fmt.bufPrint(&end_buffer, "{d}", .{end}) catch unreachable;
        return self.run(&.{ "tmux", "capture-pane", "-t", snapshot.pane_id, "-p", "-e", "-N", "-M", "-S", start_arg, "-E", end_arg }, capture_output_limit);
    }

    pub fn jump(self: Client, request: JumpRequest, lines: []const []const u8) !void {
        var commands = CommandBatch.init(self);
        defer commands.deinit();
        const target_col = flash.cursorRights(lineAt(lines, request.target_row), request.target_col);
        const saved_col = flash.cursorRights(lineAt(lines, request.snapshot.copy_cursor_y), request.snapshot.copy_cursor_x);
        switch (jumpKind(request.snapshot.in_mode, request.snapshot.selection_present)) {
            .enter => try appendEnterAt(&commands, request.snapshot.pane_id, request.target_row, target_col, 0),
            .move => {
                if (!request.still_in_mode) {
                    try appendEnterAt(&commands, request.snapshot.pane_id, request.target_row, target_col, request.snapshot.scroll_position);
                } else {
                    try appendPosition(&commands, request.snapshot.pane_id, request.target_row, target_col);
                }
            },
            .extend => {
                if (!request.still_in_mode) {
                    try appendEnterAt(&commands, request.snapshot.pane_id, request.snapshot.copy_cursor_y, saved_col, request.snapshot.scroll_position);
                    try appendCopyModeCommand(&commands, request.snapshot.pane_id, &.{"begin-selection"});
                }
                try appendPosition(&commands, request.snapshot.pane_id, request.target_row, target_col);
            },
        }
        _ = try commands.execute(command_output_limit);
    }

    fn run(self: Client, argv: []const []const u8, stdout_limit: usize) ![]u8 {
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

pub const JumpKind = enum { enter, move, extend };

pub fn jumpKind(in_mode: bool, selection_present: bool) JumpKind {
    if (!in_mode) return .enter;
    if (selection_present) return .extend;
    return .move;
}

pub const JumpRequest = struct {
    snapshot: PaneSnapshot,
    target_row: u32,
    target_col: u32,
    still_in_mode: bool,
};

fn lineAt(lines: []const []const u8, row: u32) []const u8 {
    if (row >= lines.len) return "";
    return lines[row];
}

fn appendEnterAt(commands: *CommandBatch, pane_id: []const u8, row: u32, col: u32, scroll: u32) !void {
    try commands.append(&.{ "copy-mode", "-t", pane_id });
    try appendMoveN(commands, pane_id, scroll, "scroll-up");
    try appendPosition(commands, pane_id, row, col);
}

fn appendPosition(commands: *CommandBatch, pane_id: []const u8, row: u32, col: u32) !void {
    try appendCopyModeCommand(commands, pane_id, &.{"top-line"});
    try appendMoveN(commands, pane_id, row, "cursor-down");
    try appendMoveN(commands, pane_id, col, "cursor-right");
}

fn appendMoveN(commands: *CommandBatch, pane_id: []const u8, n: u32, motion: []const u8) !void {
    if (n == 0) return;
    const count = try std.fmt.allocPrint(commands.client.allocator, "{d}", .{n});
    try appendCopyModeCommand(commands, pane_id, &.{ "-N", count, motion });
}

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
    if (field_count < required_query_field_count or requiredField(&fields, .pane_id).len == 0) return error.InvalidQuery;
    return .{
        .pane_id = requiredField(&fields, .pane_id),
        .width = try parseU32(requiredField(&fields, .width)),
        .height = try parseU32(requiredField(&fields, .height)),
        .cursor_x = try parseU32(requiredField(&fields, .cursor_x)),
        .cursor_y = try parseU32(requiredField(&fields, .cursor_y)),
        .in_mode = try parseU32(requiredField(&fields, .in_mode)) != 0,
        .copy_cursor_x = try parseU32(optionalField(&fields, field_count, .copy_cursor_x)),
        .copy_cursor_y = try parseU32(optionalField(&fields, field_count, .copy_cursor_y)),
        .selection_present = try parseU32(optionalField(&fields, field_count, .selection_present)) != 0,
        .scroll_position = try parseU32(optionalField(&fields, field_count, .scroll_position)),
    };
}

fn requiredField(fields: []const []const u8, field: QueryField) []const u8 {
    return fields[@intFromEnum(field)];
}

fn optionalField(fields: []const []const u8, field_count: usize, field: QueryField) []const u8 {
    const index = @intFromEnum(field);
    return if (field_count > index) fields[index] else "";
}

fn parseU32(s: []const u8) !u32 {
    if (s.len == 0) return 0;
    return std.fmt.parseUnsigned(u32, s, 10);
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
