from pathlib import Path
from shutil import copyfile, copytree
from tempfile import TemporaryDirectory
from importlib import import_module
import sysconfig
import sys
import subprocess
import random
import platform
from enum import Enum
import re
import typing

class DirectoryImport(typing.TypedDict):
    path: str | Path
    root_source_file: str

_copy_files = [
    Path() / "build.zig",
    Path() / "zig_ext" / "py_utils.zig",
    Path() / "zig_ext" / "zig_ext.zig",
    Path() / "zig_ext" / "c.h",
]

custom_zig_binary = None

IS_WINDOWS = platform.system() == "Windows"

class Optimize(Enum):
    Debug = "Debug"
    ReleaseSafe = "ReleaseSafe"
    ReleaseFast = "ReleaseFast"
    ReleaseSmall = "ReleaseSmall"


def _link_or_copy(src: Path, tgt: Path, force_copy: bool) -> None:
    if IS_WINDOWS or force_copy:
        if src.is_file():
            copyfile(src, tgt)
        elif src.is_dir():
            copytree(
                src,
                tgt,
                ignore=lambda *_: [".git", ".zig-cache", "zig-out"],
                dirs_exist_ok=True,
            )
        else:
            assert not src.exists(), src
            raise FileNotFoundError(f"No such file or directory: {src}")
    else:
        tgt.unlink(missing_ok=True)
        tgt.symlink_to(src)


def _escape(path: str) -> str:
    return path.replace("\\", "\\\\")


def prepare(
    path: str | Path,
    module_name: str,
    root_source_file: str,
    force_copy: bool = True,
    imports: dict[str, dict[str, str | Path]] | None = None,
) -> None:
    """
    Link/Create files at path needed to compile the Zig code

    In order to get ZLS support for the Python C API, you can execute this and
    develop inside the specified path.

    This function generates / overwrites the files "path / build.zig"
    and "path / build.zig.zon" as well as the directory "path / zig_ext".

    The entry point to your code is "path / root_source_file" and will not be overwritten.
    """
    if imports is None:
        imports = {}
    path = Path(path)
    if not path.is_dir():
        raise FileNotFoundError(f"No such directory: {path}")
    (path / "zig_ext").mkdir(exist_ok=True)

    for fp in _copy_files:
        _link_or_copy(Path(__file__).parent / fp, path / fp, force_copy)

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
            + f'pub const root_source_file = "{root_source_file}";\n'
            + f"pub const imports: [{len(imports)}][]const u8 = .{{\n"
            + "".join(f'    "{p}",\n' for p in imports.keys())
            + "};\n"
        )

    with (path / "zig_ext" / ".gitignore").open("w", encoding="utf-8") as f:
        f.write("*\n")

    for name, import_spec in imports.items():
        if "path" in import_spec:
            import_path = import_spec["path"]
            import_path = Path(import_path).absolute()
            _link_or_copy(import_path, path / "zig_ext" / name, force_copy)
            import_spec["path"] = f"zig_ext/{name}"

    with (path / "build.zig.zon").open("w", encoding="utf-8") as f:
        f.write(
            ".{\n"
            + "    .name = .zig_ext,\n"
            + "    .fingerprint = 0xbc61f5306128b76b,\n"
            + '    .version = "0.0.0",\n'
            + "    .dependencies = .{\n"
            + "".join(
                f'        .{name} = .{{\n'
                + "".join(
                    f'            .{key} = "{val}",\n'
                    for key, val in import_spec.items()
                )
                + '        },\n'
        
                for name, import_spec in imports.items()
            )
            + "    },\n"
            + '    .paths = .{"build.zig", "build.zig.zon", "zig_ext"},\n'
            + "}\n"
        )


def compile_to(
    target_dir: str | Path,
    module_name: str,
    source_code: str | None = None,
    file: Path | str | None = None,
    directory: DirectoryImport = None,
    imports: dict[str, dict[str, str | Path]] | None = None,
    optimize: Optimize = Optimize.Debug,
):
    """
    Same as import_zig, except that the module will not be imported an instead
    copied into the directory specified by `path_target`.

    `module_name` must be provided.

    If you import different modules with the same module_name, you may run into
    issues like segfaults.
    """
    if not module_name:
        raise Exception("module_name must be specified")

    if (source_code is not None) + (file is not None) + (directory is not None) != 1:
        raise Exception(
            "Exactly one method must be used to specify location of Zig file(s)."
        )

    with TemporaryDirectory(prefix="import_zig_compile_") as tempdir:
        temppath = Path(tempdir)
        if directory is not None:
            root_source_file = directory["root_source_file"]
            assert Path(directory["path"]).is_dir(), directory
            assert (Path(directory["path"]) / root_source_file).is_file(), directory
        elif file is not None:
            assert Path(file).is_file(), file
            root_source_file = Path(file).name
        else:
            assert source_code is not None
            root_source_file = "import_fns.zig"
        prepare(temppath, module_name, root_source_file, force_copy=False, imports=imports)

        if directory is not None:
            p = Path(directory["path"]).absolute()
            if not any(directory['root_source_file'] == f.name for f in p.iterdir()):
                raise FileNotFoundError(
                    f"Directory {p} must contain {directory['root_source_file']}"
                )
            _link_or_copy(
                p,
                temppath,
                force_copy=True,
            )
        elif file is not None:
            _link_or_copy(
                Path(file).absolute(),
                temppath / root_source_file,
                force_copy=False,
            )
        else:
            with (temppath / root_source_file).open("w", encoding="utf-8") as f:
                f.write(source_code)

        compile_prepared(target_dir, temppath, optimize=optimize)


def compile_prepared(
    target_dir: str | Path,
    cwd: str | Path,
    optimize: Optimize = Optimize.Debug,
):
    """
    `cwd` must be prepared with `prepare()`. The resulting binary will be
    placed into `target_dir`.
    """
    target_dir = Path(target_dir)
    cwd = Path(cwd)
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
        f"-Doptimize={optimize.name}",
    ]
    subprocess.run(args, cwd=cwd, check=True)

    (binary,) = (
        p
        for p in (cwd / "zig-out").glob(f"**/*{'.dll' if IS_WINDOWS else ''}")
        if p.is_file()
    )

    with (cwd / "zig_ext" / "generated.zig").open("r", encoding="utf-8") as f:
        generated_content = f.read()
        m = re.search(r'pub const module_name = "(.*?)";', generated_content)
        assert m, generated_content
        module_name = m.group(1)

    copyfile(
        binary,
        Path(target_dir) / (module_name + sysconfig.get_config_var("EXT_SUFFIX")),
    )


def import_zig(
    module_name: str | None = None,
    source_code: str | None = None,
    file: Path | str | None = None,
    directory: DirectoryImport = None,
    imports: dict[str, dict[str, str | Path]] | None = None,
    optimize: Optimize = Optimize.Debug,
):
    """
    This function takes in Zig code, wraps it in the Python C API, compiles the
    code and returns the imported binary as a python module.

    Assumptions on the code:
    The Zig source can be specified as a source code string, a file or a directory.
    If it is specified as a directory, the `directory` dictionary must provide the
    `path` to the directory as well as the `root_source_file` which is the file
    containing the functions which get exported to Python. The `root_source_file`
    may import any other Zig files inside the directory.

    A function gets exposed to Python if it is marked pub.

    It is possible to use
    ```
    const c = @import("c");
    const py = @import("py");
    ```
    in order to access the Python C API with `c` and utilities with `py`. This
    allows for example raising exceptions or passing Python objects with
    `*c.PyObject`.

    If module_name is left blank, a random name will be assigned. Otherwise, you
    may need to be careful to avoid using the same name twice to avoid weird crashes.
    """
    if module_name is None:
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
            optimize=optimize,
        )
        sys.path.append(tempdir)
        try:
            module = import_module(module_name)
        finally:
            sys.path.remove(tempdir)
        return module
