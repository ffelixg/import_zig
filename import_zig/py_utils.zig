const std = @import("std");
pub const py = @cImport({
    @cDefine("Py_LIMITED_API", "0x030a00f0");
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

pub const PyErr = error.PyErr;
const Exceptions = enum { Exception, NotImplemented, TypeError, ValueError };

pub fn raise(exc: Exceptions, comptime msg: []const u8, args: anytype) error{PyErr} {
    @branchHint(.cold);
    const pyexc = switch (exc) {
        .Exception => py.PyExc_Exception,
        .NotImplemented => py.PyExc_NotImplementedError,
        .TypeError => py.PyExc_TypeError,
        .ValueError => py.PyExc_ValueError,
    };
    const formatted = std.fmt.allocPrintZ(std.heap.raw_c_allocator, msg, args) catch "Error formatting error message";
    defer std.heap.raw_c_allocator.free(formatted);

    // new in Python 3.12, for older versions we just overwrite exceptions.
    if (@hasField(py, "PyErr_GetRaisedException")) {
        const cause = py.PyErr_GetRaisedException();
        py.PyErr_SetString(pyexc, formatted.ptr);
        if (cause) |_| {
            const consequence = py.PyErr_GetRaisedException();
            py.PyException_SetCause(consequence, cause);
            py.PyErr_SetRaisedException(consequence);
        }
    } else {
        py.PyErr_SetString(pyexc, formatted.ptr);
    }
    return PyErr;
}

pub fn PyCapsule(T: type, name: [*c]const u8, deinit: ?*const fn (*T) callconv(.c) void) type {
    return struct {
        fn py_free(capsule: ?*py.PyObject) callconv(.c) void {
            const ptr = read_capsule(capsule orelse unreachable) catch unreachable;
            defer std.heap.raw_c_allocator.destroy(ptr);
            if (deinit != null) deinit.?(ptr);
        }
        pub fn read_capsule(capsule: *py.PyObject) !*T {
            return @alignCast(@ptrCast(py.PyCapsule_GetPointer(capsule, name) orelse return PyErr));
        }
        pub fn create_capsule(data: T) !*py.PyObject {
            const ptr = std.heap.raw_c_allocator.create(T) catch {
                _ = py.PyErr_NoMemory();
                return PyErr;
            };
            ptr.* = data;
            return py.PyCapsule_New(
                @ptrCast(ptr),
                name,
                &py_free,
            ) orelse return PyErr;
        }
    };
}

fn toPyList(value: anytype) !*py.PyObject {
    const pylist = py.PyList_New(@intCast(value.len)) orelse return PyErr;
    errdefer py.Py_DECREF(pylist);
    for (value, 0..) |entry, i_entry| {
        const py_entry = try zig_to_py(entry);
        if (py.PyList_SetItem(pylist, @intCast(i_entry), py_entry) == -1) {
            py.Py_DECREF(py_entry);
            return PyErr;
        }
    }
    return pylist;
}

var struct_tuple_map = std.StringHashMap(?*py.PyTypeObject).init(std.heap.raw_c_allocator);

/// Steals a reference when passed PyObjects
pub fn zig_to_py(value: anytype) !*py.PyObject {
    return switch (@typeInfo(@TypeOf(value))) {
        .int => |info| if (info.signedness == .signed) py.PyLong_FromLongLong(@as(c_longlong, value)) else py.PyLong_FromUnsignedLongLong(@as(c_ulonglong, value)),
        .comptime_int => if (value < 0) py.PyLong_FromLongLong(@as(c_longlong, value)) else py.PyLong_FromUnsignedLongLong(@as(c_ulonglong, value)),
        .void => py.Py_NewRef(py.Py_None()),
        .float => py.PyFloat_FromDouble(@floatCast(value)),
        .comptime_float => py.PyFloat_FromDouble(@floatCast(value)),
        .bool => py.PyBool_FromLong(@intFromBool(value)),
        .optional => if (value) |v| zig_to_py(v) catch null else py.Py_NewRef(py.Py_None()),
        .array => |info| if (info.sentinel_ptr) |_|
            @compileError("Sentinel is not supported")
        else
            toPyList(value) catch null,
        .pointer => |info| if (info.child == u8 and info.size == .slice)
            py.PyUnicode_FromStringAndSize(value.ptr, @intCast(value.len))
        else if (info.child == py.PyObject and info.size == .one)
            @as(?*py.PyObject, value)
        else if (info.size == .slice)
            toPyList(value) catch null
        else
            unreachable,
        .@"struct" => |info| blk: {
            if (info.is_tuple) {
                const tuple = py.PyTuple_New(info.fields.len) orelse return PyErr;
                errdefer py.Py_DECREF(tuple);
                inline for (info.fields, 0..) |field, i_field| {
                    const py_value = try zig_to_py(@field(value, field.name));
                    if (py.PyTuple_SetItem(tuple, @intCast(i_field), py_value) == -1) {
                        py.Py_DECREF(py_value);
                        return PyErr;
                    }
                }
                break :blk tuple;
            } else {
                const type_name = @typeName(@TypeOf(value));
                const tuple_type = struct_tuple_map.get(type_name) orelse blk_tp: {
                    var fields: [info.fields.len + 1]py.PyStructSequence_Field = undefined;
                    fields[fields.len - 1] = py.PyStructSequence_Field{ .doc = null, .name = null };
                    inline for (info.fields, 0..) |field, i_field| {
                        fields[i_field] = py.PyStructSequence_Field{
                            .doc = "Zig type for this field is " ++ @typeName(field.type),
                            .name = field.name,
                        };
                    }

                    var desc: py.PyStructSequence_Desc = .{
                        .doc = "Generated in order to convert Zig struct " ++ type_name ++ " to Python object",
                        .n_in_sequence = fields.len - 1,
                        // Fully qualified name would be too verbose
                        .name = comptime name: {
                            var name: []const u8 = undefined;
                            var tokenizer = std.mem.tokenizeScalar(u8, type_name, '.');
                            while (tokenizer.next()) |token| {
                                name = token;
                            }
                            break :name "import_zig." ++ name ++ "";
                        },
                        .fields = &fields,
                    };
                    const tp = py.PyStructSequence_NewType(&desc) orelse return PyErr;

                    try struct_tuple_map.put(type_name, tp);

                    break :blk_tp tp;
                };

                const tuple = py.PyStructSequence_New(tuple_type) orelse return PyErr;
                errdefer py.Py_DECREF(tuple);
                inline for (info.fields, 0..) |field, i_field| {
                    const py_value = try zig_to_py(@field(value, field.name));
                    py.PyStructSequence_SetItem(tuple, @intCast(i_field), py_value);
                }
                break :blk tuple;
            }
        },
        else => |info| {
            @compileLog("unsupported py-type conversion", info);
            comptime unreachable;
        },
    } orelse return PyErr;
}

/// Parse Python value into Zig type. Memory management for strings is handled by Python.
/// This also means that once the original Python string is garbage collected the pointer is dangling.
/// Similary, when a PyObject is requested, the reference is borrowed.
pub fn py_to_zig(zig_type: type, py_value: *py.PyObject, allocator: ?std.mem.Allocator) !zig_type {
    switch (@typeInfo(zig_type)) {
        .int => |info| {
            const val = if (info.signedness == .signed) py.PyLong_AsLongLong(py_value) else py.PyLong_AsUnsignedLongLong(py_value);
            if (py.PyErr_Occurred() != null) {
                return PyErr;
            }
            return std.math.cast(zig_type, val) orelse return raise(.ValueError, "Expected integer to fit into {any}", .{zig_type});
        },
        .float => {
            const val: zig_type = @floatCast(py.PyFloat_AsDouble(py_value));
            if (py.PyErr_Occurred() != null) {
                return PyErr;
            }
            return val;
        },
        .bool => {
            switch (py.PyObject_IsTrue(py_value)) {
                -1 => return PyErr,
                0 => return false,
                1 => return true,
                else => unreachable,
            }
        },
        .optional => |info| {
            switch (py.Py_IsNone(py_value)) {
                1 => return null,
                0 => return try py_to_zig(info.child, py_value, allocator),
                else => unreachable,
            }
        },
        .array => |info| {
            if (info.sentinel_ptr) |_| @compileError("Sentinel is not supported");
            switch (py.PyObject_Length(py_value)) {
                -1 => return PyErr,
                info.len => {},
                else => |len| return raise(.TypeError, "Sequence had length {}, expected {}", .{ len, info.len }),
            }
            var zig_value: zig_type = undefined;
            for (0..info.len) |i| {
                const py_value_inner = py.PySequence_GetItem(py_value, @intCast(i)) orelse return PyErr;
                defer py.Py_DECREF(py_value_inner);
                zig_value[i] = try py_to_zig(info.child, py_value_inner, allocator);
            }
            return zig_value;
        },
        .pointer => |info| {
            switch (info.size) {
                .one => {
                    if (info.child == py.PyObject) {
                        return py_value;
                    } else @compileError("Only PyObject is supported for One-Pointer");
                },
                .many => @compileError("Many Pointer not supported"),
                .slice => {
                    if (info.child == u8) {
                        var size: py.Py_ssize_t = -1;
                        const char_ptr = py.PyUnicode_AsUTF8AndSize(py_value, &size) orelse return PyErr;
                        if (size < 0) {
                            return PyErr;
                        }
                        return char_ptr[0..@intCast(size)];
                    } else {
                        const len: usize = blk: {
                            const py_len = py.PyObject_Length(py_value);
                            if (py_len < 0) {
                                return PyErr;
                            }
                            break :blk @intCast(py_len);
                        };
                        const slice = allocator.?.alloc(info.child, len) catch {
                            _ = py.PyErr_NoMemory();
                            return PyErr;
                        };
                        for (slice, 0..) |*entry, i_entry| {
                            const py_entry = py.PySequence_GetItem(py_value, @intCast(i_entry)) orelse return PyErr;
                            entry.* = try py_to_zig(info.child, py_entry, allocator);
                        }
                        return slice;
                    }
                },
                .c => @compileError("C Pointer not supported"),
            }
        },
        .@"struct" => |info| {
            var zig_value: zig_type = undefined;
            if (info.fields.len == 0) {
                return zig_value;
            }
            if (py.PyDict_Check(py_value) != 0) {
                comptime var n_fields = 0;
                inline for (info.fields) |field| {
                    const py_value_inner = py.PyDict_GetItemString(
                        py_value,
                        field.name,
                    ) orelse {
                        return raise(.TypeError, "Could not get dict value for key={s}", .{field.name});
                    };
                    @field(zig_value, field.name) = try py_to_zig(
                        field.type,
                        py_value_inner,
                        allocator,
                    );
                    n_fields += 1;
                }
                switch (py.PyObject_Length(py_value)) {
                    -1 => return PyErr,
                    n_fields => return zig_value,
                    else => |len| return raise(.TypeError, "Dict had length {}, expected {}", .{ len, n_fields }),
                }
            } else {
                comptime var n_fields = 0;
                inline for (info.fields) |field| {
                    const py_value_inner = py.PySequence_GetItem(py_value, n_fields) orelse return PyErr;
                    defer py.Py_DECREF(py_value_inner);
                    @field(zig_value, field.name) = try py_to_zig(
                        field.type,
                        py_value_inner,
                        allocator,
                    );
                    n_fields += 1;
                }
                switch (py.PyObject_Length(py_value)) {
                    -1 => return PyErr,
                    n_fields => return zig_value,
                    else => |len| return raise(.TypeError, "Sequence had length {}, expected {}", .{ len, n_fields }),
                }
                return zig_value;
            }
        },
        else => {},
    }
    @compileLog("Unsupported conversion from py to zig", @typeInfo(zig_type));
    comptime unreachable;
}
