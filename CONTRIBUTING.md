# Contributing

Supported platforms: macOS and Linux, Python 3.9+ and Git 2.31+. Windows is not supported.

Edit `bin/agentbus`; installed and repo-local copies derive from it. Keep it one file with no third-party runtime dependencies. Include expected output and tests for CLI behavior changes.

From the source checkout, run the suite:

```bash
bash tests/run_all.sh
PYTHON=/usr/bin/python3 bash tests/run_all.sh
```

Set `PYTHON` to test another interpreter, for example `PYTHON=python3.15`. Tests source `tests/lib.sh`, discard inherited bus settings, and use throwaway databases, repos, and a temporary HOME. Keep that isolation in new tests; never exercise a real user's bus. Some sandbox checks are macOS-only and explicitly skip elsewhere.
