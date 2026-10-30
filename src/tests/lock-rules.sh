#!/bin/bash
# Three rules ask whether the desktop session is locked before OmacVM writes
# under ~/.config/omarchy/plugins or asks the shell to rescan:
# guest/session-lock.sh (install-plugin.sh, omacvm-plugins, restart-shell.sh,
# and omacvm-displays through session_state) and Omanotch's own copies.py
# and monitor/display-panel.py. One table of the shell's answers goes through
# all of them, so they cannot drift apart. Busy (the shell runs and does not
# answer: starting, reloading) counts as locked for every caller; no shell
# does not (nothing to reload). Stand-ins for Omarchy's shell and pgrep.
#   src/tests/lock-rules.sh [SRC]   (SRC: another checkout's src/; v3.2.13's fails at busy)
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$(cd "${1:-$R/src}" && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d "${TMPDIR:-/tmp}/lock-rules.XXXXXX"); trap 'rm -rf "$T"' EXIT
B=$T/bin S=$T/s
mkdir -p "$B" "$S"

# The shell answers while $S/up exists and runs while $S/proc does. Its lock
# status is $S/status (none: an Omarchy without that call), isLocked
# $S/islocked; with $S/warn, Qt's locale warning comes first on stdout (qs
# without a locale).
cat > "$B/omarchy-shell" <<'EOF'
#!/bin/bash
[[ $1 == -q ]] && shift
[[ -e $S/up ]] || exit 1
[[ -e $S/warn ]] && cat "$S/warn"
case "$1 $2" in
  "shell ping") exit 0 ;;
  "lock status") [[ -e $S/status ]] || { echo "Function not found." >&2; exit 1; }; cat "$S/status" ;;
  "lock isLocked") cat "$S/islocked" ;;
  *) exit 1 ;;
esac
EOF
cat > "$B/pgrep" <<'EOF'
#!/bin/bash
[[ -f $S/proc ]] || exit 1
cat "$S/proc"
EOF
chmod 755 "$B"/*
export PATH="$B:$PATH" S OMARCHY_PATH=$T
WARN='  WARN: Detected locale "C" with character encoding "ANSI_X3.4-1968", which is not UTF-8.
Qt depends on a UTF-8 locale, and has switched to "C.UTF-8" instead.'

st() {   # REQUESTED SESSIONLOCKED SECURE [LOCKED]: the lock status as Omarchy's shell answers it
  printf '{"locked":%s,"requested":%s,"pending":false,"sessionLocked":%s,"secure":%s,"realScreens":1,"lastEvent":"x"}' \
    "${4:-$1}" "$1" "$2" "$3"
}

# row WHAT WANT SHELL STATUS ISLOCKED [warn]: SHELL up (answers), busy (runs,
# no answer) or down; STATUS - for none. WANT: session-lock.sh's word.
row() {
  local want=$2 locked=open py
  rm -f "$S"/*
  case $3 in
    up) touch "$S/up"; echo 4242 > "$S/proc" ;;
    busy) echo 4242 > "$S/proc" ;;
  esac
  [[ $4 == - ]] || printf '%s\n' "$4" > "$S/status"
  printf '%s\n' "$5" > "$S/islocked"
  [[ ${6:-} == warn ]] && printf '%s\n' "$WARN" > "$S/warn"
  [[ $want == locked || $want == busy ]] && locked=locked
  py=$(python3 "$R/src/tests/lock-rules.py" "$SRC" 2>&1)
  expect "$1: session-lock.sh" "$want" "$(bash "$SRC/guest/session-lock.sh" 2>&1)"
  expect "$1: omacvm-displays" "$want" "$(sed -n 's/^omacvm-displays //p' <<< "$py")"
  expect "$1: copies.py" "$locked" "$(sed -n 's/^copies\.py //p' <<< "$py")"
  expect "$1: display-panel.py" "$locked" "$(sed -n 's/^display-panel\.py //p' <<< "$py")"
  [[ $py == *Traceback* ]] && { echo "$py" | sed 's/^/    /'; fail=1; }
}

row "open" open up "$(st false false false)" false
row "lock requested" locked up "$(st true false false)" true
row "session locked" locked up "$(st false true false)" true
row "secure" locked up "$(st false false true)" true
row "isLocked stuck after an unlock (omarchy-mac#738)" open up "$(st false false false true)" true
row "Qt's warning first, locked" locked up "$(st true true true)" true warn
row "Qt's warning first, open" open up "$(st false false false)" true warn
row "no status call, isLocked true" locked up - true
row "no status call, isLocked false" open up - false
row "status not an object" open up null false
row "busy: the shell runs, does not answer" busy busy - ""
row "down: no shell" down down - ""

exit $fail
