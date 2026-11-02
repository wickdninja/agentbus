# Changelog

## 0.1.0 - 2026-11-01

Initial release: a workspace bus in any directory, shared by its repos and linked worktrees. Buses nest; --up selects an outer bus and buses lists the chain. AGENTBUS_DB assigns an explicit bus to sandboxed lanes.

Per-agent inboxes, shared facts and history, advisory expiring claims, an activity log, JSON output, a live watch view, a shared goal (`goal`, shown by join, status and watch), emoji in watch on a terminal (`AGENTBUS_NO_EMOJI=1` turns them off), and an agent coordination skill. Init installs a local copy; path claims are relative to the bus directory.

Supports macOS and Linux, Python 3.9+, and Git 2.31+. One file, standard library only.
