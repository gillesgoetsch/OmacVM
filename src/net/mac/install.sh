#!/bin/bash
# The fast network for OmacVM.app (feature fast-network): omacvm-netd, a small
# root daemon that gives OmacVM.app's QEMU a vmnet interface (see
# omacvm-netd.c for what it may do). Started by launchd on demand.
#   src/net/mac/install.sh [--app APP]   install it, for the QEMU in APP (default:
#                                        the installed OmacVM.app), and for this
#                                        Mac user; asks for an administrator's
#                                        password (sudo)
#   src/net/mac/install.sh --status [--app APP]
#                                        ok | old (another build or another app) | missing
#   src/net/mac/install.sh --remove      not for this Mac user any more; off this
#                                        Mac when no other user has it (sudo)
# The daemon comes built and signed inside OmacVM.app (Contents/Library/
# LaunchServices, Developer ID for published apps): no Xcode needed. Apps from
# before that: built here from this source (needs Xcode's Command Line Tools).
# Accepted callers: processes of the Mac users who installed it (each user who
# runs this is added) that are QEMU signed with OmacVM's Developer ID (team
# 722686Y34B), or, for an app signed ad hoc (built from source), exactly that
# app's QEMU (its cdhash: install again after rebuilding the app).
# Exit codes: 0 done, 1 failed, 2 usage, 3 needs a person (no password to ask for).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LABEL=org.omacvm.netd
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist
SOCK=/var/run/$LABEL.sock
LOG=/var/log/$LABEL.log
TEAM='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "722686Y34B"'
DEVID='anchor apple generic and identifier "org.omacvm.app.qemu" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "722686Y34B"'

MODE=install APP=""
while (( $# )); do
  case $1 in
    --app) APP=$2; shift 2 ;;
    --status) MODE=status; shift ;;
    --remove) MODE=remove; shift ;;
    -h|--help) sed -n '2,19s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "net/mac/install.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

source "$HERE/../../lib/app.sh"   # app_bundle: the installed OmacVM.app

# The code requirement for APP's QEMU: the team for a Developer ID build, else
# that exact build.
requirement() {
  local q=$1/Contents/Resources/runtime/bin/OmacVM h
  [[ -x $q ]] || { echo "no QEMU in $1" >&2; return 1; }
  if codesign --verify -R="$DEVID" "$q" 2>/dev/null; then echo "$DEVID"; return 0; fi
  codesign --verify "$q" 2>/dev/null || { echo "$q has no valid signature" >&2; return 1; }
  h=$(codesign -dvvv "$q" 2>&1 | sed -n 's/^CDHash=//p' | head -1)
  [[ $h =~ ^[0-9a-f]{40}$ ]] || { echo "no cdhash for $q" >&2; return 1; }
  echo "cdhash H\"$h\""
}

# What this source builds: the source's hash, compiled into the binary.
VERSION=$(shasum -a 256 "$HERE/omacvm-netd.c" | cut -c1-16)
# The daemon inside APP (build-app.sh builds and signs it), if it has one.
bundled() { [[ -x $1/Contents/Library/LaunchServices/$LABEL ]] && echo "$1/Contents/Library/LaunchServices/$LABEL"; }

installed_req() {   # the requirement the installed daemon runs with
  /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$PLIST" 2>/dev/null
}
installed_users() {   # the uids it takes connections from, one per line
  plutil -extract ProgramArguments json -o - "$PLIST" 2>/dev/null |
    python3 -c 'import json, sys; a = json.load(sys.stdin); print("\n".join(a[i + 1] for i in range(len(a) - 1) if a[i] == "--user"))' 2>/dev/null
}

status() {
  [[ -x $BIN && -f $PLIST ]] || { echo missing; return 0; }
  local want h
  installed_users | grep -qx "$(id -u)" || { echo old; return 0; }
  if [[ -n $APP ]] || APP=$(app_bundle); then
    want=$(requirement "$APP" 2>/dev/null) || { echo old; return 0; }
    [[ $(installed_req) == "$want" ]] || { echo old; return 0; }
    # The app's own daemon, byte for byte; apps without one: this source's.
    if h=$(bundled "$APP"); then cmp -s "$h" "$BIN" || { echo old; return 0; }
    elif [[ $("$BIN" --version 2>/dev/null) != "$VERSION" ]]; then echo old; return 0; fi
  elif [[ $("$BIN" --version 2>/dev/null) != "$VERSION" ]]; then echo old; return 0; fi
  launchctl print "system/$LABEL" >/dev/null 2>&1 && [[ -S $SOCK ]] || { echo old; return 0; }
  echo ok
}

as_root() {   # SCRIPT ARGS...: one sudo for all of it
  if ! sudo -n true 2>/dev/null; then
    { : < /dev/tty; } 2>/dev/null || { echo "the fast network needs an administrator's password (sudo), and there is no terminal to ask in" >&2; exit 3; }
    echo "==> the fast network is a system service: macOS asks for your password (sudo)" >&2
  fi
  sudo /bin/bash -c "$@"
}

x() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; printf '%s' "${s//>/&gt;}"; }
# make_plist FILE REQUIREMENT UID...: the launchd job (at most 16 users, as
# many as the daemon takes).
make_plist() {
  local f=$1 req=$2 users; shift 2
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
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  plutil -lint -s "$f"
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ME=$(id -u)

case $MODE in
  status) status; exit 0 ;;
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
        install -o root -g wheel -m 644 "$1" '"$PLIST"'
        launchctl bootstrap system '"$PLIST" _ "$T/$LABEL.plist"
      echo "==> fast network: off for this Mac user (other users of this Mac still have it)"
      exit 0
    fi
    as_root 'launchctl bootout system/'"$LABEL"' 2>/dev/null || true; rm -f '"$PLIST $BIN $SOCK $LOG"
    echo "==> fast network removed"
    exit 0 ;;
esac

[[ -n $APP ]] || APP=$(app_bundle) || { echo "no OmacVM.app installed (in /Applications or ~/Applications)" >&2; exit 1; }
REQ=$(requirement "$APP") || exit 1
if [[ $(status) == ok ]]; then exit 0; fi
if h=$(bundled "$APP"); then
  # The app's daemon, checked on a copy (what is checked is what root
  # installs): a valid signature, and for a Developer ID app, OmacVM's team.
  cp "$h" "$T/omacvm-netd"
  codesign --verify --strict "$T/omacvm-netd" 2>/dev/null || { echo "$h has no valid signature" >&2; exit 1; }
  if [[ $REQ == "$DEVID" ]] && ! codesign --verify -R="$TEAM and identifier \"$LABEL\"" "$T/omacvm-netd" 2>/dev/null; then
    echo "$h is not signed with OmacVM's Developer ID" >&2; exit 1
  fi
else
  xcrun -f clang >/dev/null 2>&1 || { echo "this OmacVM.app has no fast network service built in, and building it here needs Xcode's Command Line Tools: xcode-select --install (or update the app)" >&2; exit 3; }
  xcrun clang -O2 -Wall -mmacosx-version-min=14.0 -DNETD_VERSION="\"$VERSION\"" -o "$T/omacvm-netd" "$HERE/omacvm-netd.c" \
    -framework vmnet -framework Security -framework CoreFoundation -lbsm
fi
# This user, and the ones it was installed for before.
# shellcheck disable=SC2046   # one uid per word
make_plist "$T/$LABEL.plist" "$REQ" "$ME" $(installed_users | grep -vx "$ME" || true)
as_root 'set -e
  install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
  launchctl bootout system/'"$LABEL"' 2>/dev/null || true
  install -o root -g wheel -m 755 "$1" '"$BIN"'
  install -o root -g wheel -m 644 "$2" '"$PLIST"'
  launchctl bootstrap system '"$PLIST" _ "$T/omacvm-netd" "$T/$LABEL.plist"
# launchd makes the socket a moment after the bootstrap.
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ $(status) == ok ]] && break; sleep 0.5; done
[[ $(status) == ok ]] || { echo "the fast network did not start (launchctl print system/$LABEL; $LOG)" >&2; exit 1; }
echo "==> fast network installed (omacvm-netd, for $(basename "$APP"))"
