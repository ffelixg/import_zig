const std = @import("std");
const builtin = @import("builtin");
const pyu = @import("py");
const py = pyu.py;
const zig_file = @import("src");

const MyNode = struct {
    node: std.SinglyLinkedList.Node,
    data: py.PyMethodDef,
};

fn list_to_arr(T: type, list: *std.SinglyLinkedList) [list.len()]T {
    var arr: [list.len()]T = undefined;
    var idx: usize = list.len();
    while (list.popFirst()) |node| {
        idx -= 1;
        const my_node: *MyNode = @fieldParentPtr("node", node);
        arr[idx] = my_node.data;
    }
    std.debug.assert(idx == 0);
    return arr;
}

var zig_ext_methods = blk: {
    var methods = std.SinglyLinkedList{};

    for (@typeInfo(zig_file).@"struct".decls) |fn_decl| {
        const zig_func = @field(zig_file, fn_decl.name);
        if (@typeInfo(@TypeOf(zig_func)) != .@"fn") continue;
        const fn_info = @typeInfo(@TypeOf(zig_func)).@"fn";

        var i_allocator: isize = -1;
        const arg_type = std.meta.Tuple(&T: {
            var types: [fn_info.params.len]type = undefined;
            for (fn_info.params, 0..) |param, i_type| {
                const T = param.type.?;
                types[i_type] = T;
                if (T == std.mem.Allocator) {
                    if (i_allocator != -1) {
                        @compileError("Can only request allocator once per function");
                    }
                    i_allocator = i_type;
                }
            }
            break :T types;
        });

        const n_py_args = if (i_allocator != -1) fn_info.params.len - 1 else fn_info.params.len;

        const wrapper = struct {
            fn wrapper(_: ?*py.PyObject, py_args: [*]*py.PyObject, n_py_args_runtime: isize) callconv(.c) ?*py.PyObject {
                var arena = std.heap.ArenaAllocator.init(std.heap.raw_c_allocator);
                defer arena.deinit();
                const allocator = arena.allocator();
                var args: arg_type = undefined;
                if (n_py_args != n_py_args_runtime) {
                    pyu.raise(.Exception, "Expected {} arguments, received {}", .{ n_py_args, n_py_args_runtime }) catch {};
                    return null;
                }
                inline for (@typeInfo(arg_type).@"struct".fields, 0..) |field, i_field| {
                    if (i_field == i_allocator) {
                        @field(args, field.name) = allocator;
                        continue;
                    }
                    const py_arg = py_args[i_field - @intFromBool(i_allocator != -1 and i_field > i_allocator)];
                    @field(args, field.name) = pyu.py_to_zig(field.type, py_arg, allocator) catch {
                        pyu.raise(.Exception, "Error converting function arguments to zig types", .{}) catch {};
                        return null;
                    };
                }

                const zig_ret = @call(.always_inline, zig_func, args);

                const zig_ret_unwrapped = if (@typeInfo(@TypeOf(zig_ret)) == .error_union)
                    zig_ret catch |err| {
                        if (err != pyu.PyErr) {
                            pyu.raise(.Exception, "{s}", .{@errorName(err)}) catch {};
                        }
                        return null;
                    }
                else
                    zig_ret;

                return pyu.zig_to_py(zig_ret_unwrapped) catch {
                    pyu.raise(.Exception, "Error converting zig return values to python types", .{}) catch {};
                    return null;
                };
            }
        }.wrapper;

        var my_node = MyNode{
            .data = py.PyMethodDef{
                .ml_name = fn_decl.name,
                .ml_meth = @ptrCast(&wrapper),
                .ml_flags = py.METH_FASTCALL,
                .ml_doc = null,
            },
            .node = .{},
        };
        methods.prepend(&my_node.node);
    }
    var my_node = MyNode{
        .data = py.PyMethodDef{
            .ml_name = null,
            .ml_meth = null,
            .ml_flags = 0,
            .ml_doc = null,
        },
        .node = .{},
    };
    methods.prepend(&my_node.node);
    break :blk list_to_arr(py.PyMethodDef, &methods);
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

fn init() callconv(.c) ?*py.PyObject {
    const module = py.PyModule_Create(&zig_ext_module);
    return module;
}

comptime {
    @export(&init, .{ .name = "PyInit_" ++ pyu.module_name, .linkage = .strong });
}
