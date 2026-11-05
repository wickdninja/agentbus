# Security

Report vulnerabilities privately through GitHub's **Report a vulnerability** button on this repository's [Security tab](https://github.com/wickdninja/agentbus/security). This uses GitHub private vulnerability reporting. Do not disclose vulnerabilities in public issues.

## The release check

A command you run at a terminal on a tool-installed agentbus may, once a day, ask GitHub whether a newer release exists, so it can print one line telling you to run `agentbus update`. What it sends: one `GET` to `https://api.github.com/repos/wickdninja/agentbus/releases/latest` (or the `releases` list when you run a release candidate) with the headers `Accept` and `User-Agent: agentbus`, over TLS with certificate checks, no redirect followed, and a 10 second limit. No cookie, no token (`GH_TOKEN` and `GITHUB_TOKEN` are never read), no identifier of you, your machine or your work. The answer is kept in a cache file in your cache folder (mode 0600 in a 0700 folder); every version in it is checked against the tag shape `X.Y.Z` or `X.Y.ZrcN` before it is shown or used, and anything else is ignored.

It never runs in CI, with `--json`, in an agent session (`CLAUDECODE`, a Codex shell, `AGENTBUS_AGENT_SESSION`, or any of stdin, stdout, stderr not a terminal), from a project copy, a clone or a fork, and it is off with `AGENTBUS_NO_UPDATE_CHECK=1`, `DO_NOT_TRACK=1` or `NO_UPDATE_NOTIFIER=1`.

## What `agentbus update` installs, and what the first install does

**`agentbus update`** reads the release's asset list from the GitHub API answer above, then downloads the release **wheel** (`agentbus-X.Y.Z-py3-none-any.whl`) and `SHA256SUMS` from `https://github.com/wickdninja/agentbus/releases/download/vX.Y.Z/`: TLS verified, at most 5 MiB and 4 KiB, 60 seconds each, redirects followed only to GitHub's own hosts (`github.com`, `*.githubusercontent.com`), into a 0700 folder under your cache folder. It checks the wheel's sha256 against the line for that file in `SHA256SUMS` and refuses a mismatch (`download_failed`, nothing installed). Then it runs the installer of the tool that installed agentbus (uv, pipx or the install's own pip), found on a filtered `PATH` (no relative entry, nothing inside your repository or a bus folder, nothing world-writable or owned by another user, no group-writable installer file, and a group-writable folder only for macOS's `admin` group, whose members can already become root), with an argument list and never a shell, from that cache folder, on that local wheel file. The downloads are removed afterwards. No source is built and no package index is asked: a wheel install fetches nothing else (agentbus has no dependencies). What the checksum does and does not give you: the wheel and `SHA256SUMS` come from the same GitHub release, so the check catches a damaged, truncated or swapped file, but not a compromised release; `update` does not verify the build-provenance attestation the release workflow publishes. If a release has no wheel or no `SHA256SUMS`, `update` stops with `manual_step` and never builds from source on its own.

**The README's first-install lines** are, from the first release that publishes a wheel, the URL of that release's wheel (`uv tool install https://github.com/wickdninja/agentbus/releases/download/vX.Y.Z/agentbus-X.Y.Z-py3-none-any.whl`, and the pipx form): uv and pipx download that one file over TLS and install it, with no build and no package index, the same file `agentbus update` installs. They do not check it against `SHA256SUMS`; `update` does. The README pins v0.2.0 today, the first release with a wheel; v0.1.0 has none and installs from source (below).

**Installing from source** (`uv tool install git+https://github.com/wickdninja/agentbus@vX.Y.Z`, the pipx form, or `@main`; documented in `docs/how-to/upgrade.md` for forks and `main`) builds on your machine. It clones the tag (a git tag can be moved; the release workflow only checks that the tag still points at the commit it built), fetches the build backend (`hatchling`, pinned to an exact version but without a hash) from PyPI, and any dependency of it that is not pinned. A fork, a clone or an install of unknown origin gets the commands printed for you to run; `update` runs none of them.

Nothing is installed by package name, because the name `agentbus` on PyPI belongs to an unrelated project (`pip install agentbus` installs that project, not this one). A repository that was renamed answers with a redirect, which the check refuses, so installs that predate a rename stay silent until you reinstall from the new name.

## Verifying a release's provenance

The release workflow attests the wheel, the sdist and `SHA256SUMS` (GitHub build provenance, signed by the workflow that built them). `agentbus update` does not check it; you can, with the GitHub CLI. In a folder of your own:

```bash
gh release download vX.Y.Z --repo wickdninja/agentbus --pattern '*.whl'
gh attestation verify agentbus-X.Y.Z-py3-none-any.whl --repo wickdninja/agentbus --signer-workflow wickdninja/agentbus/.github/workflows/release.yml
```

Exit code 0 means the file is byte-for-byte what `release.yml` built from that repository; a changed file exits 1 (`HTTP 404` from the attestations API: no attestation for those bytes). It proves where the file was built, not that the code is free of bugs. The v0.2.0 wheel and sdist verify this way; its `SHA256SUMS` was published before it was attested, so the same command on that file fails with a 404. The next release attests all three.
