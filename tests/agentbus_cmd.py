"""The one way a Python test launches the CLI; tests/lib.sh defines the same rule as the array AB.

agentbus_argv() returns the argument list to prefix to the CLI's own arguments:
  AGENTBUS_CMD  an installed command, split on whitespace
  AGENTBUS_BIN  a copy of the script (a mutation copy), run under $PYTHON (default python3)
  otherwise     $PYTHON (default python3) and the checkout's bin/agentbus
"""
import os


def agentbus_argv():
    cmd = os.environ.get('AGENTBUS_CMD')
    if cmd:
        return cmd.split()
    py = os.environ.get('PYTHON') or 'python3'
    bin_ = os.environ.get('AGENTBUS_BIN')
    if not bin_:
        bin_ = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'bin', 'agentbus')
    return [py, bin_]
