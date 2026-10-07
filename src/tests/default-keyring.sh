#!/bin/bash
# The desktop user's default keyring (src/guest/default-keyring.sh) without a
# VM: a home without keyrings (a VM from a prebuilt image) gets Omarchy's
# "Default keyring" (no password), from Omarchy's own step when the VM has it,
# else from OmacVM's copy; a home with keyrings of its own is never switched
# to another default; the first boot and omacvm apply run it; omacvm check's
# "keyring" line. runuser is a stand-in (runs the command as this user).
#   src/tests/default-keyring.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
K=$R/src/guest/default-keyring.sh
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/runuser" <<'EOF'
#!/bin/bash
echo "runuser $*" >> "$CALLS"
while [[ $1 != -- ]]; do shift; done; shift
exec "$@"
EOF
chmod +x "$T/bin/runuser"
# pkill: a gnome-keyring of the user runs when $T/daemon exists
cat > "$T/bin/pkill" <<'EOF2'
#!/bin/bash
echo "pkill $*" >> "$CALLS"
[[ -e $DAEMON ]]
EOF2
chmod +x "$T/bin/pkill"
export DAEMON=$T/daemon
export PATH=$T/bin:$PATH CALLS=$T/calls
export OMACVM_OMARCHY_DIR=$T/no-omarchy   # no Omarchy installer files unless a case makes them
perms() { ls -ld "$1" | cut -c1-10; }
fresh() { rm -rf "$T/h" "$CALLS"; mkdir -p "$T/h"; : > "$CALLS"; }

[[ -x $K ]] || { echo "FAIL src/guest/default-keyring.sh is missing"; exit 1; }

# 1. A home from the prebuilt image: no keyrings at all.
fresh
out=$("$K" status "$T/h"); rc=$?
expect "no keyrings: status" "none 1" "$out $rc"
out=$("$K" setup tester "$T/h"); rc=$?
expect "no keyrings: setup made it" "made (Default_keyring, OmacVM's copy of Omarchy's step) 0" "$out $rc"
d=$T/h/.local/share/keyrings
expect "default file" "Default_keyring" "$(cat "$d/default" 2>/dev/null)"
expect "keyring as Omarchy's (no password, never locks)" \
  "[keyring]|display-name=Default keyring|mtime=0|lock-on-idle=false|lock-after=false" \
  "$(grep -v '^ctime=' "$d/Default_keyring.keyring" 2>/dev/null | paste -sd'|' -)"
expect "keyring has a ctime" 1 "$(grep -c '^ctime=[0-9][0-9]*$' "$d/Default_keyring.keyring" 2>/dev/null)"
expect "modes (folder, keyring, default)" "drwx------ -rw------- -rw-r--r--" \
  "$(perms "$d") $(perms "$d/Default_keyring.keyring") $(perms "$d/default")"
expect "made as the user" "runuser -u tester -- env HOME=$T/h bash -c" "$(head -1 "$CALLS" | cut -d' ' -f1-8)"
out=$("$K" status "$T/h"); rc=$?
expect "status after" "Default_keyring 0" "$out $rc"
before=$(cat "$d/Default_keyring.keyring")
out=$("$K" setup tester "$T/h")
expect "second run keeps it" "kept (Default_keyring)" "$out"
expect "second run: keyring unchanged" "$before" "$(cat "$d/Default_keyring.keyring")"

# A gnome-keyring that runs (apply in a logged-in VM) does not see a new
# default keyring: setup restarts it, only when it made one.
fresh; : > "$T/daemon"
out=$("$K" setup tester "$T/h")
expect "running gnome-keyring restarted" "made (Default_keyring, OmacVM's copy of Omarchy's step; gnome-keyring restarted)" "$out"
expect "restart: the user's daemon only" "pkill -u tester -x gnome-keyring-d" "$(grep '^pkill' "$CALLS")"
: > "$CALLS"
expect "kept keyring: gnome-keyring not restarted" "kept (Default_keyring)" "$("$K" setup tester "$T/h")"
expect "kept keyring: no pkill" "" "$(cat "$CALLS")"
rm -f "$T/daemon"

# 2. Omarchy's own step when the VM has it (run as the user, with HOME).
fresh
mkdir -p "$T/omarchy/install/user"
cat > "$T/omarchy/install/user/default-keyring.sh" <<'EOF'
mkdir -p "$HOME/.local/share/keyrings"
printf '[keyring]\ndisplay-name=Default keyring\n' > "$HOME/.local/share/keyrings/Default_keyring.keyring"
echo Default_keyring > "$HOME/.local/share/keyrings/default"
echo omarchy-ran > "$HOME/marker"
EOF
out=$(OMACVM_OMARCHY_DIR=$T/omarchy "$K" setup tester "$T/h")
expect "Omarchy's step used" "made (Default_keyring, Omarchy's $T/omarchy/install/user/default-keyring.sh)" "$out"
expect "Omarchy's step ran with the user's HOME" omarchy-ran "$(cat "$T/h/marker" 2>/dev/null)"
# The checkout in the home (omarchy-mac) when /usr/share/omarchy has none.
fresh
mkdir -p "$T/h/.local/share/omarchy"; cp -R "$T/omarchy/install" "$T/h/.local/share/omarchy/"
out=$("$K" setup tester "$T/h")
expect "home checkout's step used" "made (Default_keyring, Omarchy's $T/h/.local/share/omarchy/install/user/default-keyring.sh)" "$out"
# Omarchy's step that makes nothing: OmacVM's copy after it.
fresh
mkdir -p "$T/broken/install/user"; echo 'exit 1' > "$T/broken/install/user/default-keyring.sh"
out=$(OMACVM_OMARCHY_DIR=$T/broken "$K" setup tester "$T/h")
expect "failed Omarchy step: OmacVM's copy" "made (Default_keyring, OmacVM's copy of Omarchy's step)" "$out"

# 3. Keyrings of the user's own are never switched away.
fresh; d=$T/h/.local/share/keyrings; mkdir -p "$d"; echo secret > "$d/login.keyring"
out=$("$K" setup tester "$T/h")
expect "login keyring (gnome-keyring's default without a default file) kept" "kept (login)" "$out"
expect "login keyring: nothing added" "login.keyring" "$(ls "$d" | paste -sd' ' -)"
fresh; d=$T/h/.local/share/keyrings; mkdir -p "$d"; echo secret > "$d/work.keyring"
out=$("$K" setup tester "$T/h")
expect "own keyring, no default: left alone" "left alone: $d has keyrings but no default one" "$out"
expect "own keyring: nothing added" "work.keyring" "$(ls "$d" | paste -sd' ' -)"
expect "own keyring: status none" "none" "$("$K" status "$T/h")"
fresh; d=$T/h/.local/share/keyrings; mkdir -p "$d"; echo secret > "$d/work.keyring"; echo work > "$d/default"
expect "own default keyring" "kept (work)" "$("$K" setup tester "$T/h")"
fresh; d=$T/h/.local/share/keyrings; mkdir -p "$d"; echo ../../x > "$d/default"
expect "odd default name: status none" "none" "$("$K" status "$T/h")"
expect "no runuser or pkill for kept homes" "" "$(grep -c . "$CALLS" | grep -v '^0$')"

# 4. Who runs it: the prebuilt first boot (new images) and omacvm apply's
# system steps (VMs from older images).
fb=$R/src/prebuilt/guest/omacvm-firstboot
expect "first boot runs it for the new user" 1 \
  "$(grep -c '"$S/guest/default-keyring.sh" setup "$NAME" "/home/$NAME"' "$fb")"
# after the home is the user's (chown), before the first boot ends
n_chown=$(grep -n 'chown -R -h "$NAME:$NAME"' "$fb" | cut -d: -f1); n_kr=$(grep -n 'default-keyring.sh" setup' "$fb" | cut -d: -f1)
n_done=$(grep -n 'rm -rf "$P/home" "$P/pending"' "$fb" | cut -d: -f1)
expect "first boot: after chown, before done" 1 "$(( n_chown < n_kr && n_kr < n_done ))"
gi=$R/src/guest/install.sh
expect "apply runs it as a system step" 1 \
  "$(grep -c '^if system && ! "$R/guest/default-keyring.sh" status "$H"' "$gi")"
expect "apply: setup for the desktop user" 1 "$(grep -c '"$R/guest/default-keyring.sh" setup "$U" "$H"' "$gi")"

# 5. omacvm check's "keyring" line (src/guest/check.sh, the block alone).
block=$(awk '/^# Omarchy.s default keyring/ { on = 1 } on { print } on && /^else bad "keyring"/ { exit }' "$R/src/guest/check.sh")
[[ -n $block ]] || { echo "FAIL check.sh has no keyring block"; fail=1; }
checkline() {   # HOME -> the line
  ( H=$1
    ok() { echo "ok $1: $2"; }; bad() { echo "FAIL $1: $2${3:+ (human)}"; }
    eval "$block" )
}
fresh
expect "check: no keyrings" "FAIL keyring: none: Chromium asks for a keyring password at its first start; omacvm apply makes Omarchy's default keyring" "$(checkline "$T/h")"
"$K" setup tester "$T/h" >/dev/null
expect "check: after setup" "ok keyring: Default_keyring (default)" "$(checkline "$T/h")"
fresh; d=$T/h/.local/share/keyrings; mkdir -p "$d"; : > "$d/login.keyring"
expect "check: login keyring" "ok keyring: login (default)" "$(checkline "$T/h")"
fresh; d=$T/h/.local/share/keyrings; mkdir -p "$d"; : > "$d/work.keyring"
expect "check: own keyrings, none the default" \
  "FAIL keyring: none is the default: apps like Chromium ask for a keyring password (pick one in Passwords and Keys) (human)" "$(checkline "$T/h")"

(( fail )) && { echo "default-keyring: FAILED"; exit 1; }
echo "default-keyring: all passed"
