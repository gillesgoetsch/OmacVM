#!/bin/bash
# notchcast's start at the first login after Update VM, against a small model
# of systemd's start limit (no systemd needed).
#
# 3.0.6: Update VM removes notchcast so the next login builds it again, but
# the old unit stays enabled. At the login it failed on the missing program
# every RestartSec, and the installer's enable --now + restart came on top:
# "start of the service was attempted too often", no bar in the notch strip.
#
# The model: a start counts against StartLimitBurst within
# StartLimitIntervalSec (a new window starts after the interval, as in
# systemd's ratelimit_below); reset-failed clears the count; a failed
# condition leaves the unit inactive; a missing program fails and, with
# Restart=always/on-failure, starts again after RestartSec. Every attempt
# takes 10 ms. Time is in milliseconds; sleep only moves the clock.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../../.." && pwd)            # src/
G=$src/omanotch/guest
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0

mkdir -p "$T/bin"
# --- fake systemctl ----------------------------------------------------------
cat > "$T/bin/systemctl" <<'SIM'
#!/bin/bash
set -u
S=$SIM
U=$HOME/.config/systemd/user
now() { cat "$S/clock"; }
get() { cat "$S/$1" 2>/dev/null || echo "$2"; }
put() { echo "$2" > "$S/$1"; }
# The unit's settings: the unit file, then its drop-ins (last one wins).
conf() {
  local v="" f x
  for f in "$U/notchcast.service" "$U"/notchcast.service.d/*.conf; do
    [[ -f $f ]] || continue
    x=$(sed -n "s/^$1=//p" "$f" | tail -1)
    [[ -n $x ]] && v=$x
  done
  printf '%s' "$v"
}
conditions() {
  local f
  for f in "$U/notchcast.service" "$U"/notchcast.service.d/*.conf; do
    [[ -f $f ]] && sed -n 's/^ConditionFileIsExecutable=//p' "$f"
  done | sed "s|%h|$HOME|g"
}
sec_ms() { awk -v s="$1" 'BEGIN { if (s ~ /ms$/) { sub(/ms$/, "", s); print int(s) } else print int(s * 1000) }'; }
start_unit() {
  local t; t=$(now)
  local burst interval begin n
  burst=$(conf StartLimitBurst); burst=${burst:-5}
  interval=$(conf StartLimitIntervalSec); interval=$(sec_ms "${interval:-10}")
  begin=$(get begin -1); n=$(get n 0)
  if (( begin < 0 || t - begin > interval )); then begin=$t; n=0; fi
  if (( n >= burst )); then
    put state failed; put result start-limit-hit; put begin "$begin"; put n "$n"
    echo "$t refused" >> "$S/log"
    echo "Job for notchcast.service failed because start of the service was attempted too often." >&2
    return 1
  fi
  n=$((n + 1)); put begin "$begin"; put n "$n"
  put clock $((t + 10))
  local c
  while read -r c; do
    [[ -z $c || -x $c ]] && continue
    put state inactive; echo "$t condition" >> "$S/log"; return 0
  done < <(conditions)
  if [[ -x $HOME/.local/bin/notchcast ]]; then
    put state active; echo "$t started" >> "$S/log"; return 0
  fi
  echo "$t exec-failed" >> "$S/log"
  local r; r=$(conf Restart)
  if [[ $r == always || $r == on-failure ]]; then
    put state autorestart; put restart_at $((t + 10 + $(sec_ms "$(conf RestartSec)")))
  else
    put state failed; put result exit-code
  fi
  return 1
}
cmd=() q=0
while (($#)); do
  case $1 in
    --user|--now) [[ $1 == --now ]] && now_flag=1; shift ;;
    -M) shift 2 ;;
    -q|--quiet) q=1; shift ;;
    *) cmd+=("$1"); shift ;;
  esac
done
case ${cmd[0]} in
  daemon-reload) ;;
  enable)
    mkdir -p "$U/graphical-session.target.wants"; touch "$U/graphical-session.target.wants/notchcast.service"
    if [[ ${now_flag:-0} == 1 && $(get state inactive) != active ]]; then start_unit; fi ;;
  is-enabled) [[ -e $U/graphical-session.target.wants/notchcast.service ]] ;;
  start) [[ $(get state inactive) == active ]] || start_unit ;;
  start-auto) start_unit ;;   # the manager's own start (login, Restart=)
  restart) [[ $(get state inactive) == active ]] && { put state inactive; echo "$(now) stopped" >> "$S/log"; }; start_unit ;;
  try-restart) [[ $(get state inactive) == active ]] && { put state inactive; start_unit; }; true ;;
  reset-failed) put n 0; put begin -1; [[ $(get state inactive) == failed ]] && put state inactive; true ;;
  is-active) [[ $(get state inactive) == active ]] ;;
  *) echo "systemctl model: ${cmd[*]}?" >&2; exit 2 ;;
esac
SIM
# sleep moves the clock, running the auto-restarts that fall due.
cat > "$T/bin/sleep" <<'SIM'
#!/bin/bash
"$(dirname "$0")/tick" $(( $(cat "$SIM/clock") + $(awk -v s="$1" 'BEGIN { print int(s * 1000) }') ))
SIM
cat > "$T/bin/tick" <<'SIM'
#!/bin/bash
# tick <ms>: run auto-restarts until then.
S=$SIM
while [[ $(cat "$S/state" 2>/dev/null) == autorestart ]] && (( $(cat "$S/restart_at") <= $1 )); do
  cat "$S/restart_at" > "$S/clock"
  "$(dirname "$0")/systemctl" --user start-auto 2>/dev/null
done
(( $(cat "$S/clock") < $1 )) && echo "$1" > "$S/clock"
true
SIM
printf '#!/bin/sh\nexit 0\n' > "$T/bin/hyprctl"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/pgrep"
chmod +x "$T/bin"/*

# --- pieces of the real scripts ----------------------------------------------
# omanotch/guest/install.sh from "installing the notchcast service" to the end.
sed -n '/^say "installing the notchcast service"/,$p' "$G/install.sh" > "$T/install-tail.sh"
# guest/install.sh: the drop-in it writes, and what follows it for Omanotch.
gi=$src/guest/install.sh
sed -n '/notchcast.service.d"$/,/omacvm-host.conf"$/p' "$gi" | sed '1d' > "$T/dropin.sh"
sed -n '/^  chown .*omacvm-host.conf"$/,/^  # Notifications right under the strip/p' "$gi" | sed '1d;$d' > "$T/repair.sh"
for f in install-tail dropin repair; do
  [[ -s $T/$f.sh ]] || { echo "FAIL: cannot find the $f part in the scripts"; exit 1; }
done
# The first-login unit's ExecStartPre= commands that call systemctl.
sed -n 's/^ExecStartPre=-\{0,1\}\(.*systemctl.*\)/\1/p' "$src/guest/omacvm-omanotch.service" > "$T/first-login-pre.sh"

# The unit as 3.0.5 and 3.0.6 installed it: the one on disk when the update
# runs (the new one is installed by the login's installer).
old_unit() {
  cat > "$HOME/.config/systemd/user/notchcast.service" <<'UNIT'
[Unit]
After=graphical-session.target
PartOf=graphical-session.target
[Service]
ExecStart=%h/.local/bin/notchcast
Restart=always
RestartSec=2
[Install]
WantedBy=graphical-session.target
UNIT
}

fresh() {  # fresh <name>
  export HOME=$T/$1 SIM=$T/$1/sim
  mkdir -p "$HOME/.config/systemd/user/notchcast.service.d" "$HOME/.config/systemd/user/graphical-session.target.wants" "$HOME/.local/bin" "$SIM"
  touch "$HOME/.config/systemd/user/graphical-session.target.wants/notchcast.service"
  echo 0 > "$SIM/clock"; echo inactive > "$SIM/state"
  export PATH=$T/bin:/usr/bin:/bin
}
run_dropin() {  # as guest/install.sh writes it (paths into this HOME)
  H=$HOME HOST=192.168.64.1 TYPE=app U=$USER bash -c "chown() { :; }; $(cat "$T/dropin.sh")"
}
run_repair() {
  H=$HOME U=$USER bash -c "user_ctl() { systemctl --user \"\$@\"; }; $(cat "$T/repair.sh")"
}
install_tail() {
  here=$G units=$HOME/.config/systemd/user bash -c "set -euo pipefail
say() { :; }; die() { echo \"install: \$*\" >&2; exit 1; }
$(cat "$T/install-tail.sh")" >/dev/null 2>"$SIM/install.err"
}
check() {  # check <label> <ok>
  if [[ $2 == 1 ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

# 1. The first login after Update VM, for build times from 0 to 20 s and
#    0 or 2.5 s for the rest of the installer before the service part.
bad="" runs=0
for build in $(seq 0 500 20000); do
  for rest in 0 2500; do
    runs=$((runs + 1))
    fresh "login-$build-$rest"
    old_unit
    run_dropin
    systemctl --user start-auto 2>/dev/null || true       # graphical-session.target
    sleep 5                                               # omacvm-omanotch: ExecStartPre sleep
    bash "$T/first-login-pre.sh" 2>/dev/null || true
    tick $(( $(cat "$SIM/clock") + build ))               # building notchcast
    printf '#!/bin/sh\n' > "$HOME/.local/bin/notchcast"; chmod +x "$HOME/.local/bin/notchcast"
    tick $(( $(cat "$SIM/clock") + rest ))                # bar, background, Hyprland config
    if ! install_tail || [[ $(cat "$SIM/state") != active ]]; then
      bad+=" ${build}ms/${rest}ms"
    fi
  done
done
if [[ -z $bad ]]; then check "first login after Update VM: notchcast runs ($runs timings)" 1
else check "first login after Update VM: notchcast runs; refused at build/rest:${bad:0:100}..." 0; fi

# 2. A 3.0.6 VM whose notchcast already hit the limit: Update VM's apply
#    starts it again (no reboot).
fresh repair
old_unit
printf '#!/bin/sh\n' > "$HOME/.local/bin/notchcast"; chmod +x "$HOME/.local/bin/notchcast"
echo 100000 > "$SIM/clock"; echo failed > "$SIM/state"; echo 5 > "$SIM/n"; echo 99000 > "$SIM/begin"
run_dropin
run_repair
check "Update VM restarts a notchcast stuck in its start limit" "$([[ $(cat "$SIM/state") == active ]] && echo 1 || echo 0)"

# 3. Omanotch's unit not enabled: the apply starts nothing.
fresh not-enabled
old_unit
rm -f "$HOME/.config/systemd/user/graphical-session.target.wants/notchcast.service"
printf '#!/bin/sh\n' > "$HOME/.local/bin/notchcast"; chmod +x "$HOME/.local/bin/notchcast"
run_repair
check "a notchcast that is not enabled is not started" "$([[ $(cat "$SIM/state") != active ]] && echo 1 || echo 0)"

# 4. The new unit: a missing program at login is skipped, not a restart loop.
fresh new-unit
cp "$G/systemd/notchcast.service" "$HOME/.config/systemd/user/notchcast.service"
systemctl --user start-auto 2>/dev/null || true
tick 30000
check "new unit with notchcast missing: one skipped start, no loop" "$([[ $(wc -l < "$SIM/log") -eq 1 ]] && grep -q condition "$SIM/log" && echo 1 || echo 0)"

((fails == 0)) && echo "start-limit: all ok" || { echo "start-limit: $fails failed"; exit 1; }
