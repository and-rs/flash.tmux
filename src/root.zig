const std = @import("std");
const Io = std.Io;

pub const flash = @import("flash.zig");
pub const sgr = @import("sgr.zig");
pub const tmux = @import("tmux.zig");
pub const tty = @import("tty.zig");

test {
    _ = flash;
    _ = sgr;
    _ = tmux;
}
