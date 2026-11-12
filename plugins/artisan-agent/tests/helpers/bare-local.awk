# Lists every `local` name declared without a value, as "file:line: name".
# Usage: awk -f bare-local.awk file...
# Bash 4+ leaves a bare `local x` unset, so reading it under `set -u` dies there
# but not on bash 3.2 (#127). `local x=`, `local x="$1"` and `local -a x=()` pass.
# Works line by line, joining backslash continuations (reported at the first
# line); heredoc bodies are not recognised. Portable to the awk on macOS and Linux.

function is_boundary(pre,   t) {
  t = pre
  sub(/[ \t]+$/, "", t)
  if (t == "") return 1
  if (t ~ /[;&|{(]$/) return 1
  if (t ~ /(^|[ \t;&|{(])(then|do|else)$/) return 1
  return 0
}

function scan_word(s, i,   n, c, q, depth, w) {
  # Reads one shell word starting at i; returns it in WORD and the next index in NEXT.
  n = length(s); w = ""; q = ""; depth = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (q == "'") { w = w c; if (c == "'") q = ""; i++; continue }
    if (c == "\\") { w = w c substr(s, i + 1, 1); i += 2; continue }
    if (q == "\"") { w = w c; if (c == "\"") q = ""; i++; continue }
    if (c == "'" || c == "\"") { q = c; w = w c; i++; continue }
    if (c == "$" && (substr(s, i + 1, 1) == "(" || substr(s, i + 1, 1) == "{")) {
      w = w c substr(s, i + 1, 1); depth++; i += 2; continue
    }
    if (c == "(" && substr(w, length(w), 1) == "=") { w = w c; depth++; i++; continue }
    if (depth > 0) {
      if (c == "(") depth++
      if (c == ")" || c == "}") depth--
      w = w c; i++; continue
    }
    if (c ~ /[ \t;&|<>)]/) break
    w = w c; i++
  }
  WORD = w; NEXT = i
}

{
  if ($0 ~ /\\$/ && FNR_START == 0) { FNR_START = FNR }
  if ($0 ~ /\\$/) { buf = buf substr($0, 1, length($0) - 1); next }
  line = buf $0; buf = ""
  start = FNR_START ? FNR_START : FNR; FNR_START = 0
  n = length(line)
  q = ""
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (q != "") { if (c == "\\" && q == "\"") i++; else if (c == q) q = ""; continue }
    if (c == "\\") { i++; continue }
    if (c == "'" || c == "\"") { q = c; continue }
    if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t]/)) break
    if (substr(line, i, 5) != "local") continue
    if (i > 1 && substr(line, i - 1, 1) !~ /[ \t;&|{(]/) continue
    if (substr(line, i + 5, 1) !~ /[ \t]/) continue
    if (!is_boundary(substr(line, 1, i - 1))) continue
    j = i + 5
    while (j <= n) {
      while (j <= n && substr(line, j, 1) ~ /[ \t]/) j++
      if (j > n) break
      c = substr(line, j, 1)
      if (c ~ /[;&|)#<>]/) break
      scan_word(line, j)
      j = NEXT
      if (WORD ~ /^-/) continue
      if (WORD ~ /^[A-Za-z_][A-Za-z_0-9]*$/) printf "%s:%d: %s\n", FILENAME, start, WORD
    }
    i = j
  }
}
