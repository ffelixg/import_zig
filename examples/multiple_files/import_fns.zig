const dependency = @import("dependency.zig");

pub fn add_constant(x: i64) i64 {
    return x + dependency.val;
}
