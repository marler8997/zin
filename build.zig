const std = @import("std");

pub const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

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
            // we can't use build.zig.zon because we'd need separate entries for both 0.14
            // and 0.15 and both will break zig's fetch when it tries to process their
            // build.zig files
            const objc = ZigFetch.create(b, if (zig_atleast_15) .{
                .url = "git+https://github.com/mitchellh/zig-objc#49dae46e413647545cc5c1f3e7798e9c761976b0",
                .hash = "zig_objc-0.0.0-Ir_Sp5wTAQDuSB-PaIBSxNPhnQFT-H8UGd5kBAdnUaD4",
            } else .{
                .url = "git+https://github.com/mitchellh/zig-objc#1ab06dde464e24bd4db56f6639de92ca16478bc5",
                .hash = "zig_objc-0.0.0-Ir_SpwkUAQBuD4EZduOtQ4LYQpNizYhYBMsqC60IuU9L",
            });
            const module = b.createModule(.{
                .root_source_file = objc.getLazyPath().path(b, "src/main.zig"),
            });
            zin_mod.addImport("objc", module);
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
    exe.addWin32ResourceFile(.{
        .file = b.path("examples/example.rc"),
    });

    const install = b.addInstallArtifact(exe, .{});
    examples_step.dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    if (b.args) |a| run.addArgs(a);
    b.step(name, "").dependOn(&run.step);
}

const ZigFetchOptions = struct {
    url: []const u8,
    hash: []const u8,
};
const ZigFetch = struct {
    step: std.Build.Step,
    url: []const u8,
    hash: []const u8,

    already_fetched: bool,
    pkg_path_dont_use_me_directly: []const u8,
    lazy_fetch_stdout: std.Build.LazyPath,
    generated_directory: std.Build.GeneratedFile,
    pub fn create(b: *std.Build, opt: ZigFetchOptions) *ZigFetch {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "fetch", opt.url });
        const fetch = b.allocator.create(ZigFetch) catch @panic("OOM");
        const pkg_path = b.pathJoin(&.{
            b.graph.global_cache_root.path.?,
            "p",
            opt.hash,
        });
        const already_fetched = if (std.fs.cwd().access(pkg_path, .{}))
            true
        else |err| switch (err) {
            error.FileNotFound => false,
            else => |e| std.debug.panic("access '{s}' failed with {s}", .{ pkg_path, @errorName(e) }),
        };
        fetch.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("zig fetch {s}", .{opt.url}),
                .owner = b,
                .makeFn = make,
            }),
            .url = b.allocator.dupe(u8, opt.url) catch @panic("OOM"),
            .hash = b.allocator.dupe(u8, opt.hash) catch @panic("OOM"),
            .pkg_path_dont_use_me_directly = pkg_path,
            .already_fetched = already_fetched,
            .lazy_fetch_stdout = run.captureStdOut(),
            .generated_directory = .{
                .step = &fetch.step,
            },
        };
        if (!already_fetched) {
            fetch.step.dependOn(&run.step);
        }
        return fetch;
    }
    pub fn getLazyPath(self: *const ZigFetch) std.Build.LazyPath {
        return .{ .generated = .{ .file = &self.generated_directory } };
    }
    pub fn path(self: *ZigFetch, sub_path: []const u8) std.Build.LazyPath {
        return self.getLazyPath().path(self.step.owner, sub_path);
    }
    fn make(step: *std.Build.Step, opt: std.Build.Step.MakeOptions) !void {
        _ = opt;
        const b = step.owner;
        const fetch: *ZigFetch = @fieldParentPtr("step", step);
        if (!fetch.already_fetched) {
            const sha = blk: {
                var file = try std.fs.openFileAbsolute(fetch.lazy_fetch_stdout.getPath(b), .{});
                defer file.close();
                break :blk try file.readToEndAlloc(b.allocator, 999);
            };
            const sha_stripped = std.mem.trimRight(u8, sha, "\r\n");
            if (!std.mem.eql(u8, sha_stripped, fetch.hash)) return step.fail(
                "hash mismatch: declared {s} but the fetched package has {s}",
                .{ fetch.hash, sha_stripped },
            );
        }
        fetch.generated_directory.path = fetch.pkg_path_dont_use_me_directly;
    }
};
