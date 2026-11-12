# Shared helpers for build.sh and apply.sh (sourced, Mac side).
log() { OMA_LAST=$*; printf '\033[1;32m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
# python3 and the Swift answers without Xcode's Command Line Tools (src/lib/tools.sh).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tools.sh"
tools_path
source "$(dirname "${BASH_SOURCE[0]}")/version.sh"
source "$(dirname "${BASH_SOURCE[0]}")/labels.sh"

# Progress for the control centre's jobs (OMACVM_PROGRESS=json, set by the
# Bridge): one JSON line per step, "step n of m". A command that runs another
# passes its count on (OMACVM_STEP_BASE steps done, OMACVM_STEP_OF in all).
OMA_STEP=${OMACVM_STEP_BASE:-0}; OMA_STEPS=${OMACVM_STEP_OF:-0}
step() {   # NAME TEXT
  OMA_STEP=$((OMA_STEP + 1)); (( OMA_STEP <= OMA_STEPS )) || OMA_STEPS=$OMA_STEP
  [[ ${OMACVM_PROGRESS:-} == json ]] || return 0
  local t=${2//\\/\\\\}; t=${t//\"/\\\"}
  printf '{"omacvm_progress": 1, "step": "%s", "n": %d, "of": %d, "text": "%s"}\n' "$1" "$OMA_STEP" "$OMA_STEPS" "$t"
}

# failed_part PART TEXT [SIDE]: what failed in a job (PART a feature, or
# empty; SIDE vm, the default, or mac), for the person and, as a JSON line,
# for the control centre. OMA_FAILED keeps the last TEXT (apply's rollback
# line names it: OmacVM.app shows only a job's last line).
failed_part() {
  local t
  t=$(printf '%s' "$2" | tr '\000-\037' ' ' | cut -c1-160)
  OMA_FAILED=$t
  info "what failed: $t"
  [[ ${OMACVM_PROGRESS:-} == json ]] || return 0
  t=${t//\\/\\\\}; t=${t//\"/\\\"}
  printf '{"omacvm_failed": 1, "part": "%s", "text": "%s", "side": "%s"}\n' "$1" "$t" "${3:-vm}"
}

# mac_helper_feature HELPER: the feature a Mac helper is for (empty: none).
mac_helper_feature() {
  case $1 in
    "OmacVM Bridge") echo bridge ;;
    "OmacVM Gestures") echo gestures ;;
    Omanotch) echo omanotch ;;
  esac
}

# media_keys_state LINE: the Bridge's last "media keys: event tap|waiting|cannot"
# log line -> "ok|warn|fail<TAB>detail". The tap is created again whenever an
# OmacVM VM comes to the front or macOS invalidated it: that is how it works,
# not a failure. A failed re-creation keeps the old tap (works, so warn).
# Since #290 the tap exists only while a VM is in front ("armed" until then: ok);
# one macOS disabled is removed and comes back after a hold-off (warn).
media_keys_state() {
  local m=${1#media keys: }
  case $m in
    "event tap installed"*|"event tap created again"*) printf 'ok\tevent tap installed\n' ;;
    "event tap armed"*) printf 'ok\tevent tap armed (made while a VM is in front)\n' ;;
    *"keeping the old one"*|"event tap removed"*) printf 'warn\t%s\n' "$m" ;;
    "") printf 'fail\tno event tap yet\n' ;;
    *) printf 'fail\t%s\n' "$m" ;;
  esac
}

# helper_pid bridge|gestures [test]: this user's running OmacVM Bridge or
# Gestures, whichever job started it: its LaunchAgent, or macOS itself
# (System Settings' "Quit & Reopen" after a grant, Finder: an
# application.<id>.* job, #331). The oldest one (Gestures asks a short-lived
# copy of itself about its permissions). test: the test identity's.
# -a: also an ancestor of this shell. pgrep leaves its own ancestors out by
# default, and the Bridge runs omacvm check for the control centre: without
# -a the Bridge never found itself ("not running" while it runs, 3.0.14).
helper_pid() {
  local exe
  case $1-${2:-} in
    bridge-test) exe="OmacVM Test Bridge\.app/Contents/MacOS/" ;;
    gestures-test) exe="OmacVM Test Gestures\.app/Contents/MacOS/" ;;
    bridge-) exe="OmacVMBridge\.app/Contents/MacOS/omacvm-bridge" ;;
    gestures-) exe="OmacVMGestures\.app/Contents/MacOS/omacvm-gestures" ;;
    *) return 1 ;;
  esac
  LC_ALL=C pgrep -a -o -u "$(id -u)" -f "$exe"   # bytes: in UTF-8, pgrep -f fails on any line that is not UTF-8 (#545)
}

# proc_started PID: when it started (seconds since 1970), from ps's elapsed time.
proc_started() {
  local e p d=0 h=0 m=0 s=0
  e=$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ') || return 1
  [[ -n $e ]] || return 1
  [[ $e == *-* ]] && { d=${e%%-*}; e=${e#*-}; }
  IFS=: read -r -a p <<<"$e"
  case ${#p[@]} in
    3) h=${p[0]} m=${p[1]} s=${p[2]} ;;
    2) m=${p[0]} s=${p[1]} ;;
    *) return 1 ;;
  esac
  echo $(( $(date +%s) - ((10#$d * 24 + 10#$h) * 60 + 10#$m) * 60 - 10#$s ))
}

# helper_log PID LOG: the running helper's own lines of its log, from its last
# "starting (pid PID" line (Bridge, Gestures from 3.0.14). A helper that does
# not say it: the whole log when it was written since the process started,
# else nothing and exit 1: the log is from a process before it (#331: a Bridge
# macOS started again wrote to /dev/null, and check read the old one's
# "permissions: ... MISSING").
helper_log() {
  local n started mt
  n=$(grep -nE "omacvm-[a-z]+: starting \(pid $1[,)]" "$2" 2>/dev/null | tail -1 | cut -d: -f1)
  if [[ -n $n ]]; then tail -n +"$n" "$2"; return 0; fi
  started=$(proc_started "$1") || return 1
  mt=$(stat -f %m "$2" 2>/dev/null) || return 1
  (( mt >= started )) || return 1
  cat "$2"
}

# gestures_state LOG: what OmacVM Gestures does, from its log (the running
# process's lines): "listening", "waiting<TAB>the missing permissions" (it
# waits for them at start and listens by itself once they are granted, #330)
# or "" (nothing said yet, or a helper from before it said so).
gestures_state() {
  local l p
  l=$(grep -E 'omacvm-gestures: (waiting for Accessibility|permissions granted|listening on|running)' "$1" 2>/dev/null | tail -1)
  case $l in
    *"waiting for Accessibility"*)
      p=$(grep -E 'omacvm-gestures: permissions: ' "$1" | tail -1 | sed -E 's/^.*permissions: //; s/[A-Za-z ]+ granted(, )?//g; s/ MISSING//g; s/[, ]+$//')
      printf 'waiting\t%s\n' "${p:-Accessibility}" ;;
    "") ;;
    *) echo listening ;;
  esac
}

# cli_for_bridge OMACVM: true when OMACVM (a checkout's omacvm, resolved) is
# the one the omacvm command runs: install.sh links it into one of these. So
# another clone or worktree that runs src/mac/install.sh never becomes what
# the Bridge runs (and moves on an update). No omacvm command at all (a clone
# run as ./omacvm): true. OMACVM_SET_CLI=1: true. OMACVM_CLI_LINKS: the links
# to look at, for tests.
cli_for_bridge() {
  local b links=0
  [[ ${OMACVM_SET_CLI:-} == 1 ]] && return 0
  for b in ${OMACVM_CLI_LINKS:-/opt/homebrew/bin/omacvm /usr/local/bin/omacvm $HOME/.local/bin/omacvm}; do
    [[ -e $b || -L $b ]] || continue
    links=1
    [[ $(realpath "$b" 2>/dev/null) == "$1" ]] && return 0
  done
  (( ! links ))
}

# cli_version OMACVM: the OmacVM version of that omacvm (its src/VERSION).
cli_version() { head -n1 "$(dirname "$(realpath "$1" 2>/dev/null || echo "$1")")/src/VERSION" 2>/dev/null; }

# cli_file_app OMACVM: OmacVM.app's copy of omacvm (OMACVM, inside the app)
# becomes what the Bridge runs, unless the file names a checkout that is still
# there (a CLI install keeps its own) and is not older than the app (#233: an
# old checkout ran the control centre's switches for a newer VM). So the
# app's setup, and each app start (app/app/Sources/OmacVM/ControlCLI.swift,
# the same rule), point it at the current app after an update or a move.
cli_file_app() {
  local f="$OMA_SUPPORT/cli" cur
  [[ $1 == /*/Contents/Resources/omacvm/omacvm && -f $1 ]] || return 0
  cur=$(head -n1 "$f" 2>/dev/null || true)
  [[ $cur == "$1" ]] && return 0
  if [[ -n $cur && -f $cur && $cur != */Contents/Resources/omacvm/omacvm ]] &&
     ! version_lt "$(cli_version "$cur")" "$(cli_version "$1")"; then return 0; fi
  mkdir -p "$OMA_SUPPORT"
  (umask 077; printf '%s\n' "$1" > "$f.new" && mv -f "$f.new" "$f")
}


# SSH into the guest as root with the OmacVM key. Each VM's host key is
# remembered the first time OmacVM sets the VM up (build, apply) and checked on
# every later connection: OMA_PIN is that VM's file (vm_pin, vm.sh), and
# OMA_PIN_NEW=1 lets a connection record the key when there is none yet. A VM
# without a remembered key (and OMA_PIN_NEW unset) is reached as before.
# IP:PORT for OmacVM.app's VMs (127.0.0.1 and the VM's SSH port).
# OMACVM_TEST_IDENTITY=1: the test identity ("OmacVM Test", app/scripts/build-app.sh
# --test-identity, whose Bridge runs omacvm with it): its own folders, never the
# installed helpers' token, keys or pins.
if [[ ${OMACVM_TEST_IDENTITY:-} == 1 ]]; then
  OMA_SUPPORT="$HOME/Library/Application Support/omacvm-test"
  OMA_BRIDGE_SUPPORT="$HOME/Library/Application Support/omacvm-test-bridge"
else
  OMA_SUPPORT="$HOME/Library/Application Support/omacvm"
  OMA_BRIDGE_SUPPORT="$HOME/Library/Application Support/omacvm-bridge"
fi
OMA_PINS="$OMA_SUPPORT/known_hosts"
gssh() {
  local ip=$1 port=22; shift
  [[ $ip == *:* ]] && { port=${ip##*:}; ip=${ip%:*}; }
  local hk=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
  if [[ -n ${OMA_PIN:-} ]] && [[ -s $OMA_PIN || ${OMA_PIN_NEW:-} == 1 ]]; then
    [[ -s $OMA_PIN ]] || { mkdir -p "$(dirname "$OMA_PIN")" && chmod 700 "$(dirname "$OMA_PIN")"; }
    hk=(-o "StrictHostKeyChecking=$([[ -s $OMA_PIN ]] && echo yes || echo accept-new)"
        -o "UserKnownHostsFile=\"$OMA_PIN\"" -o HostKeyAlias=omacvm-vm -o CheckHostIP=no)
  fi
  # An OmacVM.app VM's own key first (OMA_VM_KEY, vm_pin): it goes along
  # when the VM folder is copied to another Mac; then this Mac's key.
  local ids=()
  [[ -n ${OMA_VM_KEY:-} && -f ${OMA_VM_KEY:-} ]] && ids=(-i "$OMA_VM_KEY")
  ssh ${ids[@]+"${ids[@]}"} -i "${OMA_KEY:-$HOME/.ssh/omacvm}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 \
    "${hk[@]}" -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -p "$port" "root@$ip" "$@"
}

# ssh_failure_why IP FILE: why SSH did not get in, from ssh's own messages in
# FILE (vm_probe with OMA_PROBE_ERR), one line; "hostkey" first when the VM
# answered with another host key than the one remembered. No second
# connection: every unauthenticated one (ssh-keyscan opens several) counts
# against the Mac in sshd's PerSourcePenalties (OpenSSH 9.8+), and enough of
# them turn the Mac away for up to 10 minutes; all of the Mac's connections
# come from one address (QEMU's user network: 10.0.2.2).
ssh_failure_why() {
  local ip=$1 e
  e=$(tr -d '\r' < "$2" 2>/dev/null | grep -v '^ *$' | grep -viE '^(@|It is also possible|Someone could be|Please contact|Add correct|Offending|Host key for|[A-Z]+ host key for)' | head -3 | tr '\n' ' ' | sed 's/ *$//')
  if grep -qE 'Host key verification failed|IDENTIFICATION HAS CHANGED' "$2" 2>/dev/null; then
    echo "hostkey $ip answers with another SSH host key"
  elif grep -q 'Permission denied' "$2" 2>/dev/null; then echo "OmacVM's SSH key did not get in at $ip"
  elif grep -q 'Connection refused' "$2" 2>/dev/null; then echo "nothing takes SSH at $ip (the VM is starting, or its SSH stopped)"
  elif grep -qiE 'timed out|Operation timed out' "$2" 2>/dev/null; then echo "SSH at $ip did not answer (the VM is busy, or its network is down)"
  elif grep -qE 'Connection (reset|closed)|kex_exchange_identification|Broken pipe' "$2" 2>/dev/null; then
    echo "SSH at $ip closed the connection (the VM is busy or starting, or its SSH turns the Mac away for a while after many tries)"
  elif [[ -n $e ]]; then echo "SSH to $ip did not get in: $(printf '%s' "$e" | tr -d '\000-\037' | cut -c1-160)"
  else
    # Nothing said: the VM's sshd closed the connection before a word (as it
    # does while PerSourcePenalties turns the Mac away; seen 2026-10-07).
    echo "SSH at $ip closed the connection (the VM is busy or starting, or its SSH turns the Mac away for a while after many tries)"
  fi
}

# hostkey_changed IP [SECONDS]: the VM answers, with other host keys than the one
# remembered for it.
hostkey_changed() {
  [[ -n ${OMA_PIN:-} && -s ${OMA_PIN:-} ]] || return 1
  local _h t k seen=0 ip=$1 port=22
  [[ $ip == *:* ]] && { port=${ip##*:}; ip=${ip%:*}; }   # OmacVM.app: 127.0.0.1:PORT
  while read -r _h t k; do
    [[ -n $k ]] || continue
    # Only a key of a type remembered tells: a scan cut short by a busy VM
    # may bring only the others.
    grep -qF " $t " "$OMA_PIN" || continue
    seen=1
    grep -qF " $t $k" "$OMA_PIN" && return 1
  done < <(ssh-keyscan -T "${2:-5}" -p "$port" "$ip" 2>/dev/null)
  (( seen ))
}

hostkey_error() {   # the VM's name (VM) and how apply names it (OMA_PIN_ARGS) come from vm_pin
  printf '\033[1;31merror:\033[0m %s answers with another SSH host key than the one OmacVM remembered for it.\n' "${VM:-the VM}" >&2
  local how="omacvm apply ${OMA_PIN_ARGS:-} --reset-host-key"
  [[ -n ${OMA_RESET_HINT:-} ]] && how=$OMA_RESET_HINT   # OmacVM.app's apply-vm.sh
  printf 'If you rebuilt or reinstalled it, forget the old key:\n\n  %s\n\nIf not, something else may answer at its address: do not go on.\n' \
    "$how" >&2
}

# The Bridge's token (the Bridge makes it on its first start). The VMs' gestures
# daemons say it too, so it is made here when Gestures comes without the Bridge.
BRIDGE_TOKEN="$OMA_BRIDGE_SUPPORT/token"
bridge_token_ensure() {
  [[ -f $BRIDGE_TOKEN && $(tr -d '[:space:]' < "$BRIDGE_TOKEN" | wc -c) -ge 32 ]] && return 0
  mkdir -p "$(dirname "$BRIDGE_TOKEN")" && chmod 700 "$(dirname "$BRIDGE_TOKEN")"
  (umask 077; openssl rand -hex 32 > "$BRIDGE_TOKEN")
}

# The control centre's key for one VM (TYPE NAME): the Bridge acts for a VM
# only when its request carries this key, so a VM that takes another VM's
# address cannot act for it (src/bridge/mac/control.swift reads it). Made at
# the VM's first apply, again with "new" (apply --reset-host-key: a rebuilt VM).
VM_KEYS="$OMA_SUPPORT/vm-keys"
vm_key_file() { printf '%s/%s' "$VM_KEYS" "$(printf '%s/%s' "$1" "$2" | shasum -a 256 | cut -c1-32)"; }
vm_key_ensure() {   # TYPE NAME [new] -> the key's file
  local f; f=$(vm_key_file "$1" "$2")
  if [[ ${3:-} == new || ! -s $f ]]; then
    mkdir -p "$VM_KEYS" && chmod 700 "$VM_KEYS"
    (umask 077; openssl rand -hex 32 > "$f.tmp") && mv -f "$f.tmp" "$f"
  fi
  echo "$f"
}

# Touch ID's key for one VM (ADR 0041), beside its control key: the Bridge
# shows a Touch ID dialog only for a VM whose request carries it. In the VM
# it is root's alone (/etc/omacvm/touchid-key). Gone when the feature is off.
touchid_key_ensure() {   # TYPE NAME [new] -> the key's file
  local f; f=$(vm_key_file "$1" "$2").touchid
  if [[ ${3:-} == new || ! -s $f ]]; then
    mkdir -p "$VM_KEYS" && chmod 700 "$VM_KEYS"
    (umask 077; openssl rand -hex 32 > "$f.tmp") && mv -f "$f.tmp" "$f"
  fi
  echo "$f"
}

# Omanotch on this Mac serves OmacVM.app's VMs (on 127.0.0.1) only from the
# version that knows the app's QEMU: 0 it does, 1 too old, 2 not installed.
omanotch_serves_app() {
  local b=$HOME/Applications/Omanotch.app/Contents/MacOS
  [[ -d $b ]] || return 2
  grep -aqF /Contents/Resources/runtime/bin/OmacVM "$b"/* 2>/dev/null || return 1
}
# ... and on the app's fast network (192.168.77.1): 0 it does, 1 too old, 2 not installed.
omanotch_serves_fast_network() {
  local b=$HOME/Applications/Omanotch.app/Contents/MacOS
  [[ -d $b ]] || return 2
  grep -aqF "on OmacVM.app's fast network" "$b"/* 2>/dev/null || return 1
}

wait_ssh() {   # <ip> [seconds]: 3 when the VM's host key changed
  # By the clock: each try can take seconds of its own. Another host key is
  # told by ssh itself (ssh_failure_why), never by a key scan per try: a VM
  # still booting would otherwise count a scan every 5 s against the Mac and
  # turn it away for minutes once it is up (PerSourcePenalties).
  local end=$((SECONDS + ${2:-600})) err
  err=$(mktemp -t omacvm-ssh)
  while :; do
    gssh "$1" true 2>"$err" && { rm -f "$err"; return 0; }
    [[ $(ssh_failure_why "$1" "$err") == "hostkey "* ]] && { rm -f "$err"; hostkey_error; return 3; }
    (( SECONDS < end )) || break
    sleep 5
  done
  rm -f "$err"
  die "no SSH on $1 after ${2:-600} s"
}

# lease_ip MAC: the newest address macOS's DHCP server (bootpd: vmnet's shared
# network) gave that MAC (aa:bb:..; the lease file drops leading zeros).
lease_ip() {
  local m
  m=$(tr 'A-F' 'a-f' <<<"$1" | sed 's/:0/:/g; s/^0//')
  [[ -n $m ]] || return 1
  awk -v m="1,$m" '/ip_address=/ { split($0, a, "="); ip = a[2] } /hw_address=/ { split($0, b, "="); if (b[2] == m) print ip }' \
    /var/db/dhcpd_leases 2>/dev/null | tail -1
}
