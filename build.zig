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
    addExample(b, target, optimize, zin_mod, x11, examples, "hello");

    const test_step = b.step("test", "Run all tests");
    if (x11) {
        const test_x11 = b.step("test-x11", "Run the X11 tests against a fake X server");
        const exe = b.addExecutable(.{
            .name = "test-x11",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/x11.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zin", .module = zin_mod }},
            }),
        });
        test_x11.dependOn(&b.addRunArtifact(exe).step);
        // each app bug zin panics on runs in its own process
        for (x11_panic_cases) |case| {
            const run = b.addRunArtifact(exe);
            run.addArg(case[0]);
            run.addCheck(.{ .expect_stderr_match = case[1] });
            run.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
            test_x11.dependOn(&run.step);
        }
        test_step.dependOn(test_x11);
    }
}

/// App bugs zin's X11 platform must panic on: the test-x11 argument that runs
/// the case, and the panic message.
const x11_panic_cases: []const [2][]const u8 = &.{
    .{ "panic-show-not-created", "show called on a window that's not created" },
    .{ "panic-invalidate-not-created", "invalidate called on a window that's not created" },
    .{ "panic-get-client-size-not-created", "getClientSize called on a window that's not created" },
    .{ "panic-start-timer-not-created", "startTimer called on a window that's not created" },
    .{ "panic-create-twice", "create called on a window that's already created" },
    .{ "panic-create-unregistered", "create called before registerClass" },
    .{ "panic-unregister-while-created", "unregisterClass called while its window exists" },
    .{ "panic-disconnect-while-created", "disconnect called while window a exists" },
    .{ "panic-use-after-failure", "the X11 connection failed, the app must disconnect" },
    .{ "panic-show-after-destroyed", "show called on a window that's not created" },
    .{ "panic-hide-not-created", "hide called on a window that's not created" },
    .{ "panic-create-after-destroy", "create called on a window the app destroyed, hide windows to show them again" },
    .{ "panic-show-after-app-destroy", "show called on a window that was destroyed" },
    .{ "panic-error-after-recreate", "Unhandled X11 Error" },
    .{ "panic-error-after-recreate-wrap", "Unhandled X11 Error" },
    .{ "panic-error-after-race-cleared", "Unhandled X11 Error" },
    .{ "panic-error-not-naming-resource", "Unhandled X11 Error" },
    .{ "panic-draw-after-destroy", "drawing on a window the app destroyed" },
    .{ "panic-create-after-failure", "the X11 connection failed, the app must disconnect" },
    .{ "panic-raw-access-after-failure", "the X11 connection failed, the app must disconnect" },
    .{ "panic-main-loop-after-setup-failed", "the X11 connection failed, the app must disconnect" },
    .{ "panic-show-after-failure", "the X11 connection failed, the app must disconnect" },
    .{ "panic-get-client-size-before-created", "getClientSize called before the window's .created callback" },
    .{ "panic-error-after-app-destroy-race", "Unhandled X11 Error" },
};

fn addExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
    zin_mod: *std.Build.Module,
    x11: bool,
    examples_step: *std.Build.Step,
    name: []const u8,
) void {
    for ([_]bool{ false, true }) |win32_direct2d| {
        if (win32_direct2d and (target.result.os.tag != .windows or x11)) continue;
        const exe_name = if (win32_direct2d) b.fmt("{s}-d2d", .{name}) else name;
        const options = b.addOptions();
        options.addOption(bool, "win32_direct2d", win32_direct2d);
        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zin", .module = zin_mod },
                    .{ .name = "build_options", .module = options.createModule() },
                },
            }),
            .win32_manifest = b.path("res/win32dpiaware.manifest"),
        });
        if (target.result.os.tag == .windows) exe.subsystem = .windows;
        exe.root_module.addWin32ResourceFile(.{
            .file = b.path("examples/example.rc"),
        });

        const install = b.addInstallArtifact(exe, .{});
        b.step(b.fmt("install-{s}", .{exe_name}), "").dependOn(&install.step);
        examples_step.dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        run.addPassthruArgs();
        b.step(exe_name, "").dependOn(&run.step);
    }
}
