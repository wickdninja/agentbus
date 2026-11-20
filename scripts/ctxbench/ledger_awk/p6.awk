# P6: who works on item Y: a live claim overlapping src/Y/, or an open todo with topic Y whose owner is on the roster.
# Usage: awk -v y=SLUG -v now=ISO -f common.awk -f p6.awk COORDINATION.md
hdr() { claims_line(); k = v($4); i = v($5); f = v($6); t = v($7); r = v($10)
  if (k == "TODO" && v($8) == y) { owner[i] = (t == "all") ? f : t }
  else if ((k == "DONE" || k == "DROPPED") && r != "-") closed[r] = 1
  else if (k == "JOIN") on[f] = 1
  else if (k == "LEAVE") delete on[f] }
END { t = epoch(now)
  for (p in holder) if (until[p] > t && overlaps(p, "src/" y "/")) who[holder[p]] = 1
  for (i in owner) if (!(i in closed) && (owner[i] in on)) who[owner[i]] = 1
  for (w in who) print "agent " w }
