# Security

Report vulnerabilities privately through GitHub's **Report a vulnerability** button on this repository's [Security tab](https://github.com/wickdninja/agentbus/security). This uses GitHub private vulnerability reporting. Do not disclose vulnerabilities in public issues.

## The release check

A command you run at a terminal on a tool-installed agentbus may, once a day, ask GitHub whether a newer release exists, so it can print one line telling you to run `agentbus update`. What it sends: one `GET` to `https://api.github.com/repos/wickdninja/agentbus/releases/latest` (or the `releases` list when you run a release candidate) with the headers `Accept` and `User-Agent: agentbus`, over TLS with certificate checks, no redirect followed, and a 10 second limit. No cookie, no token (`GH_TOKEN` and `GITHUB_TOKEN` are never read), no identifier of you, your machine or your work. The answer is kept in a cache file in your cache folder (mode 0600 in a 0700 folder); every version in it is checked against the tag shape `X.Y.Z` or `X.Y.ZrcN` before it is shown or used, and anything else is ignored.

It never runs in CI, with `--json`, in an agent session (`CLAUDECODE`, a Codex shell, or any of stdin, stdout, stderr not a terminal), from a project copy, a clone or a fork, and it is off with `AGENTBUS_NO_UPDATE_CHECK=1`, `DO_NOT_TRACK=1` or `NO_UPDATE_NOTIFIER=1`.

`agentbus update` runs only the installer of the tool that installed agentbus (uv, pipx or the install's own pip), found on a filtered `PATH` (no relative entry, nothing inside your repository or a bus folder, nothing group- or world-writable), with an argument list and never a shell, from your home folder, at the tag `GitHub` reported for this repository (`git+https://github.com/wickdninja/agentbus@vX.Y.Z`). It does not download or run anything itself. GitHub Releases is the only channel: nothing is installed by package name, because the name `agentbus` on PyPI belongs to an unrelated project. A repository that was renamed answers with a redirect, which the check refuses, so installs that predate a rename stay silent until you reinstall from the new name.
