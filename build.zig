const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = std.mem.trim(u8, @embedFile("VERSION"), " \t\r\n");
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const mod = b.addModule("flash_tmux", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "flash_tmux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "flash_tmux", .module = mod }},
        }),
    });

    b.installArtifact(exe);

    const snapshot_cases = b.addExecutable(.{
        .name = "snapshot_cases",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/snapshot-cases.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "flash_tmux", .module = mod }},
        }),
    });
    const install_snapshot_cases = b.addInstallArtifact(snapshot_cases, .{});
    const snapshot_cases_step = b.step("snapshot-cases", "Install the snapshot case generator");
    snapshot_cases_step.dependOn(&install_snapshot_cases.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

}
