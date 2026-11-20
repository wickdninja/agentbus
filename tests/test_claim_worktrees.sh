#!/bin/bash
set -euo pipefail
# A claim held in a different git worktree warns and names the holder instead of refusing (issue 86 L1): separate
# checkouts never touch the same file on disk, and 88% of 241 refusals on real buses were across worktrees. In the same
# checkout nothing changes: an overlap is refused, folder claims included. A checkout is the working tree an agent
# joined in (agents.cwd): the nearest folder above it holding .git (a folder in the main checkout, a file in a linked
# worktree). An agent whose folder is in no checkout, or is gone, is treated as sharing yours: refused as before. Only
# paths: a scheme name (area:ios-sim) is one thing every checkout shares and is refused across worktrees too.
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export AGENTBUS_DB="$T/bus.db"
R="$T/repo"; WT="$T/lane-wt"
git init -q "$R"; mkdir -p "$R/src/dir" "$R/sub"; echo a > "$R/src/a.py"
git -C "$R" -c user.name=t -c user.email=t@t add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm init
git -C "$R" worktree add -q "$WT" -b lane
RP=$(cd "$R" && pwd -P)   # the checkout as the tool names it: resolved (macOS TMPDIR is under a /var link)
mkdir -p "$T/plain"

(cd "$R" && agentbus --as main join >/dev/null)
(cd "$R/sub" && agentbus --as peer join >/dev/null)        # the same checkout, a folder below its top
(cd "$WT" && agentbus --as lane join >/dev/null)
(cd "$T/plain" && agentbus --as outside join >/dev/null)  # in no checkout
(cd "$R" && agentbus --as main claim src/a.py --purpose "parser" >/dev/null && agentbus --as main claim src/dir/ --purpose "the dir" >/dev/null)
holder_of() { agentbus --json claims | python3 -c 'import json,sys; print(" ".join(sorted(c["resource"] + "@" + c["agent"] for c in json.load(sys.stdin)["items"])))'; }

echo "TEST: the same file held in another worktree: a warning naming the holder, exit 0, the holder keeps it"
out=$(cd "$WT" && agentbus --as lane claim src/a.py --purpose "lane work" 2>"$T/err") || fail "a claim held in another worktree was refused: $(cat "$T/err")"
grep -qF "main holds src/a.py in another checkout ($RP)" "$T/err" || fail "the warning does not name the holder and its checkout: $(cat "$T/err")"
case "$out" in "not recorded: src/a.py stays main's"*) ;; *) fail "the result line does not say the claim was not recorded: $out" ;; esac
[ "$(holder_of)" = "src/a.py@main src/dir/@main" ] || fail "the holder lost its claim: $(holder_of)"
j=$(cd "$WT" && agentbus --as lane --json claim src/a.py 2>/dev/null) || fail "--json: refused"
printf '%s' "$j" | python3 -c 'import json,sys; r=json.load(sys.stdin); w=r["warnings"]; assert r["recorded"] is False and [x["code"] for x in w] == ["held_in_other_checkout"] and w[0]["name"] == "main" and w[0]["held"] == "src/a.py" and w[0]["checkout"].endswith("/repo"), r' \
  || fail "--json lacks recorded false and the warning: $j"
ok "held in another worktree: warned, named, not taken"

echo "TEST: a file inside a folder held in another worktree is claimed, with the warning"
out=$(cd "$WT" && agentbus --as lane claim src/dir/x.py 2>"$T/err") || fail "refused: $(cat "$T/err")"
case "$out" in "claimed src/dir/x.py "*) ;; *) fail "not claimed: $out" ;; esac
grep -qF "main holds src/dir/ in another checkout" "$T/err" || fail "no warning: $(cat "$T/err")"
[ "$(holder_of)" = "src/a.py@main src/dir/@main src/dir/x.py@lane" ] || fail "claims after a cross-worktree claim: $(holder_of)"
ok "an overlapping claim in another worktree is recorded beside the holder's"

echo "TEST: a batch across worktrees claims what is free and leaves the held file to its holder"
j=$(cd "$WT" && agentbus --as lane --json claim src/a.py src/b.py 2>/dev/null) || fail "batch refused"
printf '%s' "$j" | python3 -c 'import json,sys; r=json.load(sys.stdin); c={x["resource"]: x.get("recorded", True) for x in r["claims"]}; assert c == {"src/a.py": False, "src/b.py": True} and len(r["warnings"]) == 1, r' \
  || fail "batch result: $j"
ok "a batch takes the free resource"

echo "TEST: in the same checkout an overlap is still refused, folder claims included"
(cd "$R/sub" && agentbus --as peer claim src/a.py 2>"$T/err") && fail "the same checkout took a held file"
grep -qF "refused: src/a.py is claimed by main" "$T/err" || fail "the same-checkout refusal changed: $(cat "$T/err")"
(cd "$R/sub" && agentbus --as peer claim src/dir/y.py 2>"$T/err") && fail "the same checkout took a file under a held folder"
grep -qF "overlaps src/dir/" "$T/err" || fail "the folder refusal changed: $(cat "$T/err")"
ok "same checkout: refused as before"

echo "TEST: a worktree's lane is refused by another lane in the same worktree"
(cd "$WT" && agentbus --as lane2 join >/dev/null)
(cd "$WT" && agentbus --as lane2 claim src/dir/x.py 2>"$T/err") && fail "the same worktree took lane's file"
grep -qF "claimed by lane" "$T/err" || fail "the same-worktree refusal: $(cat "$T/err")"
ok "same worktree: refused"

echo "TEST: a scheme name (a simulator, a device, a database) is one thing every checkout shares: refused across worktrees"
# Bug it catches: the worktree rule let two lanes in two worktrees hold area:ios-sim at once, the mutex the skill teaches.
(cd "$R" && agentbus --as main claim area:ios-sim --ttl-min 30 >/dev/null)
(cd "$WT" && agentbus --as lane claim area:ios-sim 2>"$T/err") && fail "a lane in another worktree took area:ios-sim"
grep -qF "refused: area:ios-sim is claimed by main" "$T/err" || fail "the area refusal: $(cat "$T/err")"
ok "area:NAME stays a mutex across worktrees"

echo "TEST: an agent in no checkout is refused as before"
(cd "$T/plain" && agentbus --as outside claim src/a.py 2>"$T/err") && fail "an agent outside any checkout took a held file"
grep -qF "claimed by main" "$T/err" || fail "the outside refusal: $(cat "$T/err")"
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("UPDATE agents SET cwd=? WHERE name=?", (sys.argv[2], "lane2")); c.commit()' "$AGENTBUS_DB" "$T/gone/folder"
(cd "$WT" && agentbus --as lane2 claim src/a.py 2>"$T/err") && fail "an agent whose folder is gone took a held file"
grep -qF "claimed by main" "$T/err" || fail "the gone-folder refusal: $(cat "$T/err")"
ok "no checkout, or a folder that is gone: refused"
