/// This example is using the arrow C data interface, which is documented at
/// https://arrow.apache.org/docs/format/CDataInterface.html
const std = @import("std");
const pyu = @import("import_zig/py_utils.zig");
const py = pyu.py;

// Arrow moves the data buffers from producers to
// consumers, so the raw_c_allocator is forced
const ally = std.heap.raw_c_allocator;

/// If format or name are not static strings, this is where you free them
fn release_schema(self: *ArrowSchema) callconv(.c) void {
    self.release = null;
}

const ArrowSchema = extern struct {
    // Array type description
    format: [*:0]const u8,
    name: ?[*:0]const u8,
    metadata: ?[*]const u8 = null,
    flags: i64 = 0,
    n_children: i64 = 0,
    children: ?[*]*ArrowSchema = null,
    dictionary: ?[*]ArrowSchema = null,

    // Release callback
    release: ?*@TypeOf(release_schema),
    // Opaque producer-specific data
    private_data: ?*anyopaque = null,
};

/// This must be kept in sync with how the arrow array is created
fn release_array(self: *ArrowArray) callconv(.c) void {
    std.c.free(self.buffers.?[1]);
    std.c.free(@ptrCast(self.buffers));
    self.release = null;
}

const ArrowArray = extern struct {
    // Array data description
    length: i64,
    null_count: i64,
    offset: i64 = 0,
    n_buffers: i64,
    n_children: i64 = 0,
    buffers: ?[*]?*anyopaque,
    children: ?[*]*ArrowArray = null,
    dictionary: ?[*]ArrowArray = null,

    // Release callback
    release: ?*@TypeOf(release_array),
    // Opaque producer-specific data
    private_data: ?*anyopaque = null,
};

const SchemaCapsule = pyu.PyCapsule(ArrowSchema, "arrow_schema", &struct {
    fn deinit(self: *ArrowSchema) callconv(.c) void {
        if (self.release) |release|
            release(self);
    }
}.deinit);
const ArrayCapsule = pyu.PyCapsule(ArrowArray, "arrow_array", &struct {
    fn deinit(self: *ArrowArray) callconv(.c) void {
        if (self.release) |release|
            release(self);
    }
}.deinit);

/// Produce an arrow array of Fibonacci numbers
pub fn fibonaccis(num: usize) !struct { *py.PyObject, *py.PyObject } {
    const fibs = try ally.alloc(u64, num);
    errdefer ally.free(fibs);

    if (num > 0)
        fibs[0] = 0;
    if (num > 1)
        fibs[1] = 1;
    for (2..num) |i| {
        fibs[i] = fibs[i - 1] + fibs[i - 2];
    }

    const schema = ArrowSchema{
        .format = "L",
        .name = "fibonacci",
        .release = @constCast(&release_schema),
    };

    const buffers = try ally.alloc(?*anyopaque, 2);
    buffers[0] = null;
    buffers[1] = fibs.ptr;
    const array = ArrowArray{
        .length = @intCast(num),
        .null_count = 0,
        .n_buffers = 2,
        .buffers = buffers.ptr,
        .release = @constCast(&release_array),
    };

    return .{
        try SchemaCapsule.create_capsule(schema),
        try ArrayCapsule.create_capsule(array),
    };
}

/// Consume an arrow array of strings
pub fn average_string_length(schema_capsule: *py.PyObject, array_capsule: *py.PyObject) !f64 {
    // This data is borrowed and will be freed when the capsule is garbage collected
    const schema: *ArrowSchema = try SchemaCapsule.read_capsule(schema_capsule);
    const array: *ArrowArray = try ArrayCapsule.read_capsule(array_capsule);

    if (!std.mem.eql(u8, std.mem.span(schema.format), "u"))
        return error.ExpectedUnicodeStringSchema;

    const string_offsets: [*]u32 = @ptrCast(@alignCast(array.buffers.?[1]));

    // This is usually 0, but doesn't have to be
    const start: f64 = @floatFromInt(string_offsets[0]);
    const end: f64 = @floatFromInt(string_offsets[@intCast(array.length)]);
    const length: f64 = @floatFromInt(array.length);
    return (end - start) / length;
}
