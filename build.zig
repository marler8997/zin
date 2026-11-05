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

    // A parent build can set these to false and add its own "win32", "x11" or
    // "objc" import to the zin module, so both share one copy of the dependency.
    const import_win32 = b.option(bool, "import-win32", "Import zin's own win32 dependency (default: true)") orelse true;
    const import_x11 = b.option(bool, "import-x11", "Import zin's own x11 dependency (default: true)") orelse true;
    const import_objc = b.option(bool, "import-objc", "Import zin's own objc dependency (default: true)") orelse true;

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
    if (import_win32) {
        if (b.lazyDependency("win32", .{})) |dep| zin_mod.addImport("win32", dep.module("win32"));
    }

    if (x11) {
        if (import_x11) {
            if (b.lazyDependency("x11", .{})) |dep| zin_mod.addImport("x11", dep.module("x11"));
        }
    } else switch (target.result.os.tag) {
        .windows => {},
        .macos => {
            if (import_objc) {
                if (b.lazyDependency("objc", .{ .target = target, .optimize = optimize })) |dep| {
                    zin_mod.addImport("objc", dep.module("objc"));
                }
            }
            const coregraphics_h = b.addWriteFiles().add("c.h",
                \\#include <CoreGraphics/CoreGraphics.h>
                \\// #include <CoreFoundation/CoreFoundation.h>
                \\
            );
            zin_mod.addImport("c", b.addTranslateC(.{
                .root_source_file = coregraphics_h,
                .target = target,
                .optimize = optimize,
            }).createModule());
            //zin_mod.linkFramework("Foundation");
            zin_mod.linkFramework("AppKit", .{});
        },
        else => {},
    }

    const examples = b.step("examples", "Build/install all examples");
    addExample(b, target, optimize, zin_mod, examples, "hello");
}

fn addExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
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
    exe.root_module.addWin32ResourceFile(.{
        .file = b.path("examples/example.rc"),
    });

    const install = b.addInstallArtifact(exe, .{});
    b.step(b.fmt("install-{s}", .{name}), "").dependOn(&install.step);
    examples_step.dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(&install.step);
    run.addPassthruArgs();
    b.step(name, "").dependOn(&run.step);
}
