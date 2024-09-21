# import-zig

    pip install import-zig

This module provides a way to import Zig code directly into Python using a single function call to `import_zig`. Here is an example:

```py
from import_zig import import_zig

mod = import_zig(source_code = """
    pub fn Q_rsqrt(number: f32) f32 {
        const threehalfs: f32 = 1.5;
        const x2 = number * 0.5;
        var y = number;
        var i: i32 = @bitCast(y);
        i = 0x5f3759df - (i >> 1);
        y = @bitCast(i);
        y = y * (threehalfs - (x2 * y * y));

        return y;
    }
""")

print(f"1 / sqrt(1.234) = {mod.Q_rsqrt(1.234)}")
```

The main goal of this module is to make it easy to prototype Zig extensions for Python without having to engage with the Python build system. When building larger Zig extensions it is likely preferable to write your own build process with setuptools or to use a ziggy-pydust template, which provides a comptime abstraction over many aspects of the Python C API. Zig and Zig extensions are still very new though, so things will likely change. Technically you could also use this module as part of a packaging step by calling the `compile_to` function to build the binary and moving it into the packages build folder.

One approach that I expect to stay the same is the comptime wrapping for conversion between Zig and Python types as well as exception handling. This is conveniently packed into the file `py_utils.zig` and could be copy pasted into a new setuptools based project and maybe adjusted.

See the docs of the import_zig function for more details or check out the examples directory.

# File structure

The file structure that will be generated to compile the Zig code looks as follows.

```bash
project_folder
├── build.zig
├── generated.zig
├── inner
│   └── import_fns.zig
├── py_utils.zig
└── zig_ext.zig
```

The `inner` directory is where your code lives. When you pass a source code string or file path, it will be written / linked as the `import_fns.zig` file. When you pass a directory path, the directory will be linked as the `inner` directory above, enabling references to other files in the directory path.

The above file structure can be generated with:

```py
import_zig.prepare("/path/to/project_folder", "module_name")
```

This enables ZLS support for the Python C API when importing `py_utils` from `import_fns.zig`.

# Type mapping

The conversion is defined in `py_utils.zig` and applied based on the parameter / return types of the exported function. Errors are also forwarded. The solution to passing variable length data back to Python is a bit of a hack: When an exported function specifies `std.mem.Allocator` as a parameter type, then an arena allocator - which gets deallocated after the function call - will be passed into the function. The allocator can then be used to allocate and return new slices for example.

For nested types, the conversion is applied recursively.

| Conversion from Python                  | Zig datatype                      | Conversion to Python                          |
| --------------------------------------- | --------------------------------- | --------------------------------------------- |
| int                                     | integer (any size / sign)         | int                                           |
| float                                   | float (any size)                  | float                                         |
| -                                       | void                              | None                                          |
| evaluated like bool()                   | bool                              | bool                                          |
| sequence                                | array                             | list                                          |
| sequence                                | non u8 const slice                | list                                          |
| str                                     | u8 const slice                    | str                                           |
| dict or sequence                        | struct                            | tuple if struct is a tuple or named tuple     |
| comparison with None                    | optional                          | null -> None                                  |
