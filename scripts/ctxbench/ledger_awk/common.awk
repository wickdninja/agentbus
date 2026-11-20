# Shared by every ctxbench Ledger-awk reducer (docs/evals/ctxbench-protocol.md, "Ledger-awk"). POSIX awk only.
# A header line is "- eid=E1 ts=T kind=K id=I from=F to=T topic=P path=R reply_to=Q | text"; the fields before "|"
# are percent-encoded and hold no space. Continuation lines of a body start with two spaces.
function v(s) { sub(/^[a-z_]+=/, "", s); return s }
function hdr() { return ($0 ~ /^- eid=E[0-9]+ ts=[^ ]+ kind=[A-Z]+ id=[^ ]+ from=[^ ]+ to=[^ ]+ topic=[^ ]+ path=[^ ]+ reply_to=[^ ]+ \|/) }
function epoch(ts,   y, m, d, era, yoe, doy, doe) {
  y = substr(ts, 1, 4) + 0; m = substr(ts, 6, 2) + 0; d = substr(ts, 9, 2) + 0
  if (m <= 2) y--
  era = int(y / 400); yoe = y - era * 400
  doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return (era * 146097 + doe - 719468) * 86400 + substr(ts, 12, 2) * 3600 + substr(ts, 15, 2) * 60 + substr(ts, 18, 2)
}
function overlaps(a, b) {
  sub(/\/$/, "", a); sub(/\/$/, "", b)
  return a == b || index(b, a "/") == 1 || index(a, b "/") == 1
}
# Claims, keyed by resource as the bus keys them: holder and expiry (epoch). CLAIM and TAKEOVER (re)start 120 minutes.
function claims_line(   k, f, p, t) {
  k = v($4); f = v($6); p = v($9); t = epoch(v($3))
  if (k == "CLAIM" || k == "TAKEOVER") { holder[p] = f; until[p] = t + 7200 }
  else if (k == "RELEASE" && holder[p] == f) { delete holder[p]; delete until[p] }
}
