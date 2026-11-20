# P4: todos I may take. Usage: awk -v me=NAME -f common.awk -f p4.awk COORDINATION.md
hdr() { k = v($4); i = v($5); f = v($6); t = v($7); r = v($10); ts = v($3)
  if (k == "TODO") { owner[i] = (t == "all") ? f : t; at[i] = ts; n++; order[n] = i }
  else if ((k == "DONE" || k == "DROPPED") && r != "-") closed[r] = 1
  else if (k == "JOIN") on[f] = 1
  else if (k == "LEAVE") { delete on[f]; if (ts > lastleave[f]) lastleave[f] = ts } }
END { for (j = 1; j <= n; j++) { i = order[j]; o = owner[i]
  if (i in closed) continue
  if (o == me || (!(o in on) && (o in lastleave) && lastleave[o] >= at[i])) print "todo " i } }
