#!/bin/bash
# Touch ID's guest side (ADR 0041) without a VM: the PAM client against a
# fake Bridge (tests/touchid/fake-bridge.py) and a fake logind
# (tests/touchid/fake-loginctl) for every answer and every session it can
# meet, the polkit rule's note writer, and touchid.sh putting its PAM lines
# in and taking them out again.
#   src/tests/touchid-client.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
G=$R/src/bridge/guest
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
expect() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: want '$2', got '$3'"; fi; }
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
T=$(mktemp -d); FPID=
trap 'if [[ -n $FPID ]]; then kill "$FPID" 2>/dev/null; fi; rm -rf "$T"' EXIT

ME=$(id -u)
mkdir -p "$T/etc" "$T/run" "$T/proc/$$" "$T/bridge" "$T/logind" "$T/dev/pts" "$T/actions"
openssl rand -hex 32 > "$T/bridge/token"; openssl rand -hex 32 > "$T/bridge/key"
cp "$T/bridge/token" "$T/etc/touchid-token"; cp "$T/bridge/key" "$T/etc/touchid-key"
chmod 600 "$T/etc/"*
: > "$T/dev/pts/3"   # the terminal sudo runs in (a file here; the user owns it)
sudo_argv() { printf '%s\0' "$@" > "$T/proc/$$/cmdline"; }
sudo_argv sudo pacman -Syu
echo 2 > "$T/proc/$$/sessionid"   # the user's service manager (uwsm terminals)
session() {   # ID Name Remote Active Seat Class
  printf 'Name=%s\nRemote=%s\nActive=%s\nSeat=%s\nClass=%s\n' "$2" "$3" "$4" "$5" "$6" > "$T/logind/session-$1"
}
session 1 vincent no yes seat0 user          # the desktop
session 2 vincent no yes '' manager          # its service manager
echo Display=1 > "$T/logind/user-$ME"
cat > "$T/actions/test.policy" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <action id="com.1password.1Password.unlock"><defaults><allow_active>auth_self</allow_active></defaults></action>
  <action id="org.freedesktop.policykit.exec"><defaults><allow_active>auth_admin</allow_active></defaults></action>
  <action id="org.freedesktop.NetworkManager.network-control"><defaults><allow_active>yes</allow_active></defaults></action>
</policyconfig>
EOF
python3 "$R/src/tests/touchid/fake-bridge.py" "$T/bridge" 2> "$T/bridge/err" & FPID=$!
for _ in $(seq 150); do [[ -s $T/bridge/port ]] && break; sleep 0.1; done
[[ -s $T/bridge/port ]] || { echo "FAIL the fake Bridge did not start"; cat "$T/bridge/err"; exit 1; }

export OMACVM_TOUCHID_TEST=1 OMACVM_TOUCHID_ETC=$T/etc OMACVM_TOUCHID_RUN=$T/run OMACVM_TOUCHID_PROC=$T/proc
export OMACVM_TOUCHID_DEV=$T/dev OMACVM_TOUCHID_ACTIONS=$T/actions OMACVM_TOUCHID_UID_MIN=$ME
export OMACVM_TOUCHID_LOGINCTL=$R/src/tests/touchid/fake-loginctl OMACVM_TOUCHID_LOGIND=$T/logind
export OMACVM_TOUCHID_HOST=127.0.0.1 OMACVM_TOUCHID_PORT=$(cat "$T/bridge/port")
export PAM_TYPE=auth PAM_USER=vincent PAM_SERVICE=sudo PAM_TTY=/dev/pts/3
# The client's parent is this shell ($$): its "sudo" command line and session are the fake ones above.
run() {   # MODE -> rc in $rc, output in $T/out, the request's body in $last
  echo "$1" > "$T/bridge/mode"; : > "$T/bridge/requests"
  python3 "$G/omacvm-touchid" > "$T/out" 2>&1; rc=$?
  last=$(tail -1 "$T/bridge/requests" | python3 -c 'import json, sys; l = sys.stdin.read(); print(json.loads(l)["body"] if l else "")')
}
asked() { expect "$1" "$2" "$last"; }

# ---- sudo: the answers ----
run yes; expect "yes: let in" 0 "$rc"
expect "asks on the screen" "Touch ID on your Mac, or wait for the password prompt" "$(head -1 "$T/out")"
asked "sudo: kind, command and terminal" '{"user":"vincent","kind":"sudo","detail":"pacman -Syu","tty":"pts/3"}'
run no-cancelled; expect "cancelled: password" 1 "$rc"
expect "cancelled: nothing more said" 1 "$(wc -l < "$T/out" | tr -d ' ')"
run no-not-front; expect "VM not in front: password" 1 "$rc"
expect "VM not in front: said" "Touch ID not available (VM not in front), use your password" "$(tail -1 "$T/out")"
run no-locked; expect "Mac locked: said" "Touch ID not available (Mac locked), use your password" "$(tail -1 "$T/out")"
run off; expect "off on the Mac (unsigned, as the Bridge sends it): password" 1 "$rc"
expect "off on the Mac: said" "Touch ID not available (Touch ID off), use your password" "$(tail -1 "$T/out")"
run off-other; expect "another unsigned refusal: nothing said" 1 "$(wc -l < "$T/out" | tr -d ' ')"
run clock; expect "VM clock off: said" "Touch ID not available (VM clock off), use your password" "$(tail -1 "$T/out")"
run unsigned; expect "unsigned yes: password" 1 "$rc"
run other-key; expect "yes signed with another key: password" 1 "$rc"
run other-nonce; expect "yes for another request: password" 1 "$rc"
run wrong-proof; expect "Bridge without the token: password" 1 "$rc"
expect "... and the token never sent" 0 "$(wc -l < "$T/bridge/requests" | tr -d ' ')"
mv "$T/etc/touchid-key" "$T/key.off"; run yes; expect "no key (off in the VM): password" 1 "$rc"; mv "$T/key.off" "$T/etc/touchid-key"

# ---- who may ask: the person at the VM's screen only ----
PAM_SERVICE=login run yes; expect "another PAM service: password" 1 "$rc"; asked "... without asking" ""
PAM_SERVICE=sudo-i run yes; expect "sudo -i: asks" 0 "$rc"
session 9 vincent yes yes '' user; echo 9 > "$T/proc/$$/sessionid"
run yes; expect "from an SSH login: password" 1 "$rc"; asked "... without asking" ""
session 9 bob no yes seat0 user; run yes; expect "from another user's session: password" 1 "$rc"
session 9 vincent no yes '' background; run yes; expect "from a cron job's session: password" 1 "$rc"
session 9 vincent no yes seat0 user; run yes; expect "from a text console of the user: asks" 0 "$rc"
echo 77 > "$T/proc/$$/sessionid"; run yes; expect "an audit session logind does not know (cronie's): password" 1 "$rc"
echo 4294967295 > "$T/proc/$$/sessionid"; run yes; expect "no audit session: the desktop decides" 0 "$rc"
echo 2 > "$T/proc/$$/sessionid"
session 1 vincent yes yes seat0 user; run yes; expect "desktop session remote: password" 1 "$rc"
session 1 vincent no no seat0 user; run yes; expect "desktop session not active (switched away): password" 1 "$rc"
session 1 vincent no yes '' user; run yes; expect "desktop session without a seat: password" 1 "$rc"
session 1 bob no yes seat0 user; run yes; expect "someone else at the screen: password" 1 "$rc"; asked "... without asking" ""
session 1 vincent no yes seat0 user
mv "$T/logind/user-$ME" "$T/user.off"; run yes; expect "no desktop session: password" 1 "$rc"; mv "$T/user.off" "$T/logind/user-$ME"
PAM_USER=root run yes; expect "root (rootpw, targetpw, polkit's admin): password" 1 "$rc"; asked "... without asking" ""
OMACVM_TOUCHID_UID_MIN=$(( ME + 1 )) run yes; expect "a system user: password" 1 "$rc"
PAM_USER='Bad User' run yes; expect "odd user name: password" 1 "$rc"
session 1 first.last no yes seat0 user; session 2 first.last no yes '' manager
PAM_USER=first.last run yes; expect "a user name with a dot: asks" 0 "$rc"
session 1 vincent no yes seat0 user; session 2 vincent no yes '' manager

# ---- sudo: a terminal of the user's, a command the dialog can show whole ----
PAM_TTY= run yes; expect "sudo without a terminal (sudo -n in the background): password" 1 "$rc"; asked "... without asking" ""
PAM_TTY=/dev/pts/9 run yes; expect "a terminal that is not there: password" 1 "$rc"
PAM_TTY=ssh run yes; expect "not a terminal name: password" 1 "$rc"
PAM_TTY=/dev/tty3 run yes; expect "a console that is not there: password" 1 "$rc"
sudo_argv sudo PACMAN=x LD_PRELOAD=/tmp/x.so pacman -Syu; run yes
expect "variables on sudo's command line: password" 1 "$rc"; asked "... without asking" ""
expect "... and says why" "Touch ID not used for this command (too long or sets variables), use your password" "$(tail -1 "$T/out")"
sudo_argv sudo -E pacman -S "$(printf 'p%.0s' $(seq 130))"; run yes; expect "a command too long to show whole: password" 1 "$rc"
sudo_argv sudo pacman -S "$(printf 'caf\xc3\xa9')" "$(printf 'a\tb')"; run yes
asked "not plain ASCII: '?', not dropped" '{"user":"vincent","kind":"sudo","detail":"pacman -S caf? a?b","tty":"pts/3"}'
sudo_argv sudoedit /etc/hosts; run yes; asked "sudoedit named" '{"user":"vincent","kind":"sudo","detail":"sudoedit /etc/hosts","tty":"pts/3"}'
sudo_argv sudo pacman -Syu

# ---- polkit: the rule's notes ----
export PAM_SERVICE=polkit-1
N=$G/omacvm-touchid-note
note() { "$N" vincent "$1"; }
rm -f "$T/run/vincent"; run yes; expect "no check noted: password" 1 "$rc"; asked "... without asking" ""
note com.1password.1Password.unlock; expect "the rule's note" 0 "$?"
run yes; asked "1Password: kind" '{"user":"vincent","kind":"1password"}'
rm -f "$T/run/vincent"; note org.freedesktop.policykit.exec; run yes
asked "polkit: the action" '{"user":"vincent","kind":"polkit","action":"org.freedesktop.policykit.exec"}'
note com.1password.1Password.unlock; run yes
asked "pkexec, then a pkcheck for 1Password: no name at all (H1)" '{"user":"vincent","kind":"polkit"}'
rm -f "$T/run/vincent"; note com.1password.1Password.unlock; note org.freedesktop.NetworkManager.network-control; run yes
asked "the desktop's own checks that never ask do not count" '{"user":"vincent","kind":"1password"}'
rm -f "$T/run/vincent"; note org.freedesktop.NetworkManager.network-control; run yes
expect "only checks that never ask: password" 1 "$rc"
rm -f "$T/run/vincent"; note org.example.unknown; run yes
asked "an action without a file still counts" '{"user":"vincent","kind":"polkit","action":"org.example.unknown"}'
echo "$(( $(date +%s) - 8 )) org.freedesktop.policykit.exec" > "$T/run/vincent"; run yes
expect "a note older than 5 s: password" 1 "$rc"
echo "$(( $(date +%s) - 8 )) org.freedesktop.policykit.exec" > "$T/run/vincent"; note com.1password.1Password.unlock; run yes
asked "... but it still takes the name from a newer one" '{"user":"vincent","kind":"polkit"}'
echo "$(( $(date +%s) - 30 )) org.freedesktop.policykit.exec" > "$T/run/vincent"; note com.1password.1Password.unlock; run yes
asked "a note from long ago does not" '{"user":"vincent","kind":"1password"}'
rm -f "$T/run/vincent"; note com.1password.1Password.unlock; "$N" --other org.freedesktop.policykit.exec
expect "the rule's note for someone not at the screen" yes "$([[ -s $T/run/.other ]] && echo yes)"
run yes; expect "pkexec over SSH right after a local check: password (M5)" 1 "$rc"; asked "... without asking" ""
rm -f "$T/run/.other"; "$N" --other org.freedesktop.NetworkManager.network-control; run yes
asked "... but not for their checks that never ask" '{"user":"vincent","kind":"1password"}'
rm -f "$T/run/.other" "$T/run/vincent"; note org.freedesktop.policykit.exec
session 9 vincent yes yes '' user; echo 9 > "$T/proc/$$/sessionid"
run yes; expect "polkit from an SSH login (setuid helper): password" 1 "$rc"; echo 2 > "$T/proc/$$/sessionid"
PAM_USER=root run yes; expect "polkit as root (auth_admin for a user outside wheel): password" 1 "$rc"
"$N" vincent 'bad action;rm'; expect "a bad note is refused" 1 "$?"
"$N" ../x a.b; expect "a bad user in a note is refused" 1 "$?"
"$N" "$(printf 'u%.0s' $(seq 33))" a.b; expect "a user name too long is refused" 1 "$?"
for i in $(seq 400); do note org.freedesktop.policykit.exec; done
if (( $(wc -c < "$T/run/vincent") <= 4200 )); then ok "notes stay short"; else bad "notes grow: $(wc -c < "$T/run/vincent") bytes"; fi

# ---- OmacVM.app: the port org.omacvm.auth (a Unix socket standing in), the app relaying to the Bridge ----
export PAM_SERVICE=sudo
PS=$T/auth.sock
python3 "$R/src/tests/touchid/fake-auth-port.py" "$T/bridge" "$PS" "$(cat "$T/bridge/port")" 2> "$T/bridge/port-err" & PPID2=$!
trap 'kill "$PPID2" 2>/dev/null; if [[ -n $FPID ]]; then kill "$FPID" 2>/dev/null; fi; rm -rf "$T"' EXIT
for _ in $(seq 100); do [[ -e $T/bridge/port-ready ]] && break; sleep 0.1; done
echo "OMACVM_VM_TYPE=app" > "$T/etc/env"
export OMACVM_TOUCHID_AUTH_PORT=$PS
port_ops() { cut -d' ' -f1 "$T/bridge/port-ops" 2>/dev/null | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}'; }
: > "$T/bridge/port-mode"; : > "$T/bridge/port-ops"
mv "$T/etc/touchid-token" "$T/token.off"   # the app adds the token: the VM needs none for the port
s=$(ms); run yes; took=$(( $(ms) - s ))
expect "app: yes over the port: let in" 0 "$rc"
expect "app: asks on the screen" "Touch ID on your Mac, or wait for the password prompt" "$(head -1 "$T/out")"
asked "app: the same request" '{"user":"vincent","kind":"sudo","detail":"pacman -Syu","tty":"pts/3"}'
expect "app: the token added by the app, not the VM" "Bearer $(cat "$T/bridge/token")" "$(tail -1 "$T/bridge/requests" | python3 -c 'import json,sys; print(json.load(sys.stdin)["auth"])')"
expect "app: one request, then a cancel the app ignores" "cancel=1 touchid=1 " "$(port_ops)"
if (( took < 1500 )); then ok "app: answered in ${took} ms"; else bad "app: took ${took} ms"; fi
mv "$T/token.off" "$T/etc/touchid-token"
run no-not-front; expect "app: VM not in front: said" "Touch ID not available (VM not in front), use your password" "$(tail -1 "$T/out")"
run off; expect "app: off on the Mac: said" "Touch ID not available (Touch ID off), use your password" "$(tail -1 "$T/out")"
run unsigned; expect "app: unsigned yes: password" 1 "$rc"
run other-key; expect "app: yes signed with another key: password" 1 "$rc"
run other-nonce; expect "app: yes for another request: password" 1 "$rc"
echo stale > "$T/bridge/port-mode"; run yes; expect "app: an earlier client's answer and junk skipped, ours taken" 0 "$rc"
echo status0 > "$T/bridge/port-mode"; s=$(ms); run yes; took=$(( $(ms) - s ))
expect "app: the Bridge did not answer: password" 1 "$rc"
if (( took < 1500 )); then ok "app: ... at once (${took} ms)"; else bad "app: status 0 took ${took} ms"; fi
echo close > "$T/bridge/port-mode"; s=$(ms); run yes; took=$(( $(ms) - s ))
expect "app: the app hangs up: password" 1 "$rc"
if (( took < 2000 )); then ok "app: ... at once (${took} ms)"; else bad "app: hang-up took ${took} ms"; fi
echo noack > "$T/bridge/port-mode"; s=$(ms); run yes; took=$(( $(ms) - s ))
expect "app: nobody relays (writes taken, no ack): password" 1 "$rc"
expect "app: ... and says so" "Touch ID not available (OmacVM.app does not answer), use your password" "$(tail -1 "$T/out")"
if (( took < 3000 )); then ok "app: ... after the ack wait (${took} ms)"; else bad "app: no ack took ${took} ms"; fi
: > "$T/bridge/port-mode"
OMACVM_TOUCHID_AUTH_PORT=$T/none run yes
expect "app: no port (the VM started before touch-id was on): password" 1 "$rc"
expect "app: ... and says to restart once" "Touch ID not available (shut the VM down and start it again once), use your password" "$(tail -1 "$T/out")"
asked "app: ... without asking" ""
PAM_TTY= run yes; expect "app: the same rules (sudo without a terminal): password" 1 "$rc"; asked "app: ... without asking" ""
# A dialog nobody answers: the pings keep it up; when the client is killed (Ctrl+C) the pings stop and it goes.
echo hang > "$T/bridge/mode"; rm -f "$T/bridge/closed"; : > "$T/bridge/port-ops"
python3 "$G/omacvm-touchid" > /dev/null 2>&1 & CP=$!
sleep 2.5
expect "app: pings keep the dialog up past the app's timeout" no "$([[ -f $T/bridge/closed ]] && echo yes || echo no)"
n=$(grep -c '^ping ' "$T/bridge/port-ops"); if (( n >= 3 )); then ok "app: pinged ($n in 2.5 s)"; else bad "app: $n pings in 2.5 s"; fi
kill -9 "$CP"; wait "$CP" 2>/dev/null
for _ in $(seq 40); do [[ -f $T/bridge/closed ]] && break; sleep 0.1; done
expect "app: client killed: the Mac's dialog goes (pings stopped)" yes "$([[ -f $T/bridge/closed ]] && echo yes)"
# Ctrl+C in sudo's terminal: pam_exec runs the client in a session of its own, so the terminal's SIGINT reaches only
# sudo, which blocks it while PAM runs. The client sees it pending at its parent, cancels at once, the password follows.
rm -f "$T/bridge/closed"; : > "$T/bridge/port-ops"
printf 'Name:\tsudo\nSigPnd:\t0000000000000000\nShdPnd:\t0000000000000000\nSigBlk:\t0000000000000006\n' > "$T/proc/$$/status"
python3 "$G/omacvm-touchid" > /dev/null 2>&1 & CP=$!
sleep 1.5
expect "app: nothing pending at sudo: still asking" yes "$(kill -0 "$CP" 2>/dev/null && echo yes)"
printf 'Name:\tsudo\nSigPnd:\t0000000000000000\nShdPnd:\t0000000000000002\nSigBlk:\t0000000000000006\n' > "$T/proc/$$/status"
s=$(ms); gone=no; for _ in $(seq 30); do kill -0 "$CP" 2>/dev/null || { gone=yes; break; }; sleep 0.1; done; took=$(( $(ms) - s ))
wait "$CP"; crc=$?
expect "app: Ctrl+C pending at sudo: the client stops with a no" "yes 1" "$gone $crc"
if (( took < 1500 )); then ok "app: ... at once (${took} ms)"; else bad "app: Ctrl+C took ${took} ms"; fi
for _ in $(seq 20); do [[ -f $T/bridge/closed ]] && break; sleep 0.1; done
expect "app: ... with a cancel, and the Mac's dialog goes" "cancel yes" "$(tail -1 "$T/bridge/port-ops" | cut -d' ' -f1) $([[ -f $T/bridge/closed ]] && echo yes)"
rm -f "$T/proc/$$/status"
rm -f "$T/bridge/closed"; : > "$T/bridge/port-ops"
s=$(ms); OMACVM_TOUCHID_DEADLINE=1 run hang; took=$(( $(ms) - s ))
for _ in $(seq 20); do [[ -f $T/bridge/closed ]] && break; sleep 0.1; done
expect "app: the deadline: password, and a cancel" "1 cancel" "$rc $(tail -1 "$T/bridge/port-ops" | cut -d' ' -f1)"
expect "app: ... the Mac's dialog goes" yes "$([[ -f $T/bridge/closed ]] && echo yes)"
if (( took < 2500 )); then ok "app: ... after the deadline (${took} ms)"; else bad "app: deadline took ${took} ms"; fi
kill "$PPID2" 2>/dev/null; wait "$PPID2" 2>/dev/null
rm -f "$T/etc/env"; unset OMACVM_TOUCHID_AUTH_PORT
export PAM_SERVICE=polkit-1; rm -f "$T/run/vincent"; note org.freedesktop.policykit.exec   # as the polkit part left it

# ---- a Bridge that never finishes, a caller that goes, a Bridge that is down ----
s=$(ms); OMACVM_TOUCHID_DEADLINE=2 run drip; took=$(( $(ms) - s ))
expect "a dripping Bridge: password" 1 "$rc"
if (( took < 4000 )); then ok "... after the deadline (${took} ms)"; else bad "a dripping Bridge held it ${took} ms"; fi
echo hang > "$T/bridge/mode"; rm -f "$T/bridge/closed"
bash -c 'python3 "$1" > /dev/null 2>&1 & echo $! > "$2"; sleep 0.6' _ "$G/omacvm-touchid" "$T/client.pid"
gone=no; for _ in $(seq 20); do kill -0 "$(cat "$T/client.pid")" 2>/dev/null || { gone=yes; break; }; sleep 0.1; done
expect "the caller went (agent's Cancel): the client stops" yes "$gone"
for _ in $(seq 20); do [[ -f $T/bridge/closed ]] && break; sleep 0.1; done
expect "... and the Mac's side sees it go (the dialog closes)" yes "$([[ -f $T/bridge/closed ]] && echo yes)"
kill "$FPID"; wait "$FPID" 2>/dev/null; FPID=
export PAM_SERVICE=sudo
s=$(ms); run yes; took=$(( $(ms) - s ))
expect "Bridge down: password" 1 "$rc"
if (( took < 2000 )); then ok "Bridge down: answered in ${took} ms"; else bad "Bridge down: took ${took} ms"; fi

# ---- touchid.sh: the PAM lines in before the first auth line, once; out again, files as before ----
P=$T/root/etc/pam.d; V=$T/root/usr/lib/pam.d; mkdir -p "$P" "$V"
printf '#%%PAM-1.0\nauth\t\tinclude\t\tsystem-auth\naccount\t\tinclude\t\tsystem-auth\nsession\t\tinclude\t\tsystem-auth\n' > "$P/sudo"
# polkit 127: only the vendor's file
printf '#%%PAM-1.0\n\nauth       include      system-auth\naccount    include      system-auth\npassword   include      system-auth\nsession    include      system-auth\n' > "$V/polkit-1"
printf '#%%PAM-1.0\nauth include system-auth\n' > "$P/login"
cp -R "$P" "$T/pam.orig"; cp -R "$V" "$T/vendor.orig"
mkdir -p "$T/root/etc/polkit-1/rules.d"; touch "$T/root/etc/polkit-1/rules.d/49-omacvm-touchid.rules"
OMACVM_TOUCHID_ROOT=$T/root "$G/touchid.sh" on && OMACVM_TOUCHID_ROOT=$T/root "$G/touchid.sh" on
L='auth       sufficient   pam_exec.so quiet seteuid stdout /usr/lib/omacvm/omacvm-touchid'
expect "on: sudo's first auth line is ours" "$L" "$(grep -m1 '^auth' "$P/sudo")"
expect "on: polkit-1 (vendor file only) gets a copy in /etc with ours first" "$L" "$(grep -m1 '^auth' "$P/polkit-1")"
expect "... the rest as the vendor's" "$(grep -v '^#' "$V/polkit-1")" "$(grep -v '^#' "$P/polkit-1" | grep -vxF "$L")"
expect "on twice: one line" 1 "$(grep -c pam_exec "$P/sudo")"
expect "no sudo-i here: none made" no "$([[ -e $P/sudo-i ]] && echo yes || echo no)"
expect "login untouched" "" "$(diff "$T/pam.orig/login" "$P/login")"
expect "vendor files untouched" "" "$(diff -r "$T/vendor.orig" "$V")"
printf 'session    optional     pam_example.so\n' >> "$V/polkit-1"   # polkit's update changes the vendor's file
OMACVM_TOUCHID_ROOT=$T/root "$G/touchid.sh" on
expect "on again: our copy follows the vendor's newer file" "$(grep -v '^#' "$V/polkit-1")" "$(grep -v '^#' "$P/polkit-1" | grep -vxF "$L")"
expect "... still with one line of ours" 1 "$(grep -c pam_exec "$P/polkit-1")"
cp "$V/polkit-1" "$T/vendor.orig/polkit-1"
expect "the client, the note writer and the rule installed" yes \
  "$([[ -x $T/root/usr/lib/omacvm/omacvm-touchid && -x $T/root/usr/lib/omacvm/omacvm-touchid-note && -f $T/root/etc/polkit-1/rules.d/00-omacvm-touchid.rules ]] && echo yes)"
expect "the theme sender and its user units installed (the Touch ID panel's colours)" yes \
  "$([[ -x $T/root/usr/lib/omacvm/omacvm-touchid-theme && -f $T/root/etc/systemd/user/omacvm-touchid-theme.path && -f $T/root/etc/systemd/user/omacvm-touchid-theme.service ]] && echo yes)"
D=$T/root/etc/systemd/system/polkit-agent-helper@.service.d/omacvm-touchid.conf
expect "polkit's helper may reach the Bridge (no env: the default address), nothing else" \
  "PrivateNetwork=no RestrictAddressFamilies=AF_UNIX AF_INET IPAddressDeny=any IPAddressAllow=10.211.55.2" "$(grep -v '^[#[]' "$D" | tr '\n' ' ' | sed 's/ $//')"
mkdir -p "$T/root/etc/omacvm"; echo "OMACVM_HOST='10.0.2.2'" > "$T/root/etc/omacvm/env"
OMACVM_TOUCHID_ROOT=$T/root "$G/touchid.sh" on
expect "... the Bridge's address from the VM's env" "IPAddressAllow=10.0.2.2" "$(grep IPAddressAllow "$D")"
echo "OMACVM_VM_TYPE=app" >> "$T/root/etc/omacvm/env"; OMACVM_TOUCHID_ROOT=$T/root "$G/touchid.sh" on
expect "OmacVM.app: polkit's helper gets the port, no network" "BindPaths=-/dev/virtio-ports/org.omacvm.auth DeviceAllow=char-virtio-portsdev rw" \
  "$(grep -v '^[#[]' "$D" | tr '\n' ' ' | sed 's/ $//')"
echo "OMACVM_HOST='10.0.2.2'" > "$T/root/etc/omacvm/env"
expect "the port rule: org.omacvm.auth root's alone" 'SUBSYSTEM=="virtio-ports", ATTR{name}=="org.omacvm.auth", OWNER="root", GROUP="root", MODE="0600"' "$(cat "$T/root/etc/udev/rules.d/70-omacvm-auth.rules")"
expect "the old rule's name gone" no "$([[ -e $T/root/etc/polkit-1/rules.d/49-omacvm-touchid.rules ]] && echo yes || echo no)"
touch "$T/root/etc/omacvm/touchid-key" "$T/root/etc/omacvm/touchid-token"
OMACVM_TOUCHID_ROOT=$T/root "$G/touchid.sh" off
expect "off: sudo as before" "" "$(diff "$T/pam.orig/sudo" "$P/sudo")"
expect "off: our polkit-1 copy gone, the vendor's counts again" no "$([[ -e $P/polkit-1 ]] && echo yes || echo no)"
expect "off: client, rule, drop-in, theme sender, its units and keys gone" "" \
  "$(ls "$T/root/usr/lib/omacvm" "$T/root/etc/polkit-1/rules.d" "$T/root/etc/systemd/system" "$T/root/etc/systemd/user" "$T/root/etc/omacvm" "$T/root/etc/udev/rules.d" 2>/dev/null | grep -v ':$' | grep -vx env | grep .)"
exit $fail
