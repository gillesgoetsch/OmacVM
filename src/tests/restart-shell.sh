#!/bin/bash
# What an apply owes the Omarchy shell (src/guest/restart-shell.sh, run by
# guest/install.sh at the end of an apply and by omacvm-plugins.service at
# login) without a VM: staged bar widgets in place (omacvm-plugins), the
# colour fix on the user's clones, one shell restart; at once unless the
# session is locked, then right after the unlock. "Locked" is Omarchy's lock
# status read at the call, not isLocked, which Quickshell 0.3.2 leaves true
# after the first unlock (omarchy-mac#738); a shell that does not answer
# (busy) counts as locked. omarchy-shell, omarchy-restart-shell, systemd-run,
# systemctl, pgrep, sleep, omacvm-plugins and shell-colors.py are stand-ins.
#   src/tests/restart-shell.sh [SCRIPT]   (SCRIPT: another restart-shell.sh to test)
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
K0=${1:-$R/src/guest/restart-shell.sh}
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
[[ -f $K0 ]] || { echo "FAIL $K0 is missing"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/g"
# The script and session-lock.sh beside it, omacvm-plugins and shell-colors.py
# moved to the stand-ins.
for f in "$K0" "$(dirname "$K0")/session-lock.sh"; do
  [[ -f $f ]] || continue
  s=$(sed -e "s#/usr/local/bin/omacvm-plugins#$T/bin/omacvm-plugins#g" \
          -e "s#/usr/local/lib/omacvm/shell-colors.py#$T/bin/shell-colors.py#g" "$f")
  printf '%s\n' "$s" > "$T/g/$(basename "$f")"
done
K=$T/g/$(basename "$K0")
# omarchy-shell: answers while $S/up exists, from $S/status and $S/islocked
# (absent: the call is unknown, exit 1 as Omarchy's omarchy-shell says it).
# The shell runs while $S/proc exists (its pid in it).
cat > "$T/bin/omarchy-shell" <<'EOF'
#!/bin/bash
echo "omarchy-shell $*" >> "$CALLS"
[[ -e $S/up ]] || exit 1
case "$1 $2" in
  "shell ping") exit 0 ;;
  "lock status") [[ -f $S/status ]] || exit 1; cat "$S/status" ;;
  "lock isLocked") [[ -f $S/islocked ]] || exit 1; cat "$S/islocked" ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/bash
[[ -f $S/proc ]] || exit 1
cat "$S/proc"
EOF
# omarchy-restart-shell: refuses (exit 1, the same shell) while $S/refuse exists.
cat > "$T/bin/omarchy-restart-shell" <<'EOF'
#!/bin/bash
echo "omarchy-restart-shell" >> "$CALLS"
if [[ -e $S/refuse ]]; then rm -f "$S/refuse"; exit 1; fi
[[ -f $S/proc ]] && echo $(( $(cat "$S/proc") + 1 )) > "$S/proc"
exit 0
EOF
cat > "$T/bin/systemd-run" <<'EOF'
#!/bin/bash
echo "systemd-run $*" >> "$CALLS"
EOF
# systemctl --user is-active: while $S/active exists; stop removes it.
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
case " $* " in
  *" is-active "*) [[ -e $S/active ]] ;;
  *" stop "*) rm -f "$S/active" ;;
esac
EOF
# omacvm-plugins: moves the staged copies (and notes the restart when
# $S/replaces exists); shell-colors.py: prints $S/colors.
cat > "$T/bin/omacvm-plugins" <<'EOF'
#!/bin/bash
echo "omacvm-plugins" >> "$CALLS"
st=$HOME/.local/state/omacvm
if [[ -d $st/plugins-staged ]]; then rm -rf "$st/plugins-staged"; [[ -e $S/replaces ]] && touch "$st/restart-shell"; fi
exit 0
EOF
cat > "$T/bin/shell-colors.py" <<'EOF'
#!/bin/bash
echo "shell-colors $*" >> "$CALLS"
cat "$S/colors" 2>/dev/null || echo "nothing to do (QtQuick 6.11 already where needed)"
EOF
# sleep: counts; $S/after-N runs (a script) after the Nth one. 300: a loop
# that never ends, stopped.
cat > "$T/bin/sleep" <<'EOF'
#!/bin/bash
echo "sleep $*" >> "$CALLS"
n=$(( $(cat "$S/sleeps" 2>/dev/null || echo 0) + 1 )); echo $n > "$S/sleeps"
[[ -f $S/after-$n ]] && bash "$S/after-$n"
(( n < 300 )) || kill -9 $PPID
exit 0
EOF
chmod +x "$T/bin/"*
export PATH=$T/bin:$PATH CALLS=$T/calls S=$T/s HOME=$T/home
unset XDG_STATE_HOME
ST=$HOME/.local/state/omacvm
FLAG=$ST/restart-shell

# Omarchy's lock status as omarchy-mac's shell answers it (JSON.stringify).
status() {   # LOCKED REQUESTED SESSIONLOCKED SECURE
  printf '{"locked":%s,"requested":%s,"pending":false,"sessionLocked":%s,"secure":%s,"realScreens":1,"passwordPam":true,"fingerprint":false,"authenticating":false,"lastEvent":"unlocked","lastEventAt":"2026-10-29T04:33:00.914Z"}\n' "$@"
}
WARN=$'\e[33m  WARN\e[0m: Detected locale "C" with character encoding "ANSI_X3.4-1968", which is not UTF-8.\nQt depends on a UTF-8 locale, and has switched to "C.UTF-8" instead.'
# A shell that runs and answers, with a restart owed (a changed widget).
fresh() { rm -rf "$S" "$CALLS" "$HOME"; mkdir -p "$S" "$ST"; : > "$CALLS"; touch "$S/up" "$FLAG"; echo 100 > "$S/proc"; }
calls() { grep -v -e '^omarchy-shell' -e '^systemctl --user is-active' "$CALLS" | paste -sd'|' -; }
has() { [[ -e $1 ]] && echo yes || echo no; }
SELF=$K
QUEUED="systemd-run --user --quiet --collect --unit=omacvm-restart-shell bash $SELF --after-unlock"
COLORS="shell-colors $HOME/.config/omarchy/plugins"
NOW="omacvm-plugins|omarchy-restart-shell"
SAYS="the Omarchy shell gets the new bar widgets right after the next unlock"

# 1. Unlocked after an earlier lock: isLocked still says true (Quickshell 0.3.2).
fresh; status true false false false > "$S/status"; echo true > "$S/islocked"
out=$(bash "$K"); rc=$?
expect "unlocked after an unlock (isLocked stale): restarted now" "$NOW 0 no" "$(calls) $rc $(has "$FLAG")"
expect "  nothing said" "" "$out"

# 2. Never locked.
fresh; status false false false false > "$S/status"; echo false > "$S/islocked"
bash "$K" >/dev/null
expect "never locked: restarted now" "$NOW" "$(calls)"

# 3. The lock screen is up: a user unit does it after the unlock.
fresh; status true true false true > "$S/status"; echo true > "$S/islocked"
out=$(bash "$K"); rc=$?
expect "locked: not now, after the unlock" "$QUEUED 0 yes" "$(calls) $rc $(has "$FLAG")"
expect "  says so" "$SAYS" "$out"

# 4. On its way (asked, the compositor not yet locked) and locked without the
#    request (another path): both wait too.
fresh; status true true false false > "$S/status"
bash "$K" >/dev/null
expect "lock requested: waits" "$QUEUED" "$(calls)"
fresh; status true false true false > "$S/status"
bash "$K" >/dev/null
expect "session locked: waits" "$QUEUED" "$(calls)"

# 5. The waiter: locked for two looks, then unlocked: everything owed, then
#    one restart, 2 s after the unlock.
fresh; status true true true true > "$S/status"
status true false false false > "$S/unlocked"
echo "cp '$S/unlocked' '$S/status'" > "$S/after-2"
bash "$K" --after-unlock >/dev/null; rc=$?
expect "waiter: right after the unlock" "sleep 5|sleep 5|sleep 2|$NOW 0 no" "$(calls) $rc $(has "$FLAG")"

# 6. The waiter while the shell goes away (logout, shutdown): ends without a
#    restart once it is gone twice in a row; the note stays for the next login.
fresh; status true true true true > "$S/status"
echo "rm -f '$S/up' '$S/proc'" > "$S/after-1"
bash "$K" --after-unlock >/dev/null; rc=$?
expect "waiter: the shell went away: no restart" "sleep 5|sleep 5 0 yes" "$(calls) $rc $(has "$FLAG")"

# 7. Not running at all (nobody logged in): nothing, the note goes.
fresh; rm -f "$S/up" "$S/proc"; status true false false false > "$S/status"
out=$(bash "$K"); rc=$?
expect "no shell: nothing" "||0 no" "$(calls)|$out|$rc $(has "$FLAG")"

# 8. An Omarchy without the status call: isLocked as before.
fresh; echo true > "$S/islocked"
bash "$K" >/dev/null
expect "no status call, isLocked true: waits" "$QUEUED" "$(calls)"
fresh; echo false > "$S/islocked"
bash "$K" >/dev/null
expect "no status call, isLocked false: restarted" "$NOW" "$(calls)"

# 9. A C locale: qs prints Qt's warning before each answer.
fresh; { echo "$WARN"; status true false false false; } > "$S/status"; { echo "$WARN"; echo true; } > "$S/islocked"
bash "$K" >/dev/null
expect "C locale, unlocked: restarted" "$NOW" "$(calls)"
fresh; { echo "$WARN"; status true true true true; } > "$S/status"; { echo "$WARN"; echo true; } > "$S/islocked"
bash "$K" >/dev/null
expect "C locale, locked: waits" "$QUEUED" "$(calls)"
fresh; { echo "$WARN"; echo true; } > "$S/islocked"
bash "$K" >/dev/null
expect "C locale, no status call, isLocked true: waits" "$QUEUED" "$(calls)"

# 10. Nothing owed (no widget changed, nothing staged or queued): nothing at
#     all, locked or not; no job waits for an unlock.
fresh; rm -f "$FLAG"; status false false false false > "$S/status"
bash "$K" >/dev/null
expect "nothing owed, unlocked: nothing" "" "$(calls)"
fresh; rm -f "$FLAG"; status true true true true > "$S/status"
bash "$K" >/dev/null
expect "nothing owed, locked: no waiter" "" "$(calls)"

# 11. Only a staged copy (a new widget: no restart owed by itself).
fresh; rm -f "$FLAG"; mkdir -p "$ST/plugins-staged/omacvm.x"; status true true true true > "$S/status"
bash "$K" >/dev/null
expect "a staged copy, locked: waits" "$QUEUED" "$(calls)"
fresh; rm -f "$FLAG"; mkdir -p "$ST/plugins-staged/omacvm.x"; status false false false false > "$S/status"
bash "$K" >/dev/null
expect "a staged new widget, unlocked: in place, no restart" "omacvm-plugins" "$(calls)"
fresh; rm -f "$FLAG"; mkdir -p "$ST/plugins-staged/omacvm.x"; touch "$S/replaces"; status false false false false > "$S/status"
bash "$K" >/dev/null
expect "a staged copy over a loaded one, unlocked: in place, one restart" "$NOW" "$(calls)"

# 12. The colour fix on the user's clones before the restart.
fresh; rm -f "$FLAG"; mkdir -p "$ST/plugins-staged/omacvm.x" "$HOME/.config/omarchy/plugins"
echo "patched 1 file (QtQuick 6.11)" > "$S/colors"; status false false false false > "$S/status"
bash "$K" >/dev/null
expect "the clones' colours patched: then one restart" "omacvm-plugins|$COLORS|omarchy-restart-shell" "$(calls)"

# 13. Busy (the shell runs, does not answer: a reload, a restart) is not gone:
#     the waiter waits it out; started then too.
fresh; status true false false false > "$S/status"; rm -f "$S/up"
echo "touch '$S/up'" > "$S/after-2"
bash "$K" --after-unlock >/dev/null
expect "waiter: busy twice, then open: restarted" "sleep 5|sleep 5|sleep 2|$NOW" "$(calls)"
fresh; rm -f "$S/up"
bash "$K" >/dev/null
expect "busy at the end of an apply: waits" "$QUEUED" "$(calls)"

# 14. A waiter already there (it reads the files when the session opens).
fresh; status true true true true > "$S/status"; touch "$S/active"
out=$(bash "$K")
expect "a waiter already there: no second one" "|$SAYS (already waiting)" "$(calls)|$out"

# 15. Omarchy refuses the restart (the session locked again): the waiter
#     waits again, then restarts once.
fresh; status true false false false > "$S/status"; touch "$S/refuse"
bash "$K" --after-unlock >/dev/null
expect "restart refused: waits, then once" "sleep 2|$NOW|sleep 5|sleep 2|$NOW" "$(calls)"
expect "  the note gone after it" "no" "$(has "$FLAG")"

# 16. install.sh runs this script at the end when a shell runs and drops the note when none does; nothing
#     of OmacVM's asks isLocked first any more.
I=$R/src/guest/install.sh
expect "install.sh runs restart-shell.sh when a shell runs" 1 "$(grep -c '^  user_script "$R/guest/restart-shell.sh" || true$' "$I")"
expect "install.sh drops the note without a shell" 1 "$(grep -c '^  home_run rm -f "$RS"' "$I")"
expect "no isLocked in install.sh" 0 "$(grep -c 'lock isLocked' "$I")"
expect "copies.py asks status first" 1 "$(grep -c '"omarchy-shell", "lock", "status"' "$R/src/omanotch/guest/copies.py")"

exit $fail
