"""The one way a unit test reaches the code: `from load_agentbus import ab`. bin/agentbus (or the copy AGENTBUS_BIN
names, so a mutated copy is what runs) is loaded once per process as a module. Assign through `patched`, never into
`ab` by hand, so a test cannot leak a change into the next one."""
import contextlib
import importlib.machinery
import importlib.util
import os
import sys

sys.dont_write_bytecode = True  # the checkout stays as it was: tests/run_all.sh checks that
_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_NAME = "agentbus_under_test"


def _load():
    if _NAME in sys.modules:
        return sys.modules[_NAME]
    loader = importlib.machinery.SourceFileLoader(_NAME, os.environ.get("AGENTBUS_BIN") or os.path.join(_ROOT, "bin", "agentbus"))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(_NAME, loader))
    sys.modules[_NAME] = module
    loader.exec_module(module)
    return module


ab = _load()


@contextlib.contextmanager
def patched(name, value):
    """ab.<name> is value for the length of a with block."""
    old = getattr(ab, name)
    setattr(ab, name, value)
    try:
        yield
    finally:
        setattr(ab, name, old)


def diag(test, fn, *args, **kwargs):
    """The Diag of the die() that fn(...) must end in, for a test to read its code and next command."""
    with test.assertRaises(SystemExit) as caught:
        fn(*args, **kwargs)
    test.assertIsInstance(caught.exception.code, ab.Diag)
    return caught.exception.code
