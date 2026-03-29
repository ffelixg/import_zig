# import-zig

```bash
pip install import-zig
```

`import_zig` provides the simplest possible interface for compiling and importing Zig code into Python, to enable easy experimentation and prototyping.

Additionally, the `compile_to` function outputs a compiled Python extension module for the target interpreter, which can be integrated into a larger Python package. [Here](https://github.com/ffelixg/zodbc_py/blob/f263a1a154f1273e5bb8cef34b652ebb09a40c27/setup.py) is a `setup.py` of a Python package using `compile_to` in this way.

One fun thing about creating Python extensions with Zig is that you don't need to install or set up any compiler toolchain to use or build a module. The entire Zig compiler is a simple dependency on the `ziglang` Python package, which is the only dependency of `import-zig`.

## Requirements

- Python 3.10 or newer.
- The package installs and invokes `ziglang==0.15.1`.
- Python development headers must be available so Zig can compile against the Python C API. On Linux this usually means installing `python3-dev` or `python3-devel`.

## Quick start

```py
from import_zig import import_zig

mod = import_zig(source_code="""
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

## Choosing an input mode

Exactly one of `source_code`, `file`, or `directory` must be passed to `import_zig()` or `compile_to()`.

- `source_code`: compile an inline Zig source string.
- `file`: compile a single `.zig` file.
- `directory`: compile a multi-file Zig project. This argument is a mapping with:
  - `path`: directory containing your Zig sources.
  - `root_source_file`: entry-point Zig file inside that directory.

Example using a directory:

```py
from import_zig import import_zig

module = import_zig(
    directory={
        "path": "multiple_files",
        "root_source_file": "import_fns.zig",
    },
)
```

## Development workflow with `prepare`

`prepare()` writes the Zig build scaffolding into an existing directory so you can work on a Zig project with editor support and compile it later with `compile_prepared()`.

```py
import import_zig

import_zig.prepare(
    "/path/to/project_folder",
    "module_name",
    "root_source_file.zig",
)
```

This generates the following files alongside your own Zig source tree:

```bash
project_folder
├── root_source_file.zig
├── build.zig
├── build.zig.zon
└── zig_ext
    ├── c.h
    ├── generated.zig
    ├── .gitignore
    ├── py_utils.zig
    └── zig_ext.zig
```

`root_source_file.zig` is your entry point and is never overwritten by `prepare()`. `build.zig`, `build.zig.zon`, and `zig_ext/` are regenerated to match the current Python environment. On non-Windows platforms they are symlinked by default; on Windows, or when `force_copy=True`, they are copied instead.

This setup enables ZLS support for `@import("c")` and `@import("py")` inside your Zig sources.

## Compiling to a reusable extension

Use `compile_to()` when you want a compiled extension file in a target directory instead of importing it immediately:

```py
from import_zig import compile_to

compile_to(
    target_dir=".",
    module_name="my_module",
    file="single_file.zig",
)
```

The produced binary is platform-specific and will use Python's extension suffix for the current interpreter.

Use `compile_prepared(target_dir, cwd)` after a `prepare()` workflow. `cwd` must point at the prepared Zig project directory.

## Build options and dependencies

The `optimize` argument is accepted by `import_zig()`, `compile_to()`, and `compile_prepared()`. Supported values are:

- `Optimize.Debug`
- `Optimize.ReleaseSafe`
- `Optimize.ReleaseFast`
- `Optimize.ReleaseSmall`

`imports` can be passed to `prepare()`, `import_zig()`, or `compile_to()` to populate `build.zig.zon` dependencies for Zig packages. Each dependency entry is written directly into the generated `.dependencies` section. If an import spec contains a `path` entry, it is rewritten relative to the prepared build directory.

## Type mapping and Python interop

The conversion rules live in `zig_ext/py_utils.zig` and are applied based on the parameter and return types of exported `pub fn` functions. Nested conversions are handled recursively.

| Conversion from Python | Zig datatype | Conversion to Python |
| --- | --- | --- |
| `int` | integer (any size / sign) | `int` |
| `float` | float (any size) | `float` |
| `bool(value)` semantics | `bool` | `bool` |
| sequence | array | `list` |
| sequence | non-`u8` slice | `list` |
| `str` | `[]const u8` | `str` |
| dict or sequence | `struct` | struct-like Python object, or tuple for Zig tuple structs |
| `None` | optional | `null` becomes `None` |
| not applicable | `void` | `None` |

Additional interop behavior:

- If a function accepts `std.mem.Allocator`, an arena allocator is provided for the duration of the call. This lets the Zig code allocate return data such as string slices whose contents are converted to a Python string before the arena is deinitialized.
- Raw Python objects can be handled directly with `*c.PyObject` after importing `c` or `py`.
- Zig errors are forwarded to Python exceptions. Returning `error.SomeName` becomes a Python exception, and `py_utils.zig` also exposes helpers for raising Python exceptions explicitly.

## Python C API helpers

Inside compiled Zig code you can use:

```zig
const c = @import("c");
const pyu = @import("py");
const py = pyu.py;
```

This gives access to the Python C API and the helper utilities bundled in `py_utils.zig`, including conversion helpers, exception helpers, and support used by the Arrow example in `examples/arrow_example.zig`.

## Examples

See `examples/basic_usage.ipynb` for the main API surface, `examples/prepare_development.ipynb` for the prepared-project workflow, and `examples/arrow_example.zig` plus `examples/arrow_example.ipynb` for lower-level Python C API interop.
