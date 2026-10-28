#!/bin/bash
# The fast network for OmacVM.app (feature fast-network): omacvm-netd, a small
# root daemon that gives OmacVM.app's QEMU a vmnet interface (see
# omacvm-netd.c for what it may do). Started by launchd on demand.
#   src/net/mac/install.sh [--app APP]   install it, for the QEMU in APP (default:
#                                        the installed OmacVM.app), and for this
#                                        Mac user; asks for an administrator's
#                                        password (sudo)
#   src/net/mac/install.sh --status [--app APP]
#                                        ok (this app's daemon, or an older
#                                        build of the same protocol: it serves
#                                        this app as it is) | old (another
#                                        protocol, or for another app) |
#                                        down (installed, not loaded) | missing
#                                        (also: only for other Mac users) |
#                                        stopped (vmnet failed too often: it no
#                                        longer tries until a restart or install);
#                                        then "vpn-nat: IF..." while it does the
#                                        NAT for networks macOS's sharing does not
#                                        cover (a VPN connected later)
#   src/net/mac/install.sh --remove      not for this Mac user any more; off this
#                                        Mac when no other user has it (sudo)
#   src/net/mac/install.sh --trust [--app APP]
#                                        what an install would trust (no root):
#                                        "team TEAM" or "exact build", and why;
#                                        then where the daemon would come from:
#                                        "daemon: app", "daemon: source" or
#                                        "daemon: refused"
#   Add --bridged-interface enN to install, --status or --remove for a
#   separate LAN bridge instance. The shared service is never changed.
#   --interfaces lists vmnet's bridge-capable physical interface names
#   without administrator privileges.
# The daemon comes built and signed inside OmacVM.app (Contents/Library/
# LaunchServices, Developer ID for published apps): no Xcode needed. It is
# used only when OmacVM's release key vouches for the app's team (below) or
# this script is the app's own copy. Else (another app, nobody vouches for
# it), and for apps without one: built here from this source (needs Xcode's
# Command Line Tools); without them the install is refused: an app nobody
# vouches for never gets its own file run as root.
# Accepted callers: processes of the Mac users who installed it (each user who
# runs this is added) that are QEMU signed with the Developer ID team of the
# app's own QEMU (the app the person installs it for; a later app of another
# team asks again), when OmacVM's release key vouches for that team: the
# signed update feed of the app's release lists it (src/release/keys.py, main
# or spare key), or this script is the app's own copy (its Fast Network
# button: the app vouches for itself). "QEMU" is OmacVM's QEMU identifier: a
# release app's (org.omacvm.app.qemu); for a test build (OmacVM Test.app,
# org.omacvm.app.test.qemu) both, so later test builds need no new password.
# Else (an app signed ad hoc, built from source, or a Developer ID no feed
# lists): exactly that app's QEMU (its cdhash: install again after rebuilding
# the app).
# OMACVM_ADMIN_PROMPT=gui: macOS's own password dialog instead of sudo in a
# terminal (OmacVM.app's Fast Network button and its question before a start
# run this script that way: the person at the Mac asked for it); no dialog
# when sudo needs no password. OMACVM_ADMIN_PROMPT=none: never root, not even
# with a sudo that needs no password (jobs a VM asked for through the Bridge):
# exit 3 instead, the app asks on the Mac at the VM's next start.
# OMACVM_NETD_TEST_ROOT (--status and --remove only, for tests): the
# daemon's files under that folder instead of /.
# Exit codes: 0 done, 1 failed, 2 usage, 3 needs a person (no password to ask
# for), 4 the person cancelled the password dialog.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BASE_LABEL=org.omacvm.netd   # also the signed binary's identifier, for every instance
# Developer ID Application of TEAM, issued by Apple, with the identifier ID
# (the same text as before teams came from the app: installed daemons stay "ok").
devid() { devid_of "$1" "identifier \"$2\""; }   # TEAM ID
devid_of() {   # TEAM "identifier ..." (the identifier part)
  printf 'anchor apple generic and %s and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "%s"' "$2" "$1"
}
# The identifiers of the app's QEMU (build-app.sh): a release's, and the test
# identity's (build-app.sh --test-identity, OmacVM Test.app).
QEMU_ID=org.omacvm.app.qemu
TEST_QEMU_ID=org.omacvm.app.test.qemu
# Either QEMU of TEAM: what an install for a test build trusts, so a test Mac
# gives its password once for all test builds, and the release app of the
# same team is served too.
devid_qemus() { devid_of "$1" "(identifier \"$QEMU_ID\" or identifier \"$TEST_QEMU_ID\")"; }   # TEAM

MODE=install APP="" BRIDGED_INTERFACE=""
while (( $# )); do
  case $1 in
    --app) APP=$2; shift 2 ;;
    --bridged-interface)
      [[ $# -ge 2 && $2 =~ ^en[0-9]{1,4}$ ]] || { echo "net/mac/install.sh: --bridged-interface needs a physical interface name (enN)" >&2; exit 2; }
      BRIDGED_INTERFACE=$2; shift 2 ;;
    --interfaces) MODE=interfaces; shift ;;
    --status) MODE=status; shift ;;
    --remove) MODE=remove; shift ;;
    --trust) MODE=trust; shift ;;
    -h|--help) sed -n '2,61s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "net/mac/install.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
LABEL=$BASE_LABEL
[[ -z $BRIDGED_INTERFACE ]] || LABEL=$BASE_LABEL.bridge.$BRIDGED_INTERFACE
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist
SOCK=/var/run/$LABEL.sock
LOG=/var/log/$LABEL.log
STATE=/var/run/$LABEL.state
NAT=/var/run/$BASE_LABEL.nat
# Only the shared daemon owns this PF anchor and enable reference.
NAT_CLEAN=:
if [[ -z $BRIDGED_INTERFACE ]]; then
  NAT_CLEAN='if [ -f '"$NAT"' ]; then
    /sbin/pfctl -a com.apple/org.omacvm.netd -f /dev/null >/dev/null 2>&1 || true
    read -r _ t _ < '"$NAT"' || true
    case $t in ""|0|*[!0-9]*) ;; *) /sbin/pfctl -X "$t" >/dev/null 2>&1 || true ;; esac
    rm -f '"$NAT"'
  fi'
fi
if [[ $MODE == status || $MODE == remove ]] && [[ -n ${OMACVM_NETD_TEST_ROOT:-} ]]; then
  BIN=$OMACVM_NETD_TEST_ROOT$BIN PLIST=$OMACVM_NETD_TEST_ROOT$PLIST SOCK=$OMACVM_NETD_TEST_ROOT$SOCK
  LOG=$OMACVM_NETD_TEST_ROOT$LOG
  STATE=$OMACVM_NETD_TEST_ROOT$STATE NAT=$OMACVM_NETD_TEST_ROOT$NAT
fi

source "$HERE/../../lib/app.sh"   # app_bundle: the installed OmacVM.app; app_version, APP_DOWNLOADS
KEYS_PY=$HERE/../../release/keys.py

# "TEAM IDENTIFIER" of APP's QEMU, if it is a Developer ID build of OmacVM's
# QEMU (a release's or the test identity's); no other identifier counts.
qemu_signer() {
  local q=$1/Contents/Resources/runtime/bin/OmacVM d t i
  d=$(codesign -dv "$q" 2>&1)
  t=$(sed -n 's/^TeamIdentifier=//p' <<< "$d") i=$(sed -n 's/^Identifier=//p' <<< "$d")
  [[ $t =~ ^[A-Z0-9]{10}$ && ( $i == "$QEMU_ID" || $i == "$TEST_QEMU_ID" ) ]] &&
    codesign --verify -R="$(devid "$t" "$i")" "$q" 2>/dev/null && echo "$t $i"
}
# The Developer ID team APP's QEMU is signed with, if it is a Developer ID build.
qemu_team() { local s; s=$(qemu_signer "$1") && echo "${s% *}"; }

# The code requirement for exactly APP's QEMU (its cdhash).
hash_req() {
  local q=$1/Contents/Resources/runtime/bin/OmacVM h
  [[ -x $q ]] || { echo "no QEMU in $1" >&2; return 1; }
  codesign --verify "$q" 2>/dev/null || { echo "$q has no valid signature" >&2; return 1; }
  h=$(codesign -dvvv "$q" 2>&1 | sed -n 's/^CDHash=//p' | head -1)
  [[ $h =~ ^[0-9a-f]{40}$ ]] || { echo "no cdhash for $q" >&2; return 1; }
  echo "cdhash H\"$h\""
}
# The code requirement for the QEMU of any build of APP's team (Developer ID
# only): a release app's QEMU identifier (the text as before, installed
# daemons stay "ok"), or for a test build both identifiers of that team.
signer_req() {   # "TEAM IDENTIFIER" (qemu_signer)
  if [[ ${1#* } == "$QEMU_ID" ]]; then devid "${1% *}" "$QEMU_ID"; else devid_qemus "${1% *}"; fi
}
team_req() { local s; s=$(qemu_signer "$1") && signer_req "$s" && echo; }

# This script is APP's own copy (the app's Fast Network button runs that one).
own_copy() {
  local mine theirs
  mine=$(cd "$HERE" && pwd -P) && theirs=$(cd "$1/Contents/Resources/omacvm/src/net/mac" 2>/dev/null && pwd -P) && [[ $mine == "$theirs" ]]
}

# APP TEAM: the signed update feed of APP's release lists TEAM (OmacVM's
# release key, main or spare, vouches for it). Says why not on stderr.
feed_lists() {
  local v=$1 out t
  v=$(app_version "$1") && [[ $v =~ ^[0-9]{1,4}(\.[0-9]{1,4}){1,3}$ ]] || { echo "$1 has no release version" >&2; return 1; }
  if ! curl -fsL --max-time 30 -o "$T/feed.json" "$APP_DOWNLOADS/v$v/OmacVM-appcast.json" ||
     ! curl -fsL --max-time 30 -o "$T/feed.json.sig" "$APP_DOWNLOADS/v$v/OmacVM-appcast.json.sig"; then
    echo "no signed update feed for OmacVM.app $v (offline, or not a published release)" >&2; return 1
  fi
  out=$(python3 "$KEYS_PY" app-feed "$T/feed.json" "$v" 2>&1) || { echo "the update feed of OmacVM.app $v does not check out (${out#keys.py: })" >&2; return 1; }
  for t in ${out#* * }; do [[ $t == "$2" ]] && return 0; done
  echo "the signed update feed of OmacVM.app $v does not list team $2" >&2
  return 1
}

# What this source builds: the source's hash, compiled into the binary.
VERSION=$(shasum -a 256 "$HERE/omacvm-netd.c" | cut -c1-16)
# Its protocol (omacvm-netd.c NETD_PROTOCOL): an installed daemon of the same
# protocol serves this app as it is, so most app updates need no new install
# (and no password).
PROTOCOL=$(sed -n 's/^#define NETD_PROTOCOL  *\([0-9][0-9]*\).*/\1/p' "$HERE/omacvm-netd.c" | head -1)
[[ -n $PROTOCOL ]] || { echo "no NETD_PROTOCOL in $HERE/omacvm-netd.c" >&2; exit 1; }
BRIDGE_PROTOCOL=$(sed -n 's/^#define NETD_BRIDGE_PROTOCOL  *\([0-9][0-9]*\).*/\1/p' "$HERE/omacvm-netd.c" | head -1)
[[ -n $BRIDGE_PROTOCOL ]] || { echo "no NETD_BRIDGE_PROTOCOL in $HERE/omacvm-netd.c" >&2; exit 1; }
# Builds from before --protocol (they answer it with their usage): their
# source's hash and protocol. 3.0.1 to 3.0.3. Older ones are installed again:
# 3.0.0's (its VPN NAT does not follow a route change) and 2.9's (no VPN NAT).
KNOWN_BUILDS="f141e093f466a64a:1"
daemon_protocol() {   # BIN -> its protocol, nothing for a build it cannot tell
  local p v k
  p=$("$1" --protocol 2>/dev/null) && [[ $p =~ ^[0-9]{1,4}$ ]] && { echo "$p"; return 0; }
  v=$("$1" --version 2>/dev/null) || return 0
  for k in $KNOWN_BUILDS; do [[ ${k%:*} == "$v" ]] && { echo "${k#*:}"; return 0; }; done
  return 0
}
# The installed daemon is this source's build, or one of the same protocol.
serves() {
  if [[ -n $BRIDGED_INTERFACE ]]; then
    [[ $("$BIN" --bridge-protocol 2>/dev/null) == "$BRIDGE_PROTOCOL" ]] &&
      [[ $(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" 2>/dev/null |
        awk '{ sub(/^[ \t]+/, "") } b { print; exit } { b = $0 == "--bridged-interface" }') == "$BRIDGED_INTERFACE" ]]
  else
    [[ $("$BIN" --version 2>/dev/null) == "$VERSION" || $(daemon_protocol "$BIN") == "$PROTOCOL" ]]
  fi
}
# The daemon inside APP (build-app.sh builds and signs it), if it has one.
bundled() { [[ -x $1/Contents/Library/LaunchServices/$BASE_LABEL ]] && echo "$1/Contents/Library/LaunchServices/$BASE_LABEL"; }
# Its code's hash: the same daemon signed again (another app build of the
# same source) needs no new install, and no password.
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -1; }

installed_req() {   # the requirement the installed daemon runs with
  /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$PLIST" 2>/dev/null
}
installed_users() {   # the uids it takes connections from, one per line
  # (no python3: on a Mac without Xcode's tools it asks to install them)
  /usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" 2>/dev/null |
    awk '{ sub(/^[ \t]+/, "") } u && /^[0-9]+$/ { print } { u = $0 == "--user" }'
}

status() {
  [[ -x $BIN && -f $PLIST ]] || { echo missing; return 0; }
  local have h s
  if [[ -n $BRIDGED_INTERFACE ]] && ! serves; then echo old; return 0; fi
  installed_users | grep -qx "$(id -u)" || { echo missing; return 0; }   # only for other Mac users
  if [[ -n $APP ]] || APP=$(app_bundle); then
    # Installed for the team of the app's QEMU (vouched for then; for a
    # release app also the one for both its release and test QEMUs, installed
    # for a test build of that team), or for exactly this QEMU.
    have=$(installed_req) && [[ -n $have ]] || { echo old; return 0; }
    s=$(qemu_signer "$APP" 2>/dev/null) || s=""
    [[ -n $s && ( $have == "$(signer_req "$s")" || $have == "$(devid_qemus "${s% *}")" ) ]] ||
      [[ $have == "$(hash_req "$APP" 2>/dev/null)" ]] || { echo old; return 0; }
    # The app's own daemon (its code), one built from this source (an app
    # nobody vouches for, or one without a daemon), or an older build of the
    # same protocol (installed by an earlier version of the app).
    if ! { h=$(bundled "$APP") && [[ -n $(cdhash "$h") && $(cdhash "$h") == "$(cdhash "$BIN")" ]]; } &&
       ! serves; then echo old; return 0; fi
  elif ! serves; then echo old; return 0; fi
  launchctl print "system/$LABEL" >/dev/null 2>&1 && [[ -S $SOCK ]] || { echo down; return 0; }
  if stopped; then echo stopped; return 0; fi
  echo ok
}

# The daemon stopped starting vmnet after MAX_FAILURES failures in a row
# (its STATE: "boot failures pause live", this boot's only): yes/no.
MAX_FAILURES=$(sed -n 's/^#define MAX_FAILURES  *\([0-9][0-9]*\).*/\1/p' "$HERE/omacvm-netd.c" | head -1)
[[ -n $MAX_FAILURES ]] || { echo "no MAX_FAILURES in $HERE/omacvm-netd.c" >&2; exit 1; }
stopped() {
  local boot b f
  boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
  [[ -r $STATE ]] && read -r b f _ < "$STATE" || return 1
  [[ $b == "$boot" && $f =~ ^[0-9]+$ ]] && (( f >= MAX_FAILURES ))
}

# One argument in single quotes for /bin/sh.
shq() { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }
# SCRIPT ARGS... as one /bin/sh command line: bash -c SCRIPT ARGS (test.sh runs it).
root_cmd() { local cmd="/bin/bash -c" a; for a in "$@"; do cmd+=" $(shq "$a")"; done; printf '%s' "$cmd"; }
as_root() {   # SCRIPT ARGS...: one sudo (or one password dialog) for all of it
  if [[ ${OMACVM_ADMIN_PROMPT:-} == none ]]; then
    echo "the fast network's service needs an administrator's password on the Mac to install or update: OmacVM asks for it on the Mac at the VM's next start (or Update… under Fast network in OmacVM, or omacvm enable fast-network in Terminal)" >&2
    exit 3
  fi
  if [[ ${OMACVM_ADMIN_PROMPT:-} == gui ]]; then
    # sudo without a password (the person's own sudo setting): no dialog.
    if sudo -n true 2>/dev/null; then sudo -n /bin/bash -c "$@"; return; fi
    local out rc=0
    # The command goes in as an argument, never into AppleScript's text.
    out=$(/usr/bin/osascript - "$(root_cmd "$@")" 2>&1 <<'AS'
on run argv
  do shell script (item 1 of argv) with prompt "OmacVM wants to change its fast network service (omacvm-netd)." with administrator privileges
end run
AS
) || rc=$?
    if (( rc )); then
      [[ $out == *"-128"* ]] && { echo "cancelled: the fast network was not changed" >&2; exit 4; }
      printf '%s\n' "$out" >&2; exit 1
    fi
    [[ -z $out ]] || printf '%s\n' "$out" >&2
    return 0
  fi
  if ! sudo -n true 2>/dev/null; then
    { : < /dev/tty; } 2>/dev/null || { echo "the fast network's service needs an administrator's password to install or update, and there is no terminal to ask in: run omacvm enable fast-network in Terminal, or use Update… under Fast network in OmacVM" >&2; exit 3; }
    echo "==> the fast network is a system service: macOS asks for your password (sudo)" >&2
  fi
  sudo /bin/bash -c "$@"
}

x() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; printf '%s' "${s//>/&gt;}"; }
# make_plist FILE REQUIREMENT UID...: the launchd job (at most 16 users, as
# many as the daemon takes).
make_plist() {
  local f=$1 req=$2 users; shift 2
  local bridge_args=""
  [[ -z $BRIDGED_INTERFACE ]] || bridge_args="    <string>--bridged-interface</string><string>$BRIDGED_INTERFACE</string>"
  users=$(printf '%s\n' "$@" | grep -E '^[0-9]+$' | head -16 |
    while read -r u; do printf '    <string>--user</string><string>%s</string>\n' "$u"; done)
  cat > "$f" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>--requirement</string>
    <string>$(x "$req")</string>
$users
$bridge_args
  </array>
  <!-- launchd holds the socket and starts the daemon on the first connection;
       anyone may connect, the daemon checks the caller's user (- -user) and
       code signature (- -requirement). -->
  <key>Sockets</key>
  <dict>
    <key>omacvm-netd</key>
    <dict>
      <key>SockPathName</key><string>$SOCK</string>
      <key>SockPathMode</key><integer>438</integer>
    </dict>
  </dict>
  <!-- macOS 13+: Login Items names the app this background item belongs to. -->
  <key>AssociatedBundleIdentifiers</key>
  <array><string>org.omacvm.app</string></array>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  plutil -lint -s "$f"
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ME=$(id -u)

# Its VPN NAT, this boot's only: "vpn-nat: IF..." (the networks it translates
# the fast network's addresses on itself, as macOS's sharing does not), or nothing.
nat_status() {
  local boot b t ifs
  [[ -z $BRIDGED_INTERFACE ]] || return 0
  boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
  [[ -r $NAT ]] && read -r b t ifs < "$NAT" || return 0
  [[ $b == "$boot" && -n $ifs && $ifs =~ ^[a-z0-9\ ]+$ ]] && echo "vpn-nat: $ifs"
  return 0
}

# What the QEMU (REQ) and the daemon (DREQ) must satisfy: for a Developer ID
# app whose team OmacVM's release key vouches for, that team (and each one's
# identifier); else exactly the files checked here, by their cdhash (an app
# built from source, a daemon built here, or a team no signed feed lists: a
# fake app signed by someone else's Developer ID gets no more than its own
# exact files). Any file can be signed ad hoc, so "a valid signature" alone
# would let a swapped file through. DREQ stays empty for the cdhash case
# (set from the daemon file below).
decide() {
  REQ=$(hash_req "$APP") || exit 1
  DREQ=""
  if QTEAM=$(qemu_team "$APP"); then
    if own_copy "$APP" || feed_lists "$APP" "$QTEAM"; then
      REQ=$(team_req "$APP") && DREQ=$(devid "$QTEAM" "$BASE_LABEL")
      return 0
    fi
    echo "==> not trusting all of team $QTEAM (above): the fast network takes only this exact build of $(basename "$APP")'s QEMU" >&2
  fi
  QTEAM=""
}

# Where the daemon comes from (after decide): "app" (the one inside APP) when
# the release key vouches for APP's team or this is APP's own copy (the app
# vouches for itself); else "source" (built here from this source) when
# Xcode's Command Line Tools are there; else "refused".
bundled_usable() {
  local h
  h=$(bundled "$APP") || return 1
  [[ -z $BRIDGED_INTERFACE ]] || [[ $("$h" --bridge-protocol 2>/dev/null) == "$BRIDGE_PROTOCOL" ]]
}
have_clang() { xcode-select -p >/dev/null 2>&1 && xcrun -f clang >/dev/null 2>&1; }
daemon_from() {
  if bundled_usable && { [[ -n $QTEAM ]] || own_copy "$APP"; }; then echo app
  elif have_clang; then echo source
  else echo refused; fi
}

case $MODE in
  interfaces)
    [[ -z $BRIDGED_INTERFACE ]] || { echo "--interfaces does not take --bridged-interface" >&2; exit 2; }
    # Listing grants no privileges and runs no service. Prefer a built helper,
    # so published apps do not need Command Line Tools just to show a picker.
    h=""
    if [[ -n $APP ]] || APP=$(app_bundle); then h=$(bundled "$APP") || h=""; fi
    if [[ -z $h || $("$h" --bridge-protocol 2>/dev/null) != "$BRIDGE_PROTOCOL" ]]; then
      h=/Library/PrivilegedHelperTools/$BASE_LABEL
      if [[ ! -x $h || $("$h" --bridge-protocol 2>/dev/null) != "$BRIDGE_PROTOCOL" ]]; then
        have_clang || { echo "listing bridge interfaces needs a current OmacVM.app or Xcode Command Line Tools" >&2; exit 3; }
        h=$T/omacvm-netd
        xcrun clang -O2 -Wall -mmacosx-version-min=14.0 -o "$h" "$HERE/omacvm-netd.c" \
          -framework vmnet -framework Security -framework CoreFoundation -lbsm
      fi
    fi
    "$h" --interfaces; exit $? ;;
  status) status; nat_status; exit 0 ;;
  trust)
    [[ -n $APP ]] || APP=$(app_bundle) || { echo "no OmacVM.app installed (in /Applications or ~/Applications)" >&2; exit 1; }
    decide
    if [[ -n $QTEAM ]]; then echo "team $QTEAM"; else echo "exact build"; fi
    echo "daemon: $(daemon_from)"
    exit 0 ;;
  remove)
    [[ -e $BIN || -e $PLIST ]] || exit 0
    others=$(installed_users | grep -vx "$ME" || true)
    if [[ -n $others ]]; then
      # Other Mac users still have it: only this one goes.
      installed_users | grep -qx "$ME" || exit 0
      req=$(installed_req) && [[ -n $req ]] || { echo "omacvm-netd's settings are unreadable: not changed" >&2; exit 1; }
      # shellcheck disable=SC2086   # one uid per word
      make_plist "$T/$LABEL.plist" "$req" $others
      as_root 'set -e
        launchctl bootout system/'"$LABEL"' 2>/dev/null || true
        '"$NAT_CLEAN"'
        install -o root -g wheel -m 644 "$1" '"$PLIST"'
        launchctl bootstrap system '"$PLIST" _ "$T/$LABEL.plist"
      echo "==> fast network: off for this Mac user (other users of this Mac still have it)"
      exit 0
    fi
    as_root 'launchctl bootout system/'"$LABEL"' 2>/dev/null || true
      '"$NAT_CLEAN"'
      rm -f '"$PLIST $BIN $SOCK $LOG $STATE"
    echo "==> fast network removed"
    exit 0 ;;
esac

[[ -n $APP ]] || APP=$(app_bundle) || { echo "no OmacVM.app installed (in /Applications or ~/Applications)" >&2; exit 1; }
hash_req "$APP" > /dev/null || exit 1
case $(status) in
  ok) exit 0 ;;
  stopped)
    # Installing again ends a stop after too many vmnet failures (omacvm check says so).
    as_root 'rm -f '"$STATE"'; launchctl kickstart -k system/'"$LABEL"' 2>/dev/null || true'
    echo "==> fast network: vmnet is tried again"
    exit 0 ;;
esac
decide
FROM=$(daemon_from)
if [[ $FROM == refused && -n $BRIDGED_INTERFACE ]] && ! bundled_usable; then
  echo "this app's network service does not support the required bridge protocol, and building it here needs Xcode's Command Line Tools: update OmacVM.app or install the tools (xcode-select --install)" >&2
  exit 3
fi
if [[ $FROM == refused ]] && bundled "$APP" >/dev/null; then
  echo "the fast network service inside $(basename "$APP") is not run as root: OmacVM's release key does not vouch for this app (no signed update feed lists its team) and this is not the app's own copy of install.sh. Use the app's Fast Network button, or install Xcode's Command Line Tools (xcode-select --install) to build the service from this source" >&2
  exit 3
fi
if [[ $FROM == app ]]; then
  h=$(bundled "$APP")
  # The app's daemon, checked on a copy first (a clear message), and again
  # as root on the installed file before launchd may run it.
  cp "$h" "$T/omacvm-netd"
  codesign --verify --strict "$T/omacvm-netd" 2>/dev/null || { echo "$h has no valid signature" >&2; exit 1; }
  if [[ -n $DREQ ]] && ! codesign --verify -R="$DREQ" "$T/omacvm-netd" 2>/dev/null; then
    echo "$h is not signed with the Developer ID of team $QTEAM, as the app's QEMU is" >&2; exit 1
  fi
else
  [[ $FROM == source ]] || { echo "this OmacVM.app has no fast network service built in, and building it here needs Xcode's Command Line Tools: xcode-select --install (or update the app)" >&2; exit 3; }
  # A locally compiled fallback is not Developer ID signed by the app's team.
  # Pin its exact compiled code below instead of carrying the bundled requirement.
  DREQ=""
  xcrun clang -O2 -Wall -mmacosx-version-min=14.0 -DNETD_VERSION="\"$VERSION\"" -o "$T/omacvm-netd" "$HERE/omacvm-netd.c" \
    -framework vmnet -framework Security -framework CoreFoundation -lbsm
fi
if [[ -n $BRIDGED_INTERFACE ]]; then
  [[ $("$T/omacvm-netd" --bridge-protocol 2>/dev/null) == "$BRIDGE_PROTOCOL" ]] || {
    echo "this app's network service does not support bridging: update OmacVM.app" >&2; exit 3;
  }
  "$T/omacvm-netd" --interfaces | grep -Fxq "$BRIDGED_INTERFACE" || {
    echo "unsupported bridged interface $BRIDGED_INTERFACE (see --interfaces)" >&2; exit 1;
  }
fi
if [[ -z $DREQ ]]; then
  h=$(cdhash "$T/omacvm-netd")
  [[ $h =~ ^[0-9a-f]{40}$ ]] || { echo "no cdhash for omacvm-netd" >&2; exit 1; }
  DREQ="cdhash H\"$h\""
fi
# This user, and the ones it was installed for before.
# shellcheck disable=SC2046   # one uid per word
make_plist "$T/$LABEL.plist" "$REQ" "$ME" $(installed_users | grep -vx "$ME" || true)
# The copy in $T is this user's: another of their processes could swap it after
# the checks above. So root checks the file it installed (root's now) and only
# then lets launchd run it. A new install also ends a vmnet back-off.
as_root 'set -e
  install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
  launchctl bootout system/'"$LABEL"' 2>/dev/null || true
  '"$NAT_CLEAN"'
  install -o root -g wheel -m 755 "$1" '"$BIN"'
  if ! /usr/bin/codesign --verify --strict ${3:+-R="$3"} '"$BIN"' 2>/dev/null; then
    rm -f '"$BIN"'; echo "the installed omacvm-netd failed its signature check: removed" >&2; exit 1
  fi
  if [ -n "$4" ] && ! '"$BIN"' --interfaces | /usr/bin/grep -Fxq "$4"; then
    rm -f '"$BIN"'; echo "the selected interface does not support bridging" >&2; exit 1
  fi
  install -o root -g wheel -m 644 "$2" '"$PLIST"'
  rm -f '"$STATE"'
  launchctl bootstrap system '"$PLIST" _ "$T/omacvm-netd" "$T/$LABEL.plist" "$DREQ" "$BRIDGED_INTERFACE"
# launchd makes the socket a moment after the bootstrap.
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ $(status) == ok ]] && break; sleep 0.5; done
[[ $(status) == ok ]] || { echo "the fast network did not start (launchctl print system/$LABEL; $LOG)" >&2; exit 1; }
echo "==> fast network installed (omacvm-netd, for $(basename "$APP"))"
