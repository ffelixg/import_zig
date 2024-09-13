from pathlib import Path
from shutil import copyfile
from tempfile import TemporaryDirectory
from importlib import import_module
import sysconfig
import sys
import subprocess
import random
import typing

copy_paths = [
    Path(__file__).parent / "build.zig",
    Path(__file__).parent / "py_utils.zig",
    Path(__file__).parent / "zig_ext.zig",
]


def _escape(path: str):
    return path.replace("\\", "\\\\")


def prepare(path: Path, module_name: str):
    "Link/Create files at path needed to compile the Zig code"
    for cp in copy_paths:
        (path / cp.name).symlink_to(cp)

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


def import_zig(
    source_code: str | None = None,
    file: Path | str | None = None,
    directory: Path | str | None = None,
    module_name: str | None = None,
    return_action: typing.Literal["import", "binary_path"] = "import",
):
    if (source_code is not None) + (file is not None) + (directory is not None) != 1:
        raise Exception("Can only use one method to specify location of Zig file(s).")
    if module_name is None:
        module_name = f"zig_ext_{hex(random.randint(0, 2**128))[2:]}"

    with TemporaryDirectory(prefix="import_zig_") as tempdir:
        temppath = Path(tempdir)
        prepare(temppath, module_name)

        temppath_inner = temppath / "inner"
        if directory is not None:
            temppath_inner.symlink_to(Path(directory).absolute())
        else:
            temppath_inner.mkdir()
            if file is not None:
                (temppath_inner / "import_fns.zig").symlink_to(Path(file).absolute())
            else:
                assert source_code is not None
                with (temppath_inner / "import_fns.zig").open("w") as f:
                    f.write(source_code)

        proc = subprocess.run(
            [
                sys.executable,
                "-m",
                "ziglang",
                "build",
            ],
            cwd=tempdir,
            check=True,
        )

        (binary,) = (p for p in (temppath / "zig-out").glob("**/*") if p.is_file())
        new_binary = temppath / (module_name + sysconfig.get_config_var("EXT_SUFFIX"))
        binary.rename(new_binary)

        if return_action == "import":
            sys.path.append(tempdir)
            module = import_module(module_name)
            sys.path.remove(tempdir)
            return module
        elif return_action == "binary_path":
            return_binary = new_binary.parent.parent / new_binary.name
            new_binary.rename(return_binary)
            return return_binary
        else:
            raise Exception("Invalid return_action")
