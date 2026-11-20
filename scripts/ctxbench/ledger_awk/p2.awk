# P2: who holds path X. Usage: awk -v x=PATH -v now=ISO -f common.awk -f p2.awk COORDINATION.md
hdr() { claims_line() }
END { t = epoch(now); for (p in holder) if (until[p] > t && overlaps(p, x)) print "holder " holder[p] }
