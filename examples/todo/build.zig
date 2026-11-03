const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lighting = b.dependency("lighting", .{
        .target = target,
        .optimize = optimize,
    });

    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const todo_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lighting", .module = lighting.module("lighting") },
            .{ .name = "sqlite", .module = sqlite.module("sqlite") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "todo",
        .root_module = todo_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the todo example");
    run_step.dependOn(&run_cmd.step);
}
