const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libvaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const libxev = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    const zg = b.dependency("zg", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "snail",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("vaxis", libvaxis.module("vaxis"));
    exe.root_module.addImport("xev", libxev.module("xev"));
    exe.root_module.addImport("grapheme", zg.module("grapheme"));
    exe.root_module.addImport("DisplayWidth", zg.module("DisplayWidth"));

    b.installArtifact(exe);

    const exe_check = b.addExecutable(.{
        .name = "snail",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_check.root_module.addImport("vaxis", libvaxis.module("vaxis"));
    exe_check.root_module.addImport("xev", libxev.module("xev"));

    const check = b.step("check", "Check if snail shell compiles");
    check.dependOn(&exe_check.step);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
