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
from os.path import relpath


class DirectoryImport(typing.TypedDict):
    """
    Directory-based Zig import configuration.

    `path` points to a directory containing Zig sources and
    `root_source_file` names the entry-point Zig file inside that directory.
    """

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
    """Supported Zig build optimization modes."""

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
    imports: typing.Mapping[str, typing.Mapping[str, str | Path]] | None = None,
) -> None:
    """
    Prepare an existing Zig project directory for Python extension builds.

    `path` must already exist. `root_source_file` names the entry-point Zig file
    inside that directory and is not overwritten.

    This generates or refreshes `build.zig`, `build.zig.zon`, and `zig_ext/` so
    the project can be compiled against the current Python interpreter and used
    with ZLS support for `@import("c")` and `@import("py")`.

    `imports`, when provided, is written into `build.zig.zon` as Zig package
    dependencies. Any `path` entry inside an import spec is rewritten relative
    to the prepared directory.

    On non-Windows platforms files are symlinked unless `force_copy=True`.
    On Windows files are always copied.
    """
    if imports is None:
        imports = {}
    else:
        imports = {k: dict(v) for k, v in imports.items()}
    path = Path(path)
    if not path.is_dir():
        raise FileNotFoundError(f"No such directory: {path}")
    (path / "zig_ext").mkdir(exist_ok=True)

    for fp in _copy_files:
        _link_or_copy(Path(__file__).parent / fp, path / fp, force_copy)

    doc_str_install = (
        "Please ensure Python development headers are installed.\n"
        "Installation commands:\n"
        "  Ubuntu/Debian: sudo apt-get install python3-dev\n"
        "  Fedora/CentOS/RHEL: sudo dnf install python3-devel\n"
        "  macOS: Install Python from python.org or use 'brew install python'\n"
        "  Windows: Ensure you have the Python development package from python.org"
    )
    try:
        include_dir = sysconfig.get_path("include")
    except KeyError:
        raise RuntimeError(
            "Python include path not found. " + doc_str_install
        ) from None
    include_path = Path(include_dir)
    if not include_path.exists():
        raise RuntimeError(
            f"Python include path {include_path} does not exist. " + doc_str_install
        )
    if not list(include_path.rglob("Python.h")):
        raise RuntimeError(
            f"Python.h not found in {include_path} or its subdirectories. "
            + doc_str_install
        )
    include_dirs = [include_dir]
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
            imports[name] = {
                # Path.relative_to with walk_up=True would work in 3.12+
                key: relpath(val, start=path) if key == "path" else val
                for key, val in import_spec.items()
            }

    with (path / "build.zig.zon").open("w", encoding="utf-8") as f:
        f.write(
            ".{\n"
            + "    .name = .zig_ext,\n"
            + "    .fingerprint = 0xbc61f5306128b76b,\n"
            + '    .version = "0.0.0",\n'
            + "    .dependencies = .{\n"
            + "".join(
                f"        .{name} = .{{\n"
                + "".join(
                    f'            .{key} = "{val}",\n'
                    for key, val in import_spec.items()
                )
                + "        },\n"
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
    directory: DirectoryImport | None = None,
    imports: typing.Mapping[str, typing.Mapping[str, str | Path]] | None = None,
    optimize: Optimize = Optimize.Debug,
):
    """
    Compile a Zig extension into `target_dir` without importing it.

    Exactly one of `source_code`, `file`, or `directory` must be provided.
    `module_name` is required and determines the filename of the compiled
    extension module.

    `directory` must be a `DirectoryImport` mapping with `path` and
    `root_source_file`. `imports` is forwarded to `prepare()` and written into
    the generated `build.zig.zon`. `optimize` selects the Zig optimization mode.

    Reusing the same `module_name` for different binaries in one Python process
    is unsafe and may lead to crashes if both are later imported.
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

        if directory is not None:
            p = Path(directory["path"]).absolute()
            if not any(directory["root_source_file"] == f.name for f in p.iterdir()):
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
            assert source_code is not None
            with (temppath / root_source_file).open("w", encoding="utf-8") as f:
                f.write(source_code)

        prepare(
            temppath, module_name, root_source_file, force_copy=False, imports=imports
        )

        compile_prepared(target_dir, temppath, optimize=optimize)


def compile_prepared(
    target_dir: str | Path,
    cwd: str | Path,
    optimize: Optimize = Optimize.Debug,
):
    """
    Compile a directory previously prepared by `prepare()`.

    `cwd` must contain the generated `build.zig`, `build.zig.zon`, and `zig_ext`
    scaffolding. The resulting extension module is copied into `target_dir` with
    the extension suffix for the active Python interpreter.
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
    directory: DirectoryImport | None = None,
    imports: typing.Mapping[str, typing.Mapping[str, str | Path]] | None = None,
    optimize: Optimize = Optimize.Debug,
):
    """
    Compile Zig code into a CPython extension module and import it.

    Exactly one of `source_code`, `file`, or `directory` must be provided.
    When using `directory`, pass a `DirectoryImport` mapping with `path` and
    `root_source_file` so the entry-point Zig file can be identified.

    Exported `pub fn` functions are exposed to Python. Inside Zig code you may
    use `@import("c")` for the Python C API and `@import("py")` for the helper
    utilities bundled with this package.

    `imports` is forwarded into the generated `build.zig.zon` dependency list and
    `optimize` selects the Zig optimization mode.

    If `module_name` is omitted, a random unique name is generated. Reusing a
    fixed `module_name` for different binaries in one Python process is unsafe
    and can lead to crashes.
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
