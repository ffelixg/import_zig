const std = @import("std");
const generated = @import("generated.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });

    const py = b.createModule(.{
        .root_source_file = b.path("py_utils.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mod = b.createModule(.{
        .root_source_file = b.path("zig_ext.zig"),
        .target = target,
        .optimize = optimize,
    });
    const src = b.createModule(.{
        .root_source_file = b.path("../import_fns.zig"),
        .target = target,
        .optimize = optimize,
    });
    src.addImport("py", py);
    mod.addImport("src", src);
    mod.addImport("py", py);
    inline for (generated.imports) |name| {
        const dep = b.dependency(name, .{
            .target = target,
            .optimize = optimize,
        });
        src.addImport(name, dep.module(name));
    }

    const lib = b.addSharedLibrary(.{
        .name = "zig_ext",
        .root_module = mod,
    });
    lib.linkLibC();

    inline for (generated.include) |path| {
        py.addIncludePath(.{ .cwd_relative = path });
    }
    if (target.query.os_tag == .windows) {
        inline for (generated.lib) |path| {
            py.addLibraryPath(.{ .cwd_relative = path });
        }
        py.linkSystemLibrary("python3", .{});
    }
    lib.linker_allow_shlib_undefined = true;
    b.installArtifact(lib);
}
