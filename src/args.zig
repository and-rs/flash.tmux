const std = @import("std");

pub const Args = struct {
    pane: ?[]const u8 = null,
    session: ?[]const u8 = null,
    inspect: bool = false,
    version: bool = false,
};

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
        } else if (std.mem.startsWith(u8, a, "--session=")) {
            const v = a["--session=".len..];
            if (v.len == 0) return error.MissingSession;
            out.session = v;
        } else if (std.mem.eql(u8, a, "--session")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingSession;
            out.session = args[i];
        }
    }
    return out;
}
