const std = @import("std");
pub const py = @cImport({
    @cDefine("Py_LIMITED_API", "0x030a00f0");
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
pub const gp_allocator = gpa.allocator();

pub const PyErr = error{PyErr};
const Exceptions = enum { Exception, NotImplemented, TypeError, ValueError };

pub fn raise_args(exc: Exceptions, comptime msg: []const u8, args: anytype) PyErr {
    @setCold(true);
    const pyexc = switch (exc) {
        .Exception => py.PyExc_Exception,
        .NotImplemented => py.PyExc_NotImplementedError,
        .TypeError => py.PyExc_TypeError,
        .ValueError => py.PyExc_ValueError,
    };
    const formatted = std.fmt.allocPrintZ(gp_allocator, msg, args) catch "Error formatting error message";
    defer gp_allocator.free(formatted);
    py.PyErr_SetString(pyexc, formatted.ptr);
    return PyErr.PyErr;
}

pub fn raise(exc: Exceptions, comptime msg: []const u8) PyErr {
    return raise_args(exc, msg, .{});
}

pub fn raise_from(exc: Exceptions, comptime msg: []const u8, args: anytype) PyErr {
    const xc1 = py.PyErr_GetRaisedException();
    raise_args(exc, msg, args) catch {};
    const xc2 = py.PyErr_GetRaisedException();
    py.PyException_SetCause(xc2, xc1);
    py.PyErr_SetRaisedException(xc2);
    return PyErr.PyErr;
}

var struct_tuple_map = std.StringHashMap(?*py.PyTypeObject).init(gp_allocator);

/// Steals a reference when passed PyObjects
pub fn zig_to_py(value: anytype) !*py.PyObject {
    // @compileLog("val: {any}, type: {any}\n", value, @typeInfo(@TypeOf(value)));
    return switch (@typeInfo(@TypeOf(value))) {
        .Int => |info| if (info.signedness == .signed) py.PyLong_FromLongLong(@as(c_longlong, value)) else py.PyLong_FromUnsignedLongLong(@as(c_ulonglong, value)),
        .ComptimeInt => if (value < 0) py.PyLong_FromLongLong(@as(c_longlong, value)) else py.PyLong_FromUnsignedLongLong(@as(c_ulonglong, value)),
        .Pointer => |info| if (info.child == u8 and info.size == .Slice)
            py.PyUnicode_FromStringAndSize(value.ptr, @intCast(value.len))
        else if (info.child == py.PyObject and info.size == .One)
            @as(?*py.PyObject, value)
        else if (info.size == .Slice) blk: {
            const ret = py.PyList_New(@intCast(value.len)) orelse return PyErr.PyErr;
            errdefer py.Py_DECREF(ret);
            for (value, 0..) |entry, i_entry| {
                const py_entry = try zig_to_py(entry);
                if (py.PyList_SetItem(ret, @intCast(i_entry), py_entry) == -1) {
                    py.Py_DECREF(py_entry);
                    return PyErr.PyErr;
                }
            }
            break :blk ret;
        } else unreachable,
        .Struct => |info| blk: {
            if (info.is_tuple) {
                const tuple = py.PyTuple_New(info.fields.len) orelse return PyErr.PyErr;
                errdefer py.Py_DECREF(tuple);
                inline for (info.fields, 0..) |field, i_field| {
                    const py_value = try zig_to_py(@field(value, field.name));
                    if (py.PyTuple_SetItem(tuple, @intCast(i_field), py_value) == -1) {
                        py.Py_DECREF(py_value);
                        return PyErr.PyErr;
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
                        .name = type_name,
                        .fields = &fields,
                    };
                    const tp = py.PyStructSequence_NewType(&desc) orelse return PyErr.PyErr;

                    try struct_tuple_map.put(type_name, tp);

                    break :blk_tp tp;
                };

                const tuple = py.PyStructSequence_New(tuple_type) orelse return PyErr.PyErr;
                errdefer py.Py_DECREF(tuple);
                inline for (info.fields, 0..) |field, i_field| {
                    const py_value = try zig_to_py(@field(value, field.name));
                    py.PyStructSequence_SetItem(tuple, @intCast(i_field), py_value);
                }
                break :blk tuple;
            }
        },
        .Void => py.Py_NewRef(py.Py_None()),
        .Float => py.PyFloat_FromDouble(@floatCast(value)),
        else => |info| {
            @compileLog("unsupported py-type conversion", info);
            comptime unreachable;
        },
    } orelse return PyErr.PyErr;
}

/// Parse Python value into Zig type. Memory management for strings is handled by Python.
/// This also means that once the original Python string is garbage collected the pointer is dangling.
/// Similary, when a PyObject is requested, the reference is borrowed.
pub fn py_to_zig(zig_type: type, py_value: *py.PyObject, allocator: ?std.mem.Allocator) !zig_type {
    switch (@typeInfo(zig_type)) {
        .Int => |info| {
            const val = if (info.signedness == .signed) py.PyLong_AsLongLong(py_value) else py.PyLong_AsUnsignedLongLong(py_value);
            if (py.PyErr_Occurred() != null) {
                return PyErr.PyErr;
            }
            return std.math.cast(zig_type, val) orelse return raise(.ValueError, "Expected smaller integer");
        },
        .Pointer => |info| {
            switch (info.size) {
                .One => {
                    if (info.child == py.PyObject) {
                        return py_value;
                    } else @compileError("Only PyObject is supported for One-Pointer");
                },
                .Many => @compileError("Many Pointer not supported"),
                .Slice => {
                    if (info.child == u8) {
                        var size: py.Py_ssize_t = -1;
                        const char_ptr = py.PyUnicode_AsUTF8AndSize(py_value, &size) orelse return PyErr.PyErr;
                        if (size < 0) {
                            return PyErr.PyErr;
                        }
                        return char_ptr[0..@intCast(size)];
                    } else {
                        const len: usize = blk: {
                            const py_len = py.PyObject_Length(py_value);
                            if (py_len < 0) {
                                return PyErr.PyErr;
                            }
                            break :blk @intCast(py_len);
                        };
                        const slice = allocator.?.alloc(info.child, len) catch {
                            _ = py.PyErr_NoMemory();
                            return PyErr.PyErr;
                        };
                        for (slice, 0..) |*entry, i_entry| {
                            const py_entry = py.PySequence_GetItem(py_value, @intCast(i_entry)) orelse return PyErr.PyErr;
                            entry.* = try py_to_zig(info.child, py_entry, allocator);
                        }
                        return slice;
                    }
                },
                .C => @compileError("C Pointer not supported"),
            }
        },
        .Struct => |info| {
            var zig_value: zig_type = undefined;
            if (info.fields.len == 0) {
                return zig_value;
            }
            if (py.PyDict_Check(py_value) != 0) {
                comptime var n_fields = 0;
                inline for (info.fields) |field| {
                    // Magic trick to pass in an allocator
                    if (field.type == std.mem.Allocator) {
                        @field(zig_value, field.name) = allocator.?;
                        continue;
                    }
                    const py_value_inner = py.PyDict_GetItemString(
                        py_value,
                        field.name,
                    ) orelse {
                        return raise_args(.TypeError, "Could not get dict value for key={s}", .{field.name});
                    };
                    @field(zig_value, field.name) = try py_to_zig(
                        field.type,
                        py_value_inner,
                        allocator,
                    );
                    n_fields += 1;
                }
                switch (py.PyObject_Length(py_value)) {
                    -1 => return PyErr.PyErr,
                    n_fields => return zig_value,
                    else => return raise(.TypeError, "Dict length does not match struct length"),
                }
            } else {
                comptime var n_fields = 0;
                inline for (info.fields) |field| {
                    // Magic trick to pass in an allocator
                    if (field.type == std.mem.Allocator) {
                        @field(zig_value, field.name) = allocator.?;
                        continue;
                    }
                    const py_value_inner = py.PySequence_GetItem(py_value, n_fields) orelse return PyErr.PyErr;
                    defer py.Py_DECREF(py_value_inner);
                    @field(zig_value, field.name) = try py_to_zig(
                        field.type,
                        py_value_inner,
                        allocator,
                    );
                    n_fields += 1;
                }
                switch (py.PyObject_Length(py_value)) {
                    -1 => return PyErr.PyErr,
                    n_fields => return zig_value,
                    else => return raise(.TypeError, "Sequence length does not match struct length"),
                }
                return zig_value;
            }
        },
        .Float => {
            const val: zig_type = @floatCast(py.PyFloat_AsDouble(py_value));
            if (py.PyErr_Occurred() != null) {
                return PyErr.PyErr;
            }
            return val;
        },
        else => {},
    }
    @compileLog("Unsupported conversion from py to zig", @typeInfo(zig_type));
    comptime unreachable;
}
