const std = @import("std");

pub const Cursor = struct {
    row: u32,
    col: u32,
};

pub const Args = struct {
    pane: ?[]const u8 = null,
    frame: ?[]const u8 = null,
    cursor: ?Cursor = null,
    ui: bool = false,
    inspect: bool = false,
    version: bool = false,
};

// this is sort of basic, really basic arg handling
pub fn parse(args: []const []const u8) !Args {
    var out: Args = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--version")) {
            out.version = true;
        } else if (std.mem.eql(u8, a, "--inspect")) {
            out.inspect = true;
        } else if (std.mem.startsWith(u8, a, "--pane=")) {
            const v = a["--pane=".len..];
            if (v.len == 0) return error.MissingPane;
            out.pane = v;
        } else if (std.mem.eql(u8, a, "--pane")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingPane;
            out.pane = args[i];
        } else if (std.mem.startsWith(u8, a, "--frame=")) {
            const v = a["--frame=".len..];
            if (v.len == 0) return error.MissingFrame;
            out.frame = v;
        } else if (std.mem.startsWith(u8, a, "--cursor=")) {
            out.cursor = try parseCursor(a["--cursor=".len..]);
        } else if (std.mem.eql(u8, a, "--ui")) {
            out.ui = true;
        }
    }
    return out;
}

fn parseCursor(raw: []const u8) !Cursor {
    const comma = std.mem.indexOfScalar(u8, raw, ',') orelse return error.InvalidCursor;
    if (comma == 0 or comma + 1 == raw.len) return error.InvalidCursor;
    return .{
        .row = std.fmt.parseUnsigned(u32, raw[0..comma], 10) catch return error.InvalidCursor,
        .col = std.fmt.parseUnsigned(u32, raw[comma + 1 ..], 10) catch return error.InvalidCursor,
    };
}
