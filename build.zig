const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("lighting", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "bench-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lighting", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const bench_cmd = b.addRunArtifact(exe);
    bench_cmd.step.dependOn(b.getInstallStep());
    bench_cmd.addPassthruArgs();

    const bench_step = b.step("bench", "Run the benchmark server");
    bench_step.dependOn(&bench_cmd.step);

    // Convenience steps to build and run examples using their own build.zig
    const run_hello = b.addSystemCommand(&.{ "zig", "build", "run" });
    run_hello.setCwd(b.path("examples/hello"));
    run_hello.addPassthruArgs();
    const run_hello_step = b.step("run-hello", "Run the hello example");
    run_hello_step.dependOn(&run_hello.step);

    const run_todo = b.addSystemCommand(&.{ "zig", "build", "run" });
    run_todo.setCwd(b.path("examples/todo"));
    run_todo.addPassthruArgs();
    const run_todo_step = b.step("run-todo", "Run the todo example with sqlite and SPA");
    run_todo_step.dependOn(&run_todo.step);

    const mod_tests = b.addTest(.{
        .name = "lighting_test",
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const e2e_tests = b.addTest(.{
        .name = "e2e_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/e2e_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_e2e_tests.step);
}
