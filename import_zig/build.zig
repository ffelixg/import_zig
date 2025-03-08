const std = @import("std");
const generated = @import("generated.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });

    const mod = b.createModule(.{
        .root_source_file = b.path("zig_ext.zig"),
        .target = target,
        .optimize = optimize,
    });
    inline for (generated.imports) |name| {
        const dep = b.dependency(name, .{
            .target = target,
            .optimize = optimize,
        });
        mod.addImport(name, dep.module(name));
    }

    const lib = b.addSharedLibrary(.{
        .name = "zig_ext",
        .root_module = mod,
    });
    lib.linkLibC();

    inline for (generated.include) |path| {
        lib.addIncludePath(.{ .cwd_relative = path });
    }
    if (target.query.os_tag == .windows) {
        inline for (generated.lib) |path| {
            lib.addLibraryPath(.{ .cwd_relative = path });
        }
        lib.linkSystemLibrary2("python3", .{ .needed = true, .preferred_link_mode = .static });
    }
    lib.linker_allow_shlib_undefined = true;
    b.installArtifact(lib);
}
