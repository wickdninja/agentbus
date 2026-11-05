# Contributing

Supported platforms: macOS and Linux, Python 3.9+ and Git 2.31+. Windows is not supported.

Edit `bin/agentbus`; installed and repo-local copies derive from it. Keep it one file with no third-party runtime dependencies. Include expected output and tests for CLI behavior changes.

From the source checkout, run the suite:

```bash
bash tests/run_all.sh
PYTHON=/usr/bin/python3 bash tests/run_all.sh
```

Set `PYTHON` to test another interpreter, for example `PYTHON=python3.15`. Tests source `tests/lib.sh`, discard inherited bus settings, and use throwaway databases, repos, and a temporary HOME. Keep that isolation in new tests; never exercise a real user's bus. Some sandbox checks are macOS-only and explicitly skip elsewhere.

Adding a command? Add its test file `tests/test_<command>.sh` (it is picked up by name), a line in `tests/test_docs.sh` if it changes the reference, and, when it changes what an agent or a person does end to end, a step in the matching `tests/test_workflow_*.sh` story. Break the behaviour on purpose and watch the test fail: add an entry to `tests/mutations.json` naming the test (`python3 scripts/mutate.py --list`, `bash tests/test_mutations.sh`).

`bash tests/test_unit.sh` runs the fast layer in seconds: `tests/unit/`, plain `unittest` on pure logic, each test naming the bug it catches. `tests/test_cli_surface.sh` pins `--help`, every `<command> --help`, `schema --json` and the completion scripts byte for byte in `tests/golden/cli/`. A change to any of them is meant to fail it: run `bash tests/test_cli_surface.sh --update` under Python 3.9 to 3.11 and again under 3.12 or later, then review the diff.

Maintainers building agentbus on its own bus: [docs/internal/dogfood.md](docs/internal/dogfood.md).

Agent evals (Claude Code and Codex doing real work on the bus) are run by the maintainers before a release: see [docs/evals/README.md](docs/evals/README.md). They spend tokens and are not part of `bash tests/run_all.sh`.

A test file that needs something this build does not have (a command another change adds, a fixture) calls `skip_test "reason"`, or `skip_part "reason"` for one section, from `tests/lib.sh`. The runner prints `SKIP`, counts it apart (`ALL TESTS PASSED (N files, M skipped)`), and CI sets `AGENTBUS_NO_SKIP=1` so a skip there is a failure. `bash tests/run_all.sh --skip-heavy` leaves out the two files that run other tests again (`test_mutations.sh`, `test_eval_harness.sh`); `--only-heavy` runs just those. The runner also runs every file with a poisoned `AGENTBUS_DB`, `AGENTBUS_AGENT` and `HOME` and fails if any of them, or the checkout, changed.

What the isolation guarantee covers: it is a property of `bash tests/run_all.sh`, not of a file. A file run directly (`bash tests/test_x.sh`) is not checked; `lib.sh` still drops the caller's `AGENTBUS_DB` and `AGENTBUS_AGENT`, and every test makes its own `HOME`, but only the runner proves nothing leaked. The runner also fails on files left in its private `TMPDIR` (Python's `tempfile` and Linux `mktemp` honour it; a bare `mktemp -d` on macOS does not, so a leak there is not seen). Out of scope: a test that writes through a hard-coded absolute path, or leaves something in `/tmp`.
