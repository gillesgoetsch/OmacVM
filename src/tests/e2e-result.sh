#!/bin/bash
# cc-switches.sh's row texts stay UTF-8 and result.json is always written (3.4.3 and 3.4.4: a
# row cut in the middle of "─" by a byte count, ${s:0:160} with no LANG, and the result
# writer stopped on it, so the e2e gate had no result.json):
#  - clip N TEXT gives N characters in any locale, never half of one;
#  - a summary.tsv with a byte that is not UTF-8 still gives result.json (U+FFFD for it);
#  - cc-switches.sh cuts row texts only with clip (no ${s:0:N}, no cut -c on text).
#   src/tests/e2e-result.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
PY=${PYTHON:-/usr/bin/python3}
H=$R/src/tests/e2e
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-e2e-result.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}
utf8() { "$PY" -I -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null && echo utf-8 || echo "not utf-8"; }
clip() { "$PY" -I "$H/cc-result.py" clip "$1" "$2"; }

# The control centre's off box, as switch-control-centre-off saw it on 3.4.4.
box="seconds: 7.3; asked:  ╭─ OmacVM control centre: off $(printf '─%.0s' $(seq 1 200))╮"
c=$(LC_ALL=C; printf '%s' "${box:0:160}")
expect "the cause: \${s:0:160} with no LANG counts bytes and cuts a character" "not utf-8" "$(printf '%s' "$c" | utf8)"
for loc in C en_US.UTF-8; do
  c=$(LC_ALL=$loc clip 160 "$box")
  expect "clip 160 in $loc: UTF-8, 160 characters" "utf-8 160" \
    "$(printf '%s' "$c" | utf8) $("$PY" -I -c 'import sys; print(len(sys.argv[1]))' "$c")"
done
expect "clip of a short text: as it is" "a ─ b" "$(clip 160 "a ─ b")"
half=$(printf 'tail: \342\224')
expect "clip of a text that ends in half a character: U+FFFD, UTF-8" "utf-8 yes" \
  "$(clip 40 "$half" | utf8) $([[ $(clip 40 "$half") == *$'\xef\xbf\xbd' ]] && echo yes || echo no)"

# result.json from a summary.tsv with 3.4.4's cut row and a FAIL row cut the same way.
w() { "$PY" -I "$H/cc-result.py" write "$T" abc123 3.4.5 "$@" all; }
{ printf 'app\tok\t3.4.5\n'
  printf 'switch-control-centre-off\tok\tseconds: 7.3; asked:  \342\225\255\342\224\200 OmacVM control centre: off \342\224\200\342\224\n'
  printf 'touchid-no\tFAIL\tcc: \342\224\n'
  printf 'fastnet\tBLOCKED\tthe person'"'"'s VM uses the fast network\n'; } > "$T/summary.tsv"
rm -f "$T/result.json"; w 2 1 1 0 60
expect "a byte that is not UTF-8 in summary.tsv: result.json is written" yes "$([[ -s $T/result.json ]] && echo yes || echo no)"
expect "... its counts, not passed, the FAIL and BLOCKED rows with U+FFFD" \
  "{'ok': 2, 'FAIL': 1, 'BLOCKED': 1, 'skip': 0} False 2 touchid-no True" \
  "$("$PY" -I -c 'import json, sys; o = json.load(open(sys.argv[1])); print(o["counts"], o["pass"], len(o["not_ok"]), o["not_ok"][0][0], o["not_ok"][0][2] == "cc: �")' "$T/result.json")"
printf 'app\tok\t3.4.5\n' > "$T/summary.tsv"; w 1 0 0 0 60
expect "every row ok: passed" "True abc123 all" \
  "$("$PY" -I -c 'import json, sys; o = json.load(open(sys.argv[1])); print(o["pass"], o["commit"], o["only"])' "$T/result.json")"

# cc-switches.sh: no byte cuts of row texts left (cut -c only on hashes and the commit).
expect "cc-switches.sh: no \${x:0:N}" "" "$(grep -n '\${[A-Za-z_]*:0:[0-9]' "$H/cc-switches.sh")"
expect "cc-switches.sh: cut -c only on shasum and the commit" "" \
  "$(grep -n 'cut -c' "$H/cc-switches.sh" | grep -v '^[0-9]*: *#' | grep -v 'shasum\|OmacVMCommit')"

(( fail == 0 )) && echo "e2e-result: all passed"
exit $fail
