"""Runs the plugin's bin/agentbus from a bytecode cache, so a hook skips the compile.

Python compiles a script from source on every run; only imported modules get a cached .pyc.
bin/agentbus is one 9000-line file, so run as a script it spends about half of every hook
compiling. This launcher loads it the way an import does (the installed `agentbus` command
does the same) and keeps the .pyc in a private per-user folder, never beside the source and
never in a project's .agentbus.

The cache is trusted only when the folder is a real directory (not a link) this user owns and
no one else can enter (0700). Python's own check applies on top: a .pyc is used only when it
records the source's modification time and size. Anything else (no home, an unsafe folder, a
read-only disk, a damaged .pyc) falls back to compiling in memory, which is what the script
does anyway. PYTHONDONTWRITEBYTECODE is honoured: nothing is written, an existing .pyc is read.
"""
import importlib.machinery
import os
import stat
import sys
import types


def cache_folder():
    """The private per-user folder for the .pyc, or None when there is no safe one."""
    base = os.environ.get("XDG_CACHE_HOME")
    if not base or not os.path.isabs(base):
        home = os.path.expanduser("~")
        if not os.path.isabs(home):
            return None
        base = os.path.join(home, ".cache")
    folder = base
    for part in ("agentbus", "pycache"):  # both private: a loose parent could be used to swap the child
        folder = os.path.join(folder, part)
        try:
            os.makedirs(folder, mode=0o700, exist_ok=True)
            st = os.lstat(folder)  # lstat: a link planted there is not followed
        except OSError:
            return None
        # Fail closed: a folder that is not ours, or that anyone else could ever have written to, is not trusted
        # (narrowing its mode now would not undo a file planted while it was open).
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & 0o077:
            return None
    return folder


def load(source):
    """The module for `source`, its code taken from the cache when valid."""
    loader = importlib.machinery.SourceFileLoader("agentbus", source)
    module = types.ModuleType("agentbus")
    code = None
    folder = cache_folder()
    if folder:
        # sys.pycache_prefix moves where the loader reads and writes the .pyc. It is set only for
        # get_code: left on, the standard library modules agentbus imports would be recompiled into it.
        before = sys.pycache_prefix
        sys.pycache_prefix = folder
        try:
            code = loader.get_code("agentbus")
        except Exception:
            code = None
        finally:
            sys.pycache_prefix = before
    if code is None:
        with open(source, "rb") as f:
            code = compile(f.read(), source, "exec")
    module.__file__ = source  # self_path() reads it
    module.__loader__ = loader
    sys.modules["agentbus"] = module
    exec(code, module.__dict__)
    return module


def main():
    root = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    source = os.path.join(root, "bin", "agentbus")
    sys.argv[0] = source  # what `python3 bin/agentbus ...` would have shown
    load(source).cli()


if __name__ == "__main__":
    main()
