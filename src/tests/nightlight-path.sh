#!/bin/bash
# The Mac's Night Shift from Omarchy's menu and keys (#748), without a VM.
# Omarchy's envs.lua puts its own bin first on the session's PATH, so the
# Bridge's omarchy-toggle-nightlight in /usr/local/bin never ran there.
#  1. one folder, the same in every file that names it (omacvm_vm.lua puts it
#     first, the Bridge's install links the toggle there, off.sh removes it,
#     check.sh reads it); the install links only the toggle;
#  2. the PATH omacvm_vm.lua leaves after Omarchy's envs.lua finds the
#     Bridge's toggle, not Omarchy's (Lua 5.5, a stand-in for hl.env);
#  3. omarchy-toggle-nightlight --status: a Bridge that does not answer reads
#     as off within 2 s and leaves no process behind (needs timeout(1));
#  4. omacvm check's "Night Shift toggle" line (check.sh's nightlight_line);
#  5. guest/install.sh restarts the shell once: the Bridge on, omacvm_vm.lua
#     written by this run, and the running shell does not find the toggle there.
#   LUA=lua5.5 src/tests/nightlight-path.sh      (LUA: Lua 5.5, default lua)
#   OMACVM_SRC=DIR src/tests/nightlight-path.sh  against another checkout's src/
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$(cd "${OMACVM_SRC:-$R}/src" && pwd)
LUA=${LUA:-lua}
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-nightlight.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}

# ---------- 1. one folder ----------
LUAF=$SRC/guest/omacvm_vm.lua BI=$SRC/bridge/guest/install.sh OFF=$SRC/guest/off.sh CHK=$SRC/guest/check.sh
dir_lua=$(sed -n 's/^local OMARCHY_OVERRIDES = "\(.*\)"$/\1/p' "$LUAF")
dirs=""
for f in "$BI" "$OFF" "$CHK"; do
  n=$(grep -c '^ *OMARCHY_OVERRIDES=' "$f")
  dirs+="$n:$(sed -n 's/^ *OMARCHY_OVERRIDES=\(.*\)$/\1/p' "$f" | head -1) "
done
expect "the folder: one constant in omacvm_vm.lua" yes "$([[ $dir_lua == /* ]] && echo yes)"
expect "... the same one in bridge/guest/install.sh, off.sh and check.sh" "1:$dir_lua 1:$dir_lua 1:$dir_lua " "$dirs"
expect "the Bridge's install links only the night light toggle there" \
  'ln -sfn /usr/local/bin/omarchy-toggle-nightlight "$OMARCHY_OVERRIDES/omarchy-toggle-nightlight"' \
  "$(grep -E '^[^#]*(ln|cp|install)\b.*\$OMARCHY_OVERRIDES/' "$BI" | sed 's/^ *//')"
D=${dir_lua:-/usr/local/lib/omacvm/omarchy-overrides}

# ---------- 2. the PATH after Omarchy's envs.lua and omacvm_vm.lua ----------
# Omarchy's lines (default/hypr/envs.lua, omarchy-mac 4.0 and Omarchy 4.5), then OmacVM's file.
cat > "$T/path.lua" <<'EOF'
local env = { PATH = arg[2] }
os.getenv = function(k) return env[k] end
hl = setmetatable({ env = function(k, v) env[k] = v end }, { __index = function() return function() end end })
local function omarchy_envs()
  local bin_dir = "/usr/share/omarchy/bin"
  local kept = {}
  for entry in (os.getenv("PATH") or "/usr/local/bin:/usr/bin"):gmatch("[^:]+") do
    if entry ~= bin_dir then table.insert(kept, entry) end
  end
  table.insert(kept, 1, bin_dir)
  hl.env("PATH", table.concat(kept, ":"))
end
omarchy_envs(); dofile(arg[1])
omarchy_envs(); dofile(arg[1])   -- a config reload
print(env.PATH)
EOF
if ! command -v "$LUA" >/dev/null; then
  echo "FAIL no Lua 5.5 ($LUA): LUA=path/to/lua $0"; fail=1
else
  P=$(XDG_CONFIG_HOME=$T/cfg HOME=$T "$LUA" "$T/path.lua" "$LUAF" "/usr/local/sbin:/usr/local/bin:/usr/bin" 2>&1)
  # The folders under a scratch root: Omarchy's toggle, OmacVM's, the link.
  mkdir -p "$T/root/usr/share/omarchy/bin" "$T/root/usr/local/bin" "$T/root$D"
  printf '#!/bin/sh\necho omarchy\n' > "$T/root/usr/share/omarchy/bin/omarchy-toggle-nightlight"
  printf '#!/bin/sh\necho omacvm\n' > "$T/root/usr/local/bin/omarchy-toggle-nightlight"
  chmod +x "$T/root/usr/share/omarchy/bin/omarchy-toggle-nightlight" "$T/root/usr/local/bin/omarchy-toggle-nightlight"
  ln -s "$T/root/usr/local/bin/omarchy-toggle-nightlight" "$T/root$D/omarchy-toggle-nightlight"
  rp=""; IFS=: read -r -a parts <<<"$P"; for e in "${parts[@]}"; do rp+="${rp:+:}$T/root$e"; done
  expect "the session's PATH after Omarchy's envs.lua and omacvm_vm.lua (also after a reload)" \
    "$D:/usr/share/omarchy/bin:/usr/local/sbin:/usr/local/bin:/usr/bin" "$P"
  expect "... finds the Bridge's toggle, through the folder" "omacvm $T/root$D/omarchy-toggle-nightlight" \
    "$(PATH=$rp; w=$(command -v omarchy-toggle-nightlight); echo "$("$w") $w")"
  rm -f "$T/root$D/omarchy-toggle-nightlight"
  expect "... the Bridge off (no link): Omarchy's own again, nothing reloaded" "omarchy" \
    "$(PATH=$rp; "$(command -v omarchy-toggle-nightlight)")"
fi

# ---------- 3. --status with a Bridge that does not answer ----------
mkdir -p "$T/st"
cp "$SRC/bridge/guest/omarchy-toggle-nightlight" "$T/st/"
# omacvm-bridge: its curl child (a sleep) waits; BRIDGE=json: answers at once.
cat > "$T/st/omacvm-bridge" <<'EOF'
#!/bin/bash
case ${BRIDGE:-} in
  json) echo '{"night_shift":{"available":true,"enabled":true,"strength":0.8}}'; exit 0 ;;
  junk) echo 'curl: (7) Failed to connect'; exit 7 ;;
esac
sleep 10 & echo $! > "$PIDF"; wait
EOF
chmod +x "$T/st/omacvm-bridge" "$T/st/omarchy-toggle-nightlight"
REALTIMEOUT=no
if command -v timeout >/dev/null && timeout --version 2>/dev/null | grep -q coreutils; then REALTIMEOUT=yes
else printf '#!/bin/sh
shift
exec "$@"
' > "$T/st/timeout"; chmod +x "$T/st/timeout"; fi   # macOS: none
st() { PATH="$T/st:$PATH" PIDF=$T/st/pid "$T/st/omarchy-toggle-nightlight" --status 2>&1; }
expect "--status, the Bridge answers: the Mac's state" '{"enabled":true,"temperature":null}' "$(BRIDGE=json st)"
expect "--status, the Bridge refuses: off" '{"enabled":false,"temperature":null}' "$(BRIDGE=junk st)"
if [[ $REALTIMEOUT == yes ]]; then
  t0=$(date +%s); out=$(st); t1=$(date +%s)
  expect "--status, the Bridge does not answer: off" '{"enabled":false,"temperature":null}' "$out"
  expect "... within 3 s" yes "$( (( t1 - t0 <= 3 )) && echo yes || echo "no: $((t1 - t0)) s")"
  sleep 0.2
  expect "... and its curl stopped with it" gone "$(kill -0 "$(cat "$T/st/pid" 2>/dev/null)" 2>/dev/null && echo running || echo gone)"
else
  echo "skip --status time limit: no coreutils timeout here (the VM and CI's guest job have it)"
fi

# ---------- the Omarchy shell's process (check.sh and guest/install.sh) ----------
pat_chk=$(grep -o "pgrep -u \"\$U\" -f '[^']*'" "$CHK" | head -1 | sed "s/^pgrep -u \"\$U\" -f '//; s/'\$//")
pat_ins=$(grep -o "pgrep -u \"\$U\" -f '[^']*'" "$SRC/guest/install.sh" | grep -F -- '/shell' | head -1 | sed "s/^pgrep -u \"\$U\" -f '//; s/'\$//")
expect "check.sh and guest/install.sh find the shell alike" yes "$([[ -n $pat_chk && $pat_chk == "$pat_ins" ]] && echo yes)"
m() { grep -qE -- "$pat_chk" <<<"$1" && echo yes || echo no; }
expect "the shell: quickshell -n -p /usr/share/omarchy/shell" yes "$(m 'quickshell -n -p /usr/share/omarchy/shell')"
expect "... a dev-linked Omarchy" yes "$(m '/usr/bin/quickshell -n -p /home/u/.local/share/omarchy/shell')"
expect "... not systemd-cat's line before its exec" no "$(m 'systemd-cat -t omarchy-shell -- quickshell -n -p /usr/share/omarchy/shell')"
expect "... not another quickshell config" no "$(m 'quickshell -p /home/u/.config/quickshell/bar')"
expect "... not the launcher" no "$(m 'bash /usr/share/omarchy/bin/omarchy-launch-shell')"

# A running shell's /proc/PID/environ under the scratch root (NUL-separated).
mkdir -p "$T/proc/4242" "$T/ovr" "$T/omarchy/bin" "$T/stub"
printf '#!/bin/sh\necho omacvm\n' > "$T/ovr/omarchy-toggle-nightlight"
printf '#!/bin/sh\necho omarchy\n' > "$T/omarchy/bin/omarchy-toggle-nightlight"
chmod +x "$T/ovr/omarchy-toggle-nightlight" "$T/omarchy/bin/omarchy-toggle-nightlight"
environ() { printf 'HOME=/home/u\0PATH=%s\0XDG_RUNTIME_DIR=/run/user/1000\0' "$1" > "$T/proc/4242/environ"; }
NEW=$T/ovr:$T/omarchy/bin:/usr/bin OLD=$T/omarchy/bin:/usr/bin
printf '#!/bin/sh\n[ -n "$QS_PID" ] && echo "$QS_PID"\nexit 0\n' > "$T/stub/pgrep"; chmod +x "$T/stub/pgrep"

# ---------- 4. omacvm check's "Night Shift toggle" ----------
{ grep -m1 '^OMARCHY_OVERRIDES=' "$CHK"; awk '/^nightlight_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$CHK"; } |
  sed "s#^OMARCHY_OVERRIDES=.*#OMARCHY_OVERRIDES=$T/ovr#" > "$T/nl.sh"
if ! grep -q '^nightlight_line' "$T/nl.sh"; then
  echo "FAIL no nightlight_line in check.sh"; fail=1
else
  B40='[{"modmask":64,"key":"B","description":"Bluetooth","arg":"12"},{"modmask":68,"key":"N","description":"Toggle nightlight","arg":"153"}]'
  B45='[{"modmask":68,"key":"N","description":"Network","arg":"88"}]'
  nl() {   # QUEUED SHELL_PATH BINDS -> status|human|detail
    ( ok() { echo "ok||$2"; }; warn() { echo "warn|${3:+1}|$2"; }; bad() { echo "FAIL||$2"; }; skip() { echo "skip||$2"; }
      queued_when() { if [[ $Q == 1 ]]; then echo "right after the next unlock"; else echo "log out and in"; fi; }
      Q=$1; source "$T/nl.sh"; nightlight_line "$2" "$3" )
  }
  expect "check: the shell finds OmacVM's toggle, Omarchy 4.0's key" \
    "ok||the menu's Nightlight and Super+Ctrl+N drive the Mac" "$(nl 0 "$NEW" "$B40")"
  expect "check: ... Omarchy 4.5 (Super+Ctrl+N is its Network panel): menu and bar, no key named" \
    "ok||the menu's Nightlight and the bar's Night Shift drive the Mac (no key for it)" "$(nl 0 "$NEW" "$B45")"
  expect "check: ... no binds read: no key named" \
    "ok||the menu's Nightlight and the bar's Night Shift drive the Mac (no key for it)" "$(nl 0 "$NEW" "")"
  expect "check: the shell finds Omarchy's (started before the fix): warn, log out and in (a person)" \
    "warn|1|the shell runs Omarchy's own night light (hyprsunset), not the Mac's Night Shift: log out and in" "$(nl 0 "$OLD" "$B40")"
  expect "check: ... a restart waits for the unlock: warn, says when" \
    "warn||the shell runs Omarchy's own night light (hyprsunset) until it restarts, right after the next unlock" "$(nl 1 "$OLD" "$B45")"
  expect "check: no shell running: skip" "skip||no Omarchy shell running" "$(nl 0 - "$B40")"
  mv "$T/ovr/omarchy-toggle-nightlight" "$T/ovr/x"
  expect "check: OmacVM's toggle not in its folder: FAIL" \
    "FAIL||OmacVM's night light toggle is not installed: omacvm apply" "$(nl 0 "$NEW" "$B40")"
  mv "$T/ovr/x" "$T/ovr/omarchy-toggle-nightlight"
  # The line's caller: the shell's PATH from its environ.
  call=$(grep -A2 '^  qs=$(pgrep' "$CHK")
  expect "check: the shell's PATH read from its /proc environ" yes \
    "$([[ $call == *'/proc/$qs/environ'* && $call == *'nightlight_line "$qpath"'* ]] && echo yes)"
fi

# ---------- 5. guest/install.sh: the shell restarts once ----------
INS=$SRC/guest/install.sh
{ awk '/^shell_runs_overrides\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$INS"
  awk '/^if \[\[ \$\{F\[bridge\]\} == on && \( \$hypr_vm == added/ {on=1} on {print} on && /^fi$/ {exit}' "$INS"; } |
  sed "s#/proc/#$T/proc/#" > "$T/gate.sh"
if ! grep -q '^shell_runs_overrides' "$T/gate.sh" || ! grep -q 'restart_shell_later' "$T/gate.sh"; then
  echo "FAIL no restart gate in guest/install.sh"; fail=1
else
  expect "install.sh: hypr_vm holds hypr-vm.sh's answer, empty when the step does not run" yes \
    "$(awk '/^hypr_vm=""$/ {a=1} a && /^if system; then$/ {b=1} b && /hypr_vm=\$r/ {print "yes"; exit}' "$INS")"
  # shellcheck disable=SC2034 # read by the sourced block
  gate() {   # BRIDGE HYPR_VM QS_PID SHELL_PATH -> restart|-
    environ "$4"
    ( declare -A F; F[bridge]=$1; hypr_vm=$2; U=u; OMARCHY_OVERRIDES=$T/ovr; export QS_PID=$3 PATH="$T/stub:$PATH"
      log() { :; }; restart_shell_later() { echo restart; }
      source "$T/gate.sh" ) | tr -d '\n'
  }
  if (( BASH_VERSINFO[0] < 4 )); then
    echo "skip install.sh's gate: bash ${BASH_VERSION} has no associative arrays (the VM's bash and CI's do)"
  else
    expect "install: Bridge on, omacvm_vm.lua updated, the shell from before: restart" restart "$(gate on updated 4242 "$OLD")"
    expect "install: ... added (first apply on this VM): restart" restart "$(gate on added 4242 "$OLD")"
    expect "install: ... the shell already has the folder: no restart" "" "$(gate on updated 4242 "$NEW")"
    expect "install: omacvm_vm.lua unchanged (Hyprland did not reload it): no restart again" "" "$(gate on "" 4242 "$OLD")"
    expect "install: Bridge off: no restart" "" "$(gate off updated 4242 "$OLD")"
    expect "install: no shell running: no restart (the next one gets Hyprland's PATH)" "" "$(gate on updated "" "$OLD")"
  fi
  expect "install: the gate comes after the Bridge's step, before the end's restart-shell.sh" yes \
    "$(awk '/"\$R\/bridge\/guest\/install.sh"/ {a=NR} /&& ! shell_runs_overrides; then$/ {b=NR} /user_script "\$R\/guest\/restart-shell.sh" \|\| true/ {c=NR} END {print (a && b > a && c > b) ? "yes" : "no"}' "$INS")"
fi

(( fail == 0 )) && echo "nightlight-path: all passed"
exit $fail
