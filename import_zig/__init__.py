from pathlib import Path
from shutil import copyfile, copytree
from tempfile import TemporaryDirectory
from importlib import import_module
import sysconfig
import sys
import subprocess
import random
import platform

_copy_files = [
    Path() / "build.zig",
    Path() / "zig_ext" / "py_utils.zig",
    Path() / "zig_ext" / "zig_ext.zig",
    Path() / "zig_ext" / "c.h",
]

custom_zig_binary = None

IS_WINDOWS = platform.system() == "Windows"


def link_or_copy(src: Path, tgt: Path, force_copy: bool) -> None:
    if IS_WINDOWS or force_copy:
        if src.is_file():
            copyfile(src, tgt)
        else:
            copytree(
                src,
                tgt,
                ignore=lambda *_: [".git", ".zig-cache", "zig-out"],
                dirs_exist_ok=True,
            )
    else:
        tgt.unlink(missing_ok=True)
        tgt.symlink_to(src)


def _escape(path: str) -> str:
    return path.replace("\\", "\\\\")


def prepare(
    path: str | Path,
    module_name: str,
    force_copy: bool = True,
    imports: dict[str, str | Path] | None = None,
) -> None:
    """
    Link/Create files at path needed to compile the Zig code

    In order to get ZLS support for the Python C API, you can execute this and
    develop inside the "inner" directory.
    """
    if imports is None:
        imports = {}
    path = Path(path)
    if not path.is_dir():
        raise FileNotFoundError(f"No such directory: {path}")
    (path / "zig_ext").mkdir(exist_ok=True)

    for fp in _copy_files:
        link_or_copy(Path(__file__).parent / fp, path / fp, force_copy)

    include_dirs = [sysconfig.get_path("include")]
    lib_paths = [
        str(Path(sysconfig.get_config_var("installed_base"), "Libs").absolute())
    ]

    with (path / "zig_ext" / "generated.zig").open("w", encoding="utf-8") as f:
        f.write(
            f"pub const include: [{len(include_dirs)}][]const u8 = .{{\n"
            + "".join(f'    "{p}",\n' for p in map(_escape, include_dirs))
            + "};\n"
            + f"pub const lib: [{len(lib_paths)}][]const u8 = .{{\n"
            + "".join(f'    "{p}",\n' for p in map(_escape, lib_paths))
            + "};\n"
            + f'pub const module_name = "{module_name}";\n'
            + f"pub const imports: [{len(imports)}][]const u8 = .{{\n"
            + "".join(f'    "{p}",\n' for p in imports.keys())
            + "};\n"
        )

    for name, import_path in imports.items():
        import_path = Path(import_path).absolute()
        link_or_copy(import_path, path / "zig_ext" / name, force_copy)

    with (path / "build.zig.zon").open("w", encoding="utf-8") as f:
        f.write(
            ".{\n"
            + "    .name = .zig_ext,\n"
            + "    .fingerprint = 0xbc61f5306128b76b,\n"
            + '    .version = "0.0.0",\n'
            + "    .dependencies = .{\n"
            + "".join(
                f'        .{name} = .{{.path="zig_ext/{name}"}},\n' for name in imports
            )
            + "    },\n"
            + '    .paths = .{"build.zig", "build.zig.zon", "zig_ext"},\n'
            + "}\n"
        )


def compile_to(
    target_dir: str | Path,
    module_name: str | None = None,
    source_code: str | None = None,
    file: Path | str | None = None,
    directory: Path | str | None = None,
    imports: dict[str, str | Path] | None = None,
):
    """
    Same as import_zig, except that the module will not be imported an instead
    copied into the directory specified by `path_target`.

    Further, `module_name` is not randomized.
    """
    if module_name is None:
        if file is not None:
            module_name = Path(file).name.removesuffix(".zig")
        else:
            module_name = "zig_ext"

    if (source_code is not None) + (file is not None) + (directory is not None) != 1:
        raise Exception(
            "Exactly one method must be used to specify location of Zig file(s)."
        )

    with TemporaryDirectory(prefix="import_zig_compile_") as tempdir:
        temppath = Path(tempdir)
        prepare(temppath, module_name, force_copy=False, imports=imports)

        if directory is not None:
            p = Path(directory).absolute()
            if not any(f"{module_name}.zig" == f.name for f in p.iterdir()):
                raise FileNotFoundError(
                    f"{module_name=}, so Directory {p} must contain {module_name}.zig"
                )
            link_or_copy(
                p,
                temppath,
                force_copy=True,
            )
        elif file is not None:
            p = Path(file).absolute()
            if p.name != f"{module_name}.zig":
                raise FileNotFoundError(
                    f"{module_name=}, so file {p} must be named {module_name}.zig"
                )
            link_or_copy(
                p,
                temppath / f"{module_name}.zig",
                force_copy=False,
            )
        else:
            assert source_code is not None
            with (temppath / f"{module_name}.zig").open("w", encoding="utf-8") as f:
                f.write(source_code)

        args = [
            *(
                [custom_zig_binary]
                if custom_zig_binary is not None
                else [
                    sys.executable,
                    "-m",
                    "ziglang",
                ]
            ),
            "build",
            *(["-Dtarget=x86_64-windows"] if IS_WINDOWS else []),
        ]
        subprocess.run(args, cwd=temppath, check=True)

        (binary,) = (
            p
            for p in (temppath / "zig-out").glob(f"**/*{'.dll' if IS_WINDOWS else ''}")
            if p.is_file()
        )

        copyfile(
            binary,
            Path(target_dir) / (module_name + sysconfig.get_config_var("EXT_SUFFIX")),
        )


def import_zig(
    module_name: str | None = None,
    source_code: str | None = None,
    file: Path | str | None = None,
    directory: Path | str | None = None,
    imports: dict[str, str | Path] | None = None,
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
        if file is not None:
            module_name = Path(file).name.removesuffix(".zig")
        else:
            module_name = f"zig_ext_{hex(random.randint(0, 2**128))[2:]}"

    # For some reason the binary can't be deleted on windows, so it will live on
    # due to ignore_cleanup_errors. Hopefully the OS takes care of it eventually.
    with TemporaryDirectory(
        prefix="import_zig_", ignore_cleanup_errors=True
    ) as tempdir:
        compile_to(
            tempdir,
            source_code=source_code,
            file=file,
            directory=directory,
            module_name=module_name,
            imports=imports,
        )
        sys.path.append(tempdir)
        try:
            module = import_module(module_name)
        finally:
            sys.path.remove(tempdir)
        return module
