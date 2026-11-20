# P5: the newest decision (kind DECISION, topic decision) and its subject, the text after "Subject: " on the last line
# of its body. Usage: awk -f common.awk -f p5.awk COORDINATION.md
hdr() { inrec = 0
  if (v($4) == "DECISION" && v($8) == "decision") { inrec = 1; id = v($5); body = $0; sub(/^[^|]*\| ?/, "", body); last = body }
  next }
inrec { line = $0; sub(/^  /, "", line); last = line }
END { if (id == "") { print "decision none"; exit }
  s = last; if (sub(/^Subject: /, "", s)) print "decision " id " " s; else print "decision " id }
