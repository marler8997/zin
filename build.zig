const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const x11 = b.option(bool, "x11", "Use X11") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "x11", x11);
    const zin_mod = b.createModule(.{
        .root_source_file = b.path("src/zin.zig"),
        .target = target,
        .optimize = optimize,
    });
    zin_mod.addOptions("build_options", options);
    if (x11) {
        if (b.lazyDependency("x11", .{})) |x11_dep| {
            zin_mod.addImport("x11", x11_dep.module("x11"));
        }
    }
    switch (target.result.os.tag) {
        .windows => {
            if (b.lazyDependency("win32", .{})) |win32_dep| {
                zin_mod.addImport("win32", win32_dep.module("win32"));
            }
        },
        .macos => {
            if (b.lazyDependency("mach_objc", .{})) |dep| {
                zin_mod.addImport("mach_objc", dep.module("mach-objc"));
                // zin_mod.addSystemFrameworkPath(dep.path("Frameworks"));
                // zin_mod.addSystemIncludePath(dep.path("include"));
                // zin_mod.addLibraryPath(dep.path("lib"));
            }

            // zin_mod.linkFramework("Foundation", .{});
            // zin_mod.linkFramework("Cocoa", .{});
            //zin_mod.linkFramework("OpenGL", .{});
            //zin_mod.linkFramework("CoreAudio", .{});
            //zin_mod.linkFramework("CoreVideo", .{});
            //zin_mod.linkFramework("IOKit");
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
    });
    const install = b.addInstallArtifact(exe, .{});
    examples_step.dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    if (b.args) |a| run.addArgs(a);
    b.step(name, "").dependOn(&run.step);
}
