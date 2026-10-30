#!/bin/bash
# Bar widgets and Omarchy's lock screen, without a VM. The shell of
# omarchy-mac 4.0.3 reloads every plugin, its lock screen too, on a write
# under ~/.config/omarchy/plugins or a rescanPlugins call; under the lock the
# new lock screen has no password field. So an apply on a locked VM writes
# nothing there (lib/install-plugin.sh stages the copy), omacvm-plugins does
# nothing while locked, and guest/restart-shell.sh puts it all in place right
# after the unlock, with one shell restart. An unchanged plugin in its place
# costs nothing, locked or not. Runs the real scripts with stand-ins for
# Omarchy, systemd, sudo, getent and pgrep.
#   src/tests/plugin-lock.sh [SRC]   (SRC: another checkout's src/; v3.2.12's fails)
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$(cd "${1:-$R/src}" && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset XDG_STATE_HOME XDG_CONFIG_HOME
X=$T/root G=$T/src B=$T/bin S=$T/s H=$T/home
mkdir -p "$X/usr/local/bin" "$X/etc/systemd/user" "$X/usr/local/lib/omacvm" "$G" "$B"
# The scripts, their system paths moved into the test's folder.
cp -R "$SRC/lib" "$SRC/guest" "$G/"
for f in "$G/lib/install-plugin.sh" "$G/lib/omacvm-plugins" "$G/lib/omacvm-plugins.service" "$G/guest/restart-shell.sh"; do
  [[ -f $f ]] || continue
  s=$(sed -e "s#/usr/local/bin/#$X/usr/local/bin/#g" -e "s#/etc/systemd/#$X/etc/systemd/#g" \
          -e "s#/usr/local/share/omacvm/#$G/#g" -e "s#/usr/local/lib/omacvm/#$X/usr/local/lib/omacvm/#g" "$f")
  printf '%s\n' "$s" > "$f"
done

# Stand-ins. The shell: answers while $S/up exists, runs while $S/proc does
# (its pid in it), its lock status in $S/status. Every call goes to $CALLS.
cat > "$B/getent" <<EOF
#!/bin/bash
echo "\$2:x:$(id -u):$(id -g)::$H:/bin/bash"
EOF
printf '#!/bin/bash\n[[ $1 == -u ]] && shift 2\nexec "$@"\n' > "$B/sudo"
cat > "$B/omarchy-shell" <<'EOF'
#!/bin/bash
[[ $1 == -q ]] && shift
[[ -e $S/up ]] || exit 1
case "$1 $2" in
  "shell ping") exit 0 ;;
  "shell rescanPlugins") echo "rescan $(cat "$HOME/.config/omarchy/plugins/omacvm.t/v" 2>/dev/null || echo none)" >> "$CALLS" ;;
  "lock status") cat "$S/status" ;;
  *) exit 1 ;;
esac
EOF
cat > "$B/omarchy" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "plugin validate") [[ -f $3/manifest.json && ! -e $3/INVALID ]] ;;
  "plugin enable")
    echo "enable $3" >> "$CALLS"
    c=$HOME/.config/omarchy/shell.json
    jq --arg id "$3" '.bar.layout.right += [{id: $id}]' "$c" > "$c.new" && mv "$c.new" "$c"
    # Omarchy's omarchy-plugin-enable wants the shell's answer to be just
    # "ok": without a UTF-8 locale qs prints Qt's warning before it, and the
    # command fails, though the shell enabled the plugin.
    case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in
      *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
      *) echo "omarchy-plugin-enable:   WARN: Detected locale \"C\" with character encoding \"ANSI_X3.4-1968\", which is not UTF-8. ok" >&2
         exit 1 ;;
    esac ;;
  "plugin disable") [[ -e $S/up ]] || exit 1; echo "disable $3" >> "$CALLS"; echo "Disabled $3" ;;
  *) exit 1 ;;
esac
EOF
cat > "$B/pgrep" <<'EOF'
#!/bin/bash
[[ -f $S/proc ]] || exit 1
cat "$S/proc"
EOF
cat > "$B/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
case " $* " in
  *" is-active "*) [[ -e $S/active ]] ;;
  *" stop "*) rm -f "$S/active" ;;
esac
EOF
cat > "$B/systemd-run" <<'EOF'
#!/bin/bash
echo "systemd-run" >> "$CALLS"; touch "$S/active"
EOF
cat > "$B/omarchy-restart-shell" <<'EOF'
#!/bin/bash
echo "omarchy-restart-shell" >> "$CALLS"
echo $(( $(cat "$S/proc") + 1 )) > "$S/proc"
EOF
printf '#!/bin/bash\nexit 0\n' > "$B/sleep"
chmod 755 "$B"/*
export PATH="$B:$PATH" CALLS=$T/calls S

# The plugin: omacvm.t in versions v1, v2, v3, and v2 broken.
plugin() {   # VERSION
  local d=$T/p/$1
  mkdir -p "$d"
  printf '{"schemaVersion":1,"id":"omacvm.t","name":"T","version":"1","kinds":["bar-widget"],"entryPoints":{"barWidget":"Widget.qml"}}\n' > "$d/manifest.json"
  echo "Item {}" > "$d/Widget.qml"; echo "$1" > "$d/v"
  cat > "$d/placement.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
c=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json
jq -e '[.bar.layout[]?[]?.id] | index("omacvm.t") != null' "$c" >/dev/null && exit 0
omarchy-shell -q shell rescanPlugins
omarchy plugin enable omacvm.t
EOF
  chmod 755 "$d/placement.sh"
}
plugin v1; plugin v2; plugin v3; plugin bad; touch "$T/p/bad/INVALID"
P=$H/.config/omarchy/plugins/omacvm.t
ST=$H/.local/state/omacvm
# status LOCKED: Omarchy's lock status as its shell answers it.
status() { printf '{"locked":%s,"requested":%s,"pending":false,"sessionLocked":%s,"secure":%s,"lastEvent":"x"}\n' "$1" "$1" "$1" "$1" > "$S/status"; }
open() { touch "$S/up"; echo 100 > "$S/proc"; status false; }
locked() { touch "$S/up"; echo 100 > "$S/proc"; status true; }
busy() { rm -f "$S/up"; echo 100 > "$S/proc"; }
down() { rm -f "$S/up" "$S/proc"; }
fresh() {   # PLACED: a home with v1 in place (on the bar when PLACED is yes) or none
  rm -rf "$H" "$S" "$CALLS"; mkdir -p "$H/.config/omarchy/plugins" "$S"; : > "$CALLS"
  if [[ ${1:-} == yes ]]; then
    cp -R "$T/p/v1" "$P"
    printf '{"bar":{"layout":{"right":[{"id":"omacvm.t"}]}}}\n' > "$H/.config/omarchy/shell.json"
  else
    printf '{"bar":{"layout":{"right":[]}}}\n' > "$H/.config/omarchy/shell.json"
  fi
  open
}
install_plugin() { bash "$G/lib/install-plugin.sh" "$(id -un)" "$T/p/$1" 2>&1; }
plugins() { HOME=$H bash "$X/usr/local/bin/omacvm-plugins" 2>&1; }
restart_shell() { HOME=$H bash "$G/guest/restart-shell.sh" "$@" 2>&1; }
calls() { grep -E '^(rescan|enable|disable|systemd-run|omarchy-restart-shell|systemctl.* (enable|stop) )' "$CALLS" | paste -sd'|' -; }
ino() { ls -di "$1" 2>/dev/null | awk '{print $1}'; }
ver() { cat "$1/v" 2>/dev/null || echo none; }
has() { [[ -e $1 ]] && echo yes || echo no; }
queue() { paste -sd' ' - 2>/dev/null < "$ST/pending-plugins"; }

# 1. The session open, a new plugin: in place, enabled at once.
fresh; install_plugin v1 >/dev/null; rc=$?
expect "open, new: in place, rescanned and enabled, no restart" "0 v1 rescan v1|rescan v1|enable omacvm.t no" "$rc $(ver "$P") $(calls) $(has "$ST/restart-shell")"
expect "  nothing left queued" "" "$(queue)"

# 2. Open, the same plugin on the bar: nothing written, nothing for the shell.
fresh yes; i=$(ino "$P"); install_plugin v1 >/dev/null
expect "open, unchanged: the folder untouched" "$i" "$(ino "$P")"
expect "  no rescan, no enable, no queue, no restart" "|||no" "$(calls)|$(queue)||$(has "$ST/restart-shell")"

# 3. Open, changed: in place, the shell restarts at the end of the apply.
fresh yes; install_plugin v2 >/dev/null
expect "open, changed: in place, restart noted" "v2 yes rescan v2" "$(ver "$P") $(has "$ST/restart-shell") $(calls)"

# 4. Locked, changed: nothing under the plugins folder, the copy staged.
fresh yes; locked; i=$(ino "$P"); out=$(install_plugin v2); rc=$?
expect "locked, changed: the folder untouched" "0 $i v1" "$rc $(ino "$P") $(ver "$P")"
expect "  staged, queued, no restart noted yet" "v2 omacvm.t no" "$(ver "$ST/plugins-staged/omacvm.t") $(queue) $(has "$ST/restart-shell")"
expect "  no rescan or enable under the lock; the login unit on" "systemctl --user -M $(id -un)@ enable omacvm-plugins.service" "$(calls)"
expect "  says so" "plugin omacvm.t: in place right after the next unlock (the session is locked)" "$out"

# 5. Locked, a new plugin.
fresh; locked; install_plugin v1 >/dev/null
expect "locked, new: staged, not in the plugins folder" "no v1 omacvm.t" "$(has "$P") $(ver "$ST/plugins-staged/omacvm.t") $(queue)"
expect "  no rescan or enable" "" "$(calls | tr '|' '\n' | grep -v '^systemctl')"

# 6. Locked, unchanged and on the bar (and a copy an earlier apply staged):
#    nothing to do at all, the staged copy goes (this one is newer).
fresh yes; locked; mkdir -p "$ST/plugins-staged"; cp -R "$T/p/v2" "$ST/plugins-staged/omacvm.t"
i=$(ino "$P"); out=$(install_plugin v1)
expect "locked, unchanged: folder untouched, staged copy gone" "$i no" "$(ino "$P") $(has "$ST/plugins-staged/omacvm.t")"
expect "  no queue line, no call, nothing said" "|||" "$(queue)|$(calls)|$out|"

# 7. Locked twice: the newest copy waits.
fresh yes; locked; install_plugin v2 >/dev/null; install_plugin v3 >/dev/null
expect "locked twice: v3 staged, v1 in place" "v3 v1 omacvm.t" "$(ver "$ST/plugins-staged/omacvm.t") $(ver "$P") $(queue)"
expect "  never half-written beside it" "" "$(ls -A "$ST/plugins-staged" | grep -v '^omacvm.t$')"

# 8. Busy (the shell runs, does not answer: starting, reloading): as locked.
fresh yes; busy; i=$(ino "$P"); install_plugin v2 >/dev/null
expect "busy: staged, folder untouched" "v2 $i" "$(ver "$ST/plugins-staged/omacvm.t") $(ino "$P")"

# 9. No shell (nobody logged in): in place now, no restart noted, enabled at login.
fresh yes; down; out=$(install_plugin v2)
expect "no shell: in place, no restart noted, queued" "v2 no omacvm.t" "$(ver "$P") $(has "$ST/restart-shell") $(queue)"
expect "  enabled at the next login" "plugin omacvm.t installed (enabled at the next login)" "$out"

# 10. A broken plugin: refused before anything is written.
fresh yes; i=$(ino "$P"); install_plugin bad >/dev/null; rc=$?
expect "broken plugin: refused, the working one untouched" "1 $i v1 no" "$(( rc != 0 )) $(ino "$P") $(ver "$P") $(has "$ST/plugins-staged/omacvm.t")"

# 11. omacvm-plugins while locked: nothing moves, everything stays queued.
fresh yes; locked; install_plugin v2 >/dev/null; : > "$CALLS"; plugins >/dev/null; rc=$?
expect "omacvm-plugins locked: rc 0, nothing moved, still queued" "0 v1 v2 omacvm.t" "$rc $(ver "$P") $(ver "$ST/plugins-staged/omacvm.t") $(queue)"
expect "  no rescan or enable" "" "$(calls)"

# 12. ... open: the staged copy in place before the rescan, restart noted.
open; plugins >/dev/null
expect "omacvm-plugins open: v2 in place, staged gone, restart noted" "v2 no yes" "$(ver "$P") $(has "$ST/plugins-staged/omacvm.t") $(has "$ST/restart-shell")"
expect "  the rescan saw v2" "rescan v2" "$(calls)"
expect "  nothing hidden left in the plugins folder" "omacvm.t" "$(ls -A "$H/.config/omarchy/plugins" | paste -sd' ' -)"

# 13. ... no shell: in place, no restart noted (the next shell loads it).
fresh yes; locked; install_plugin v2 >/dev/null; down; plugins >/dev/null
expect "omacvm-plugins without a shell: in place, no restart noted" "v2 no" "$(ver "$P") $(has "$ST/restart-shell")"

# 14. A copy still being written (.omacvm.t.new) is never taken.
fresh yes; mkdir -p "$ST/plugins-staged/.omacvm.t.new"; echo "omacvm.t" > "$ST/pending-plugins"; plugins >/dev/null
expect "a half-written staged copy stays where it is" "v1 yes" "$(ver "$P") $(has "$ST/plugins-staged/.omacvm.t.new")"

# 15. The login unit: a stale restart note goes; staged copies go in place,
#     and the shell restarts once if it had loaded the old one.
U_FILE=$G/lib/omacvm-plugins.service
expect "login unit: the stale note removed first" 1 "$(grep -c '^ExecStartPre=-/bin/rm -f %h/.local/state/omacvm/restart-shell$' "$U_FILE")"
expect "login unit: restart-shell.sh after omacvm-plugins" 1 \
  "$(grep '^ExecStart' "$U_FILE" | tail -1 | grep -c 'guest/restart-shell.sh$')"
login() {   # the unit's lines, in order
  local l
  while IFS= read -r l; do
    l=${l#*=}; l=${l#-}; l=${l//%h/$H}
    HOME=$H bash -c "$l" >/dev/null 2>&1
  done < <(grep -E '^ExecStart(Pre)?=' "$U_FILE")
}
fresh yes; locked; install_plugin v2 >/dev/null; echo old > "$ST/restart-shell"; open; : > "$CALLS"; login
expect "login, the shell up: v2 in place, one restart, the note gone" "v2 1 no" \
  "$(ver "$P") $(grep -c '^omarchy-restart-shell' "$CALLS") $(has "$ST/restart-shell")"
fresh yes; locked; install_plugin v2 >/dev/null; echo old > "$ST/restart-shell"; down; : > "$CALLS"; login
expect "login, no shell: v2 in place, no restart" "v2 0" "$(ver "$P") $(grep -c '^omarchy-restart-shell' "$CALLS")"
fresh yes; mkdir -p "$ST"; echo old > "$ST/restart-shell"; : > "$CALLS"; login
expect "login, only a note from before: no restart" "0 no" "$(grep -c '^omarchy-restart-shell' "$CALLS") $(has "$ST/restart-shell")"

# 16. Two applies while locked: one job waits, then the newest copy and one restart.
apply_end() { restart_shell >/dev/null; }
fresh yes; locked
install_plugin v2 >/dev/null; apply_end                                # apply 1
restart_shell --retire >/dev/null; install_plugin v3 >/dev/null; apply_end   # apply 2
expect "two locked applies: the first job stopped, one waits" "systemd-run|systemctl --user stop omacvm-restart-shell.service|systemd-run yes" \
  "$(grep -E '^(systemd-run|systemctl --user stop)' "$CALLS" | paste -sd'|' -) $(has "$S/active")"
expect "  under the lock: v1 in place, no restart, no rescan" "v1 0 0" "$(ver "$P") $(grep -c '^omarchy-restart-shell' "$CALLS") $(grep -c '^rescan' "$CALLS")"
open; : > "$CALLS"; restart_shell --after-unlock >/dev/null
expect "  after the unlock: v3 in place, one restart, nothing owed" "v3 1 no no" \
  "$(ver "$P") $(grep -c '^omarchy-restart-shell' "$CALLS") $(has "$ST/plugins-staged/omacvm.t") $(has "$ST/restart-shell")"

# 17. Locked, nothing changed: the end of the apply starts no job.
fresh yes; locked; install_plugin v1 >/dev/null; : > "$CALLS"; apply_end
expect "locked, nothing changed: no job, no restart" "" "$(calls)"

# 18. The control centre off (control/guest/install.sh's bar_item_off): out of
#     the bar, the folder gone; under the lock the folder stays (out of the bar
#     it does nothing; the next apply removes it). A copy staged under the lock
#     and a queued enable never come.
off_fn=$(awk '/^bar_item_off\(\) \{/ {on = 1} on {print} on && /^}$/ {exit}' "$SRC/control/guest/install.sh")
if [[ -n $off_fn ]]; then
  mkdir -p "$G/control/guest"
  cc_off() {
    ( cd "$G/control/guest" || exit 9
      U=$(id -un)
      as_user() { env HOME="$H" "$@"; }
      source "$G/guest/home-files.sh"
      eval "$off_fn"
      bar_item_off )
  }
  cc_fresh() {
    fresh; cp -R "$T/p/v1" "$H/.config/omarchy/plugins/omacvm.control"
    mkdir -p "$ST/plugins-staged"; cp -R "$T/p/v2" "$ST/plugins-staged/omacvm.control"
    printf '%s\n' omacvm.control omacvm.t > "$ST/pending-plugins"
    printf '{"bar":{"layout":{"right":[{"id":"omacvm.control"},{"id":"omacvm.t"}]}}}\n' > "$H/.config/omarchy/shell.json"
  }
  C=$H/.config/omarchy/plugins/omacvm.control
  cc_fresh; locked; i=$(ino "$C"); cc_off
  expect "control centre off, locked: out of the bar, the folder untouched" "disable omacvm.control $i" "$(calls) $(ino "$C")"
  expect "  the staged copy and the queued enable gone" "no omacvm.t" "$(has "$ST/plugins-staged/omacvm.control") $(queue)"
  cc_fresh; cc_off
  expect "control centre off, open: out of the bar, the folder gone" "disable omacvm.control no omacvm.t" "$(calls) $(has "$C") $(queue)"
  cc_fresh; down; cc_off
  expect "control centre off, no shell: out of shell.json by hand, the folder gone" "omacvm.t no" \
    "$(jq -r '[.bar.layout.right[].id] | join(" ")' "$H/.config/omarchy/shell.json") $(has "$C")"
  I=$SRC/guest/install.sh
  expect "install.sh runs the control centre's off while its folder or a staged copy is there" 1 \
    "$(grep -c 'd $H/.config/omarchy/plugins/omacvm.control || -d $H/.local/state/omacvm/plugins-staged/omacvm.control' "$I")"
else
  expect "control/guest/install.sh has bar_item_off" yes no
fi

# 19. A plugin without placement.sh (a panel: the Wi-Fi QR card), the session
#     open, Update VM's root shell without a locale. omacvm-plugins gives
#     Omarchy's commands LC_ALL=C.UTF-8: enabled once and nothing left queued
#     (it stayed queued and was enabled again, with a rescan of the open shell,
#     at every later install-plugin.sh call and apply).
mkdir -p "$T/p/panel"
printf '{"schemaVersion":1,"id":"omacvm.q","name":"Q","version":"1","kinds":["panel"],"entryPoints":{"panel":"Panel.qml"}}\n' > "$T/p/panel/manifest.json"
echo "Item {}" > "$T/p/panel/Panel.qml"
no_locale() { (
  unset LC_ALL LANG
  for v in $(compgen -e | grep '^LC_'); do unset "$v"; done
  "$@" ) }
fresh yes; out=$(no_locale install_plugin panel)
expect "a panel, no locale: enabled once, nothing left queued" "enable omacvm.q|" "$(grep '^enable' "$CALLS" | paste -sd'|' -)|$(queue)"
expect "  Omarchy's enable did not fail" 0 "$(grep -c '^omarchy-plugin-enable:' <<< "$out")"
: > "$CALLS"; no_locale install_plugin panel >/dev/null
expect "  the next apply: no rescan, no enable" "" "$(calls)"

# 20. Every rescanPlugins caller asks for the lock first, or runs only from
#     omacvm-plugins (placement.sh). A new caller fails here until it does.
if [[ -z ${1:-} ]]; then
  allowed="lib/omacvm-plugins app/guest/omacvm-displays omanotch/guest/monitor/display-panel.py omanotch/guest/uninstall.sh"
  while IFS= read -r f; do
    f=${f#"$SRC"/}
    case $f in
      tests/*|*/tests/*) continue ;;
      */placement.sh) continue ;;   # run by omacvm-plugins after its lock check
    esac
    if [[ " $allowed " != *" $f "* ]]; then expect "rescanPlugins in $f: on the list" yes no; continue; fi
    case $f in
      omanotch/guest/monitor/display-panel.py)   # Omanotch's own rule (as copies.py)
        expect "rescanPlugins in $f: asks for the lock first" yes "$(grep -q 'def session_locked' "$SRC/$f" && echo yes || echo no)" ;;
      omanotch/guest/uninstall.sh)   # run in the session only while it is open (guest/off.sh, restart-shell.sh)
        expect "rescanPlugins in $f: off.sh runs it only unlocked" yes "$(grep -q 'off_locked' "$SRC/guest/off.sh" && echo yes || echo no)" ;;
      *) expect "rescanPlugins in $f: asks for the lock first" yes "$(grep -q 'session-lock\.sh' "$SRC/$f" && echo yes || echo no)" ;;
    esac
  done < <(grep -rlI --exclude-dir=__pycache__ rescanPlugins "$SRC" | LC_ALL=C sort)
fi

exit $fail
