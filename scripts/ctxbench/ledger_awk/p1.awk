# P1: my open todos. Usage: awk -v me=NAME -f common.awk -f p1.awk COORDINATION.md
hdr() { k = v($4); i = v($5); f = v($6); t = v($7); r = v($10)
  if (k == "TODO") { owner[i] = (t == "all") ? f : t; n++; order[n] = i }
  else if ((k == "DONE" || k == "DROPPED") && r != "-") closed[r] = 1 }
END { for (j = 1; j <= n; j++) { i = order[j]; if (!(i in closed) && owner[i] == me) print "todo " i } }
