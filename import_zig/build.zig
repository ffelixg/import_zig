const std = @import("std");
const generated = @import("zig_ext/generated.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c_tran = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("zig_ext/c.h"),
    });
    inline for (generated.include) |path| {
        c_tran.addIncludePath(.{ .cwd_relative = path });
    }

    const c_mod = c_tran.createModule();
    if (target.query.os_tag == .windows) {
        inline for (generated.lib) |path| {
            c_mod.addLibraryPath(.{ .cwd_relative = path });
        }
        c_mod.linkSystemLibrary("python3", .{});
    }

    const py_mod = b.addModule("py", .{
        .root_source_file = b.path("zig_ext/py_utils.zig"),
        .target = target,
        .optimize = optimize,
    });
    py_mod.addImport("c", c_mod);

    const src = b.createModule(.{
        .root_source_file = b.path(generated.root_source_file),
        .target = target,
        .optimize = optimize,
    });
    inline for (generated.imports) |name| {
        const dep = b.dependency(name, .{
            .target = target,
            .optimize = optimize,
        });
        src.addImport(name, dep.module(name));
    }
    src.addImport("c", c_mod);
    src.addImport("py", py_mod);

    const mod = b.createModule(.{
        .root_source_file = b.path("zig_ext/zig_ext.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("c", c_mod);
    mod.addImport("py", py_mod);
    mod.addImport("src", src);

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zig_ext",
        .root_module = mod,
    });
    lib.linkLibC();

    lib.linker_allow_shlib_undefined = true;
    b.installArtifact(lib);
}
