const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const x11: bool = blk: {
        const x11_option = b.option(bool, "x11", "Use X11");
        break :blk switch (target.result.os.tag) {
            .linux => {
                if (x11_option == false) @panic("cannot disable x11 for linux target");
                break :blk true;
            },
            else => x11_option orelse false,
        };
    };

    const options = b.addOptions();
    options.addOption(bool, "x11", x11);
    const zin_mod = b.addModule("zin", .{
        .root_source_file = b.path("src/zin.zig"),
        .target = target,
        .optimize = optimize,
    });
    zin_mod.addOptions("build_options", options);

    // all targets use win32 at the moment, some types in the common
    // code references win32 types
    const win32_dep = b.dependency("win32", .{});
    zin_mod.addImport("win32", win32_dep.module("win32"));

    if (x11) {
        if (b.lazyDependency("x11", .{})) |x11_dep| {
            zin_mod.addImport("x11", x11_dep.module("x11"));
        }
    } else switch (target.result.os.tag) {
        .windows => {},
        .macos => {
            if (b.lazyDependency("objc", .{
                .target = target,
                .optimize = optimize,
            })) |objc_dep| {
                zin_mod.addImport("objc", objc_dep.module("objc"));
                //zin_mod.linkFramework("Foundation");
                zin_mod.linkFramework("AppKit", .{});
            }
        },
        else => {},
    }

    const examples = b.step("examples", "Build/install all examples");
    addExample(b, target, optimize, zin_mod, examples, "hello");
}

fn addExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zin_mod: *std.Build.Module,
    examples_step: *std.Build.Step,
    name: []const u8,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zin", .module = zin_mod },
            },
        }),
        .win32_manifest = b.path("res/win32dpiaware.manifest"),
    });
    const install = b.addInstallArtifact(exe, .{});
    examples_step.dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    if (b.args) |a| run.addArgs(a);
    b.step(name, "").dependOn(&run.step);
}
