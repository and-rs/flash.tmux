const std = @import("std");
const flash_tmux = @import("flash_tmux");
const flash = flash_tmux.flash;
const sgr = flash_tmux.sgr;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 2 and args.len != 3) return error.InvalidArguments;

    const raw = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], gpa, .limited(4 * 1024 * 1024));
    const plain = try sgr.strip(gpa, raw);
    const lines = try splitLines(gpa, plain);
    const width = gridWidth(lines);

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.Writer.init(.stdout(), init.io, &out_buf);
    defer out.interface.flush() catch {};

    if (args.len == 3) {
        try printDimensions(&out.interface, width, @intCast(lines.len));
        return;
    }

    const grid: flash.Grid = .{
        .lines = lines,
        .width = width,
        .cursor = .{},
    };
    var parsed = try flash.State.init(gpa, grid, .{});
    defer parsed.deinit();

    var seen = std.AutoHashMap(u32, void).init(gpa);
    defer seen.deinit();
    for (parsed.rows) |row| {
        if (row.len < 3) continue;
        for (row[0 .. row.len - 2], 0..) |first, i| {
            const second = row[i + 1];
            const third = row[i + 2];
            if (!isTypeable(first) or !isTypeable(second) or !isTypeable(third)) continue;
            if (second.col != first.col + 1 or third.col != second.col + 1) continue;

            const pattern = [3]u8{ first.bytes[0], second.bytes[0], third.bytes[0] };
            if (isLabel(pattern[0]) or isLabel(pattern[1]) or isLabel(pattern[2])) continue;
            const id = (@as(u32, pattern[0]) << 16) | (@as(u32, pattern[1]) << 8) | pattern[2];
            if (seen.contains(id)) continue;
            try seen.put(id, {});
            try emitCases(gpa, grid, pattern, &out.interface);
        }
    }
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    if (trimmed.len == 0) return &.{};
    var count: usize = 1;
    for (trimmed) |byte| {
        if (byte == '\n') count += 1;
    }
    const lines = try allocator.alloc([]const u8, count);
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| : (i += 1) lines[i] = line;
    return lines;
}

fn gridWidth(lines: []const []const u8) u32 {
    var width: u32 = 0;
    for (lines) |line| {
        const cells = flash.parseLine(std.heap.page_allocator, line) catch continue;
        defer std.heap.page_allocator.free(cells);
        for (cells) |cell| width = @max(width, cell.col + cell.width);
    }
    return width;
}

fn isTypeable(cell: flash.Cell) bool {
    return cell.width == 1 and cell.bytes.len == 1 and cell.bytes[0] >= '!' and cell.bytes[0] <= '~';
}

fn isLabel(byte: u8) bool {
    return std.mem.indexOfScalar(u8, "asdfghjklqwertyuiopzxcvbnmASDFGHJKLQWERTYUIOPZXCVBNM", byte) != null;
}

fn emitCases(allocator: std.mem.Allocator, grid: flash.Grid, pattern: [3]u8, writer: anytype) !void {
    var state = try flash.State.init(allocator, grid, .{});
    defer state.deinit();
    for (pattern) |byte| {
        if (!try state.step(byte)) return;
    }
    if (state.results.items.len != 1) return;
    try printCase(writer, pattern, state.results.items[0].pos);
}

fn printDimensions(writer: anytype, width: u32, height: u32) !void {
    try writer.print("{d}\t{d}\n", .{ width, height });
}

fn printCase(writer: anytype, pattern: [3]u8, pos: flash.Pos) !void {
    try writer.print("{s}\t{d}\t{d}\n", .{ pattern, pos.row, pos.col });
}
