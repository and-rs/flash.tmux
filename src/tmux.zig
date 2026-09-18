const std = @import("std");
const Io = std.Io;
const flash = @import("flash.zig");

const pane_query_format = "#{pane_id}|#{pane_width}|#{pane_height}|#{cursor_x}|#{cursor_y}|#{?pane_in_mode,1,0}|#{copy_cursor_x}|#{copy_cursor_y}|#{?selection_present,1,0}|#{scroll_position}";
const overlay_option = "@flash-overlay";
const command_output_limit = 64;
const query_output_limit = 4096;
const capture_output_limit = 1024 * 1024;
const max_query_fields = 16;

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
    debug: bool,

    pub fn init(allocator: std.mem.Allocator, io: Io, debug: bool) Client {
        return .{ .allocator = allocator, .io = io, .debug = debug };
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

        if (self.debug) {
            _ = try self.run(&.{
                "tmux", "new-session", "-d", "-s", session, "-x", width_arg, "-y", height_arg,
                "-e", "FLASH_TMUX_DEBUG=1", "-e", "FLASH_TMUX_LOG=/tmp/flash.tmux.log",
                "sh", "-c", "exec \"$@\" 2>>\"$FLASH_TMUX_LOG\"", "flash_tmux", bin, pane_arg, session_arg,
                ";", "set-option", "-t", session, "status", "off",
            }, command_output_limit);
        } else {
            _ = try self.run(&.{
                "tmux", "new-session", "-d",        "-s", session,      "-x", width_arg, "-y",     height_arg,
                bin,    pane_arg,      session_arg, ";",  "set-option", "-t", session,   "status", "off",
            }, command_output_limit);
        }
        if (self.debug) {
            const message = try std.fmt.allocPrint(self.allocator, "flash.tmux dev: jump mode ({s})", .{pane});
            _ = self.run(&.{ "tmux", "display-message", "-d", "3000", message }, command_output_limit) catch {};
        }
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

    pub fn restoreOverlay(self: Client, pane: []const u8, source: []const u8, cancel_copy_mode: bool) !void {
        var commands = CommandBatch.init(self);
        defer commands.deinit();
        if (cancel_copy_mode) try commands.append(&.{ "copy-mode", "-q", "-t", source });
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
        const target_y: i64 = request.target_row;
        self.log("jump target={d},{d} virtual_y={d} snapshot copy={d},{d} scroll={d}", .{
            request.target_row,
            request.target_col,
            target_y,
            request.snapshot.copy_cursor_y,
            request.snapshot.copy_cursor_x,
            request.snapshot.scroll_position,
        });
        if (uniqueSuffix(lines, request.target_row, request.target_col)) |needle| {
            const current = try self.query(request.snapshot.pane_id);
            const direction = if (target_y < current.copy_cursor_y) "search-backward" else "search-forward";
            const pattern = try regexLiteral(self.allocator, needle);
            try self.copyModeCommand(request.snapshot.pane_id, &.{ direction, "--", pattern });
            const found = try self.query(request.snapshot.pane_id);
            if (found.copy_cursor_x == request.target_col and found.copy_cursor_y == target_y) return;
            self.log("search missed target; using cursor fallback", .{});
        }
        switch (jumpKind(request.snapshot.in_mode, request.snapshot.selection_present)) {
            .enter => {
                try self.enterCopyMode(request.snapshot.pane_id);
                try self.positionCursor(request.snapshot.pane_id, target_y, request.target_col, lineAt(lines, request.target_row));
            },
            .move => {
                if (!request.still_in_mode) {
                    try self.enterCopyMode(request.snapshot.pane_id);
                }
                try self.positionCursor(request.snapshot.pane_id, target_y, request.target_col, lineAt(lines, request.target_row));
            },
            .extend => {
                if (!request.still_in_mode) {
                    try self.enterCopyMode(request.snapshot.pane_id);
                    try self.positionCursor(
                        request.snapshot.pane_id,
                        request.snapshot.copy_cursor_y,
                        request.snapshot.copy_cursor_x,
                        lineAt(lines, request.snapshot.copy_cursor_y),
                    );
                    try self.copyModeCommand(request.snapshot.pane_id, &.{"begin-selection"});
                }
                try self.positionCursor(request.snapshot.pane_id, target_y, request.target_col, lineAt(lines, request.target_row));
            },
        }
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

    fn log(self: Client, comptime format: []const u8, args: anytype) void {
        if (self.debug) std.debug.print("flash.tmux " ++ format ++ "\n", args);
    }

    fn enterCopyMode(self: Client, pane_id: []const u8) !void {
        _ = try self.run(&.{ "tmux", "copy-mode", "-t", pane_id }, command_output_limit);
    }

    fn positionCursor(self: Client, pane_id: []const u8, target_y: i64, target_col: u32, line: []const u8) !void {
        var attempt: u8 = 0;
        while (attempt < 4) : (attempt += 1) {
            const current = try self.query(pane_id);
            const delta = target_y - current.copy_cursor_y;
            if (delta == 0) break;
            try self.moveCursor(pane_id, @intCast(@abs(delta)), if (delta > 0) "cursor-down" else "cursor-up");
        }

        var current = try self.query(pane_id);
        if (current.copy_cursor_y != target_y) return error.CursorPositionFailed;

        const left = flash.cursorRights(line, current.copy_cursor_x);
        try self.moveCursor(pane_id, left, "cursor-left");
        current = try self.query(pane_id);
        if (current.copy_cursor_x != 0) return error.CursorPositionFailed;

        try self.moveCursor(pane_id, flash.cursorRights(line, target_col), "cursor-right");
        current = try self.query(pane_id);
        if (current.copy_cursor_x != target_col or current.copy_cursor_y != target_y) return error.CursorPositionFailed;
    }

    fn copyModeCommand(self: Client, pane_id: []const u8, extra: []const []const u8) !void {
        var commands = CommandBatch.init(self);
        defer commands.deinit();
        try appendCopyModeCommand(&commands, pane_id, extra);
        _ = try commands.execute(command_output_limit);
    }

    fn moveCursor(self: Client, pane_id: []const u8, n: u32, motion: []const u8) !void {
        if (n == 0) return;
        var count_buffer: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buffer, "{d}", .{n}) catch unreachable;
        try self.copyModeCommand(pane_id, &.{ "-N", count, motion });
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

fn uniqueSuffix(lines: []const []const u8, row: u32, col: u32) ?[]const u8 {
    const line = lineAt(lines, row);
    const cells = flash.parseLine(std.heap.page_allocator, line) catch return null;
    defer std.heap.page_allocator.free(cells);
    for (cells) |cell| {
        if (cell.col != col) continue;
        const start = @intFromPtr(cell.bytes.ptr) - @intFromPtr(line.ptr);
        var end = start + cell.bytes.len;
        while (end <= line.len) {
            const needle = line[start..end];
            if (countOccurrences(lines, needle) == 1) return needle;
            if (end == line.len) break;
            const n = std.unicode.utf8ByteSequenceLength(line[end]) catch 1;
            end += @min(n, line.len - end);
        }
        return null;
    }
    return null;
}

fn regexLiteral(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var pattern: std.ArrayList(u8) = .empty;
    for (text) |byte| {
        if (std.mem.indexOfScalar(u8, "\\.^$|?*+()[]{}", byte) != null) try pattern.append(allocator, '\\');
        try pattern.append(allocator, byte);
    }
    return pattern.toOwnedSlice(allocator);
}

fn countOccurrences(lines: []const []const u8, needle: []const u8) u32 {
    if (needle.len == 0) return 0;
    var count: u32 = 0;
    for (lines) |line| {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, line, start, needle)) |index| {
            count += 1;
            start = index + 1;
        }
    }
    return count;
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
