# Releasing agentbus

A release is a tag. The workflow (`.github/workflows/release.yml`) refuses a tag that fails the checks below, runs the whole test workflow, builds the wheel and sdist **once**, verifies those exact files (members, an install of each, a broken-install negative control) and records their sha256s in `SHA256SUMS`. It then publishes those same files as GitHub release assets (with build provenance attestations). GitHub Releases is the only channel: the name `agentbus` on PyPI belongs to an unrelated project, so nothing is ever published there and no install line names the bare package. Every job re-checks the files against `SHA256SUMS`, and `verify_published` installs what was published and compares the sha256s again. Tags and releases are the owner's call.

Tags are `vX.Y.Z` or `vX.Y.ZrcN`, nothing else (no `a`, `b`, `dev`). A release candidate builds version `X.Y.ZrcN` (`__version__` carries the suffix), is a GitHub prerelease, and its README pin and CHANGELOG heading are the final `X.Y.Z`.

## Checklist

1. **Release-prep commit.** One commit on `main`. It differs for a candidate and for a final tag.
   - **Release candidate `vX.Y.ZrcN`:**
     - `__version__` in `bin/agentbus` becomes `X.Y.ZrcN`;
     - `.claude-plugin/plugin.json` version is `X.Y.ZrcN` and the `ref` in `.claude-plugin/marketplace.json` is the rc tag (a git source, never a `./` path);
     - the `CHANGELOG.md` heading is `## X.Y.Z - YYYY-MM-DD` (the final version, with the section stating which of the five versioned things changed: tool, copy, schema, skill, hooks);
     - the skill hashes: `python3 scripts/embed_skill.py --release`;
     - **no pin change and no `tests/released_commands.txt` line:** the README and `docs/` keep pinning the last final release, which must already exist as a git tag (`release_check.py` fails if it does not).
   - **Final tag `vX.Y.Z`:** one commit that moves all of these together, merged before the tag is made on it:
     - `__version__` becomes `X.Y.Z`;
     - the new tag's line in `tests/released_commands.txt` (the commands that release has; the README may only name those for the tag it pins);
     - the pinned install lines in `README.md` and `docs/` (`@vX.Y.Z`), except that the README's first-install lines are the release wheel's URL from the first release that publishes a wheel (below): `python3 scripts/release_check.py --wheel --lines vX.Y.Z` prints them, and `vX.Y.Z` is added to `tests/released_wheels.txt` in the same commit;
     - the plugin version and marketplace `ref` (the tag), the CHANGELOG heading, and `python3 scripts/embed_skill.py --release`.

**The README's install lines** are, from the first release that publishes a wheel and `SHA256SUMS`, the wheel's URL: no build, no package index, and the same file `agentbus update` installs. `python3 scripts/release_check.py --wheel --lines vX.Y.Z` prints the exact two lines for a tag (without `--wheel` it prints the `git+` lines, the form of any tag not yet in `tests/released_wheels.txt`); `release_check.py` requires them in the README, `verify_published.sh` runs them, and `tests/test_docs.sh` pins the README to them once the pinned release is listed. They replace the `git+` lines in the release-prep commit (the pinned README cannot name a wheel that does not exist yet). The form, with the tag filled in:

<!-- readme-install:begin -->
```bash
uv tool install https://github.com/wickdninja/agentbus/releases/download/vX.Y.Z/agentbus-X.Y.Z-py3-none-any.whl
pipx install https://github.com/wickdninja/agentbus/releases/download/vX.Y.Z/agentbus-X.Y.Z-py3-none-any.whl
```
<!-- readme-install:end -->

The `git+https://github.com/wickdninja/agentbus@vX.Y.Z` form stays documented once, in `docs/how-to/upgrade.md`, as the from-source route (a fork, or `main`).

**The README's Update section** lands in the release-prep commit of the first release that has `agentbus update` (the README may only name commands of the release it pins, so it cannot be on `main` earlier). Put this text after the install lines in `README.md`; `tests/test_docs.sh` then requires it:

<!-- readme-update:begin -->
## Update

`agentbus update` installs the latest release, upgrades your bus folders and refreshes the skill. Once a day, a command you run at a terminal may tell you a release is out (on stderr; never in CI, with `--json` or in an agent session); `AGENTBUS_NO_UPDATE_CHECK=1` turns that off. Do not run `pip install agentbus` or `uv tool install agentbus`: that name on PyPI is a different project.
<!-- readme-update:end -->

2. **Check.** `git fetch origin main && python3 scripts/release_check.py --tag vX.Y.Z` prints `release check passed: X.Y.Z`. It checks the tag shape, that `__version__` equals the tag, that the tagged commit is an ancestor of `origin/main`, the CHANGELOG heading, the pins, the plugin manifests, the skill hashes and a clean `git status`. The README pin equals the new version only at this point; on every other commit it keeps naming the last tag. For a release candidate the pin is the **last final release** (the newest tag in `tests/released_commands.txt`), because main's public README must never point at a tag that does not exist. For the final tag, the pin bump and the tag land together: one commit that bumps the version, the pins, `tests/released_commands.txt`, the CHANGELOG heading and the plugin manifests; merge it; tag that commit.
3. **Gates.** `bash tests/run_all.sh` prints `ALL TESTS PASSED (N files)` on the oldest and newest Python (`PYTHON=/usr/bin/python3`, `PYTHON=python3.15`), with `AGENTBUS_EMBED_CHECK=1 python3 scripts/embed_skill.py --check` printing `embedded skill is current`. CI's `test` and all `package` jobs are green.
4. **Tag.** `git tag vX.Y.Z && git push origin vX.Y.Z`. A release candidate is `vX.Y.ZrcN`: it creates a prerelease and skips the published-install check.
5. **Workflow.** `release.yml` is green: `check`, `test`, `build`, `publish`, and `verify_published` (final tags only).
6. **Verify the published install.** `bash scripts/verify_published.sh vX.Y.Z --sums SHA256SUMS` (download `SHA256SUMS` from the release) runs the literal install lines from the README on a clean machine, compares the published files with the recorded sha256s, and prints `published install verified: vX.Y.Z`. The same script runs in the workflow.
7. **Look.** `uv tool install git+https://github.com/wickdninja/agentbus@vX.Y.Z`, then `agentbus --version`.
8. **Launch** (see `docs/launch/`). Drafts are shown to the owner whole before anything is posted.

## Time to first handoff

`bash scripts/ttfh.sh` installs into a throwaway home, runs `agentbus init .` and `agentbus setup claude`, and times the path to a second agent's `inbox` showing the first agent's handoff. CI records the number on the summary of each `package` run. It has no pass or fail time (it mostly measures the network); put the latest number in the release notes.

## Repository settings (the owner's call; nothing here changes them)

- A tag ruleset for `v*`: only the owner (or release managers) can create tags, and nobody can move or delete one. The workflow also checks that the tag still points at the commit it built and passes `--verify-tag`, but only a ruleset stops a tag from being created on an unreviewed commit.
- Branch protection on `main`: a release must come from it, and `release_check.py` fails on a tagged commit that is not an ancestor of `origin/main`.
