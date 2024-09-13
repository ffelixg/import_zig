const std = @import("std");
const builtin = @import("builtin");
const generated = @import("generated.zig");
const py_utils = @import("py_utils.zig");
const py = py_utils.py;
const zig_file = @import("inner/import_fns.zig");

var zig_ext_methods = blk: {
    var nr_methods = 0;
    for (@typeInfo(zig_file).Struct.decls) |decl| {
        const field = @field(zig_file, decl.name);
        switch (@typeInfo(@TypeOf(field))) {
            .Fn => {
                nr_methods += 1;
            },
            else => {},
        }
    }
    var methods: [nr_methods]py.PyMethodDef = undefined;
    var i_method = 0;
    for (@typeInfo(zig_file).Struct.decls) |decl| {
        const field = @field(zig_file, decl.name);
        switch (@typeInfo(@TypeOf(field))) {
            .Fn => |info| {
                const wrapper = struct {
                    fn wrapper(module: ?*py.PyObject, py_args: ?*py.PyObject) callconv(.C) ?*py.PyObject {
                        _ = module;
                        var arena = std.heap.ArenaAllocator.init(py_utils.gp_allocator);
                        defer arena.deinit();

                        comptime var types: [info.params.len]type = undefined;
                        inline for (info.params, 0..) |param, i_type| {
                            types[i_type] = param.type.?;
                        }

                        const arg_type = std.meta.Tuple(&types);
                        const args = py_utils.py_to_zig(arg_type, (py_args orelse return null), arena.allocator()) catch {
                            py_utils.raise_from(.Exception, "Error converting function arguments to zig types", .{}) catch {};
                            return null;
                        };
                        const zig_ret = @call(.always_inline, field, args);

                        const zig_ret_unwrapped = if (@typeInfo(@TypeOf(zig_ret)) == .ErrorUnion)
                            zig_ret catch |err| {
                                if (err != py_utils.PyErr.PyErr) {
                                    py_utils.raise_from(.Exception, "Zig function returned an error: {any}", .{err}) catch {};
                                }
                                return null;
                            }
                        else
                            zig_ret;

                        return py_utils.zig_to_py(zig_ret_unwrapped) catch {
                            py_utils.raise_from(.Exception, "Error converting zig return values to python types", .{}) catch {};
                            return null;
                        };
                    }
                }.wrapper;
                methods[i_method] = py.PyMethodDef{
                    .ml_name = decl.name,
                    .ml_meth = wrapper,
                    .ml_flags = py.METH_VARARGS,
                    .ml_doc = null,
                };
            },
            else => continue,
        }
        i_method += 1;
    }
    break :blk methods ++ [_]py.PyMethodDef{
        py.PyMethodDef{
            .ml_name = null,
            .ml_meth = null,
            .ml_flags = 0,
            .ml_doc = null,
        },
    };
};

var zig_ext_module = py.PyModuleDef{
    .m_base = py.PyModuleDef_Base{
        .ob_base = py.PyObject{
            // .ob_refcnt = 1,
            .ob_type = null,
        },
        .m_init = null,
        .m_index = 0,
        .m_copy = null,
    },
    .m_name = "zig_ext",
    .m_doc = null,
    .m_size = -1,
    .m_methods = &zig_ext_methods,
    .m_slots = null,
    .m_traverse = null,
    .m_clear = null,
    .m_free = null,
};

fn init() callconv(.C) ?*py.PyObject {
    return py.PyModule_Create(&zig_ext_module);
}

comptime {
    @export(init, .{ .name = "PyInit_" ++ generated.module_name, .linkage = .strong });
}
