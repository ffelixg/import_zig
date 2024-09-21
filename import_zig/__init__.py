from pathlib import Path
from shutil import copyfile
from tempfile import TemporaryDirectory
from importlib import import_module
import sysconfig
import sys
import subprocess
import random

_copy_paths = [
    Path(__file__).parent / "build.zig",
    Path(__file__).parent / "py_utils.zig",
    Path(__file__).parent / "zig_ext.zig",
]


def _escape(path: str) -> str:
    return path.replace("\\", "\\\\")


def prepare(path: str | Path, module_name: str, symlink_only: bool = False):
    """
    Link/Create files at path needed to compile the Zig code

    In order to get ZLS support for the Python C API, you can execute this and
    develop inside the "inner" directory.
    """
    path = Path(path)
    if not path.exists():
        path.mkdir()

    for src in _copy_paths:
        tgt = path / src.name
        if symlink_only:
            (tgt).symlink_to(src)
        else:
            copyfile(src, tgt)

    (path / "inner").mkdir()

    include_dirs = [sysconfig.get_path("include")]
    lib_paths = [
        str(Path(sysconfig.get_config_var("installed_base"), "Libs").absolute())
    ]

    with (path / "generated.zig").open("w") as f:
        f.write(
            f"pub const include: [{len(include_dirs)}][]const u8 = .{{\n"
            + "".join(f'    "{p}",\n' for p in map(_escape, include_dirs))
            + "};\n"
            + f"pub const lib: [{len(lib_paths)}][]const u8 = .{{\n"
            + "".join(f'    "{p}",\n' for p in map(_escape, lib_paths))
            + "};\n"
            + f'pub const module_name = "{module_name}";\n'
        )


def compile_to(
    target_dir: str | Path,
    module_name: str = "zig_ext",
    source_code: str | None = None,
    file: Path | str | None = None,
    directory: Path | str | None = None,
):
    """
    Same as import_zig, except that the module will not be imported an instead
    copied into the directory specified by `path_target`.

    Further, `module_name` is not randomized.
    """
    if (source_code is not None) + (file is not None) + (directory is not None) != 1:
        raise Exception(
            "Exactly one method must be used to specify location of Zig file(s)."
        )

    with TemporaryDirectory(prefix="import_zig_compile_") as tempdir:
        temppath = Path(tempdir)
        prepare(temppath, module_name, symlink_only=True)

        temppath_inner = temppath / "inner"
        if directory is not None:
            temppath_inner.rmdir()
            temppath_inner.symlink_to(Path(directory).absolute())
        elif file is not None:
            (temppath_inner / "import_fns.zig").symlink_to(Path(file).absolute())
        else:
            assert source_code is not None
            with (temppath_inner / "import_fns.zig").open("w") as f:
                f.write(source_code)

        args = [sys.executable, "-m", "ziglang", "build"]
        subprocess.run(args, cwd=tempdir, check=True)

        (binary,) = (p for p in (temppath / "zig-out").glob("**/*") if p.is_file())
        binary.rename(
            Path(target_dir) / (module_name + sysconfig.get_config_var("EXT_SUFFIX"))
        )


def import_zig(
    module_name: str | None = None,
    source_code: str | None = None,
    file: Path | str | None = None,
    directory: Path | str | None = None,
):
    """
    This function takes in Zig code, wraps it in the Python C API, compiles the
    code and returns the imported binary.

    Assumptions on the code:
    The Zig source can be specified as a source code string, a file or a directory.
    If it is specified as a directory, the file containin the functions which get
    exported to Python must be named `import_fns.zig`, however that file may use
    any other files present in the directory.

    A function gets exposed to Python if it is marked pub.

    It is possible to use
    ```
    const pyu = @import("../py_utils.zig");
    const py = pyu.py;
    ```
    in order to access the Python C API with `py` and utilities with `pyu`. This
    allows for example raising exceptions or passing Python objects with
    `*py.PyObject`.

    If module_name is left blank, a random name will be assigned.
    """
    if module_name is None:
        module_name = f"zig_ext_{hex(random.randint(0, 2**128))[2:]}"

    with TemporaryDirectory(prefix="import_zig_") as tempdir:
        compile_to(
            tempdir,
            source_code=source_code,
            file=file,
            directory=directory,
            module_name=module_name,
        )
        sys.path.append(tempdir)
        try:
            module = import_module(module_name)
        finally:
            sys.path.remove(tempdir)
        return module


