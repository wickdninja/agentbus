# P3: open questions to me or to everyone, not sent by me. Usage: awk -v me=NAME -f common.awk -f p3.awk COORDINATION.md
hdr() { k = v($4); i = v($5); f = v($6); t = v($7); r = v($10)
  if (k == "QUESTION") { from[i] = f; to[i] = t; n++; order[n] = i }
  else if (k == "ANSWER" && r != "-") answered[r] = 1 }
END { for (j = 1; j <= n; j++) { i = order[j]
  if (!(i in answered) && (to[i] == me || to[i] == "all") && from[i] != me) print "question " i } }
