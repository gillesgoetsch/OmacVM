#!/bin/bash
# OmacVM, Mac side: Bridge (Wi-Fi, audio, media keys, display, wallpaper),
# Gestures (trackpad, scroll momentum, Cmd as Super on UTM), clipboard (VM -> Mac),
# Omanotch (the bar beside the notch, src/omanotch).
# Idempotent; `omacvm apply` runs it with what the VM's features need.
#   src/mac/install.sh [--no-bridge] [--skip-gestures | --keys-only] [--skip-clip] [--omanotch] [--force]
#                      [--force-app NAME]... [--skip-failed [--retry-app NAME]...] [--quiet]
# --no-bridge leaves OmacVM Bridge out (one already installed stays, other VMs
# may use it). --skip-gestures leaves OmacVM Gestures out (likewise).
# --skip-clip leaves the clipboard helper out (only Parallels VMs use it;
# likewise kept when already installed).
# --omanotch installs Omanotch too (without it, one already installed stays as
# it is).
# --keys-only installs Gestures keys-only for every VM: macOS keeps its trackpad
# gestures, and on UTM Cmd still reaches Omarchy as Super. (Without it, each
# VM chooses for itself: gestures and scroll momentum are VM features.)
# An app whose sources and options did not change since it was installed is
# left as it is (--force rebuilds it; --force-app "OmacVM Gestures" only that
# one, for a repair); --quiet only reports what changed.
# An app that does not build or install is named (after a failed build the
# one installed before keeps running), and the others go on; the run then ends with exit code 5
# (the names in the file $OMACVM_MAC_FAILED_FILE, one per line, when set).
# --skip-failed: an app that failed with these same sources is not tried
# again (the control centre's jobs: a broken build does not run on every
# switch), except the --retry-app ones; omacvm update always tries again.
# macOS asks for Location Services (Bridge) and Accessibility + Input Monitoring
# (Bridge, Gestures) the first time.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
BRIDGE=1; GESTURES=1; CLIP=1; NOTCH=0; FORCE=0; QUIET=0; FORCE_APPS="|"; SKIP_FAILED=0; RETRY_APPS="|"
while (( $# )); do
  case $1 in
    --no-bridge) BRIDGE=0 ;;
    --keys-only) GESTURES=0 ;;
    --skip-gestures) GESTURES=-1 ;;
    --skip-clip) CLIP=0 ;;
    --omanotch) NOTCH=1 ;;
    --force) FORCE=1 ;;
    --force-app) FORCE_APPS+="${2:?--force-app NAME}|"; shift ;;
    --skip-failed) SKIP_FAILED=1 ;;
    --retry-app) RETRY_APPS+="${2:?--retry-app NAME}|"; shift ;;
    --quiet) QUIET=1 ;;
    *) echo "src/mac/install.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
# The test identity (OMACVM_TEST_IDENTITY=1, app/scripts/build-app.sh
# --test-identity): its helpers are the ones inside "OmacVM Test.app", on their
# own ports and folders, granted once. Nothing is built or installed and no
# LaunchAgent is touched (those are the installed helpers): the helpers this
# run wants are started when they are not running yet, and that is all.
if [[ ${OMACVM_TEST_IDENTITY:-} == 1 ]]; then
  H=${OMACVM_HELPERS:-$HOME/Applications/OmacVM Test.app/Contents/Helpers}
  test_helper() {   # NAME LOG: start "NAME.app" from H (output to ~/Library/Logs/LOG) unless it runs
    local app="$H/$1.app"
    [[ -d $app ]] || { echo "src/mac/install.sh: test identity: $app is missing" >&2; return 1; }
    pgrep -af "$app/Contents/MacOS/" >/dev/null && return 0   # -a: the Bridge may be our parent
    open -g -n --stdout ~/Library/Logs/"$2" --stderr ~/Library/Logs/"$2" "$app" && echo "==> test identity: started $1"
  }
  rc=0
  (( BRIDGE )) && { test_helper "OmacVM Test Bridge" omacvm-test-bridge.log || rc=5; }
  (( GESTURES != -1 )) && { test_helper "OmacVM Test Gestures" omacvm-test-gestures.log || rc=5; }
  (( CLIP || NOTCH )) && echo "==> test identity: no test clipboard helper or Omanotch (left out; a test Omanotch listens on 47911: src/omanotch/README.md)"
  exit "$rc"
fi
STAMPS=~/Library/Application\ Support/omacvm/installed
mkdir -p "$HOME/.local/share/omacvm/clip" "$STAMPS"
# Up to 2.7, Gestures kept its list of VMs without a token here; nothing reads it now.
rm -f ~/Library/Application\ Support/omacvm/gestures-legacy{,.new}

# install_app NAME LAUNCHD_LABEL DIR [BUNDLE [ARGS...]]: DIR/install.sh unless
# the same sources and options are already installed and running. BUNDLE
# (OmacVMBridge.app, OmacVMGestures.app): installed from OmacVM.app's signed
# copy when the app has one built from these sources (lib/helpers.sh).
install_app() {
  local name=$1 label=$2 dir=$3 bundle=${4:-}; shift 3; (( $# )) && shift
  local sum pre="" before
  [[ -n $bundle ]] && pre=$(helpers_prebuilt "$R" "$dir" "$bundle")
  # Paths relative to src/, so another copy of the same OmacVM matches too.
  # The prebuilt copy's signature counts too: from built here to the app's
  # signed copy is a change.
  sum=$( { (cd "$R" && find "$dir" icon lib/sign.sh -type f -not -path '*/build/*' -not -name .DS_Store -print0 |
            sort -z | xargs -0 shasum); echo "args: $*"
           if [[ -n $pre ]]; then echo "prebuilt: $(shasum "$pre/Contents/_CodeSignature/CodeResources" "$pre"/Contents/MacOS/* | cut -c1-40)"; fi
         } | shasum | cut -c1-16)
  if (( ! FORCE )) && [[ $FORCE_APPS != *"|$name|"* ]]; then
    if [[ $(cat "$STAMPS/$name" 2>/dev/null) == "$sum" ]] && launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
      (( QUIET )) || echo "$name: up to date"
      return 0
    fi
    if (( SKIP_FAILED )) && [[ $RETRY_APPS != *"|$name|"* ]] && [[ $(cat "$STAMPS/$name.failed" 2>/dev/null) == "$sum" ]]; then
      echo "$name: did not build last time, not tried again (omacvm update on the Mac tries again)" >&2
      FAILED+=("$name")
      return 0
    fi
  fi
  printf '\033[1;32m==>\033[0m \033[1m%s on the Mac\033[0m%s\n' "$name" "${pre:+ (signed, from OmacVM.app)}"
  [[ -n $bundle ]] && before=$(helpers_team "$HOME/Applications/$bundle")
  # Each app's install.sh builds before it replaces anything: one that fails
  # leaves the installed one running.
  local ok=1
  if [[ -n $pre ]]; then "$R/$dir/install.sh" --prebuilt "$pre" "$@" || ok=0; else "$R/$dir/install.sh" "$@" || ok=0; fi
  if (( ! ok )); then
    echo "$sum" > "$STAMPS/$name.failed"
    FAILED+=("$name")
    printf '\033[1;31merror:\033[0m %s did not build or install (see above); when only the build failed, the one installed before keeps running\n' "$name" >&2
    return 0
  fi
  rm -f "$STAMPS/$name.failed"
  # No stamp yet: a first install, which macOS asks permissions for. Another
  # signature (built here -> OmacVM's Developer ID) is new to macOS too: it
  # asks once more, then keeps the grants across updates.
  if [[ ! -e $STAMPS/$name ]]; then INSTALLED+=("$name")
  elif [[ -n $bundle && -n $before && $before != "$(helpers_team "$HOME/Applications/$bundle")" ]]; then
    INSTALLED+=("$name"); RESIGNED=1
  fi
  echo "$sum" > "$STAMPS/$name"
}
INSTALLED=()   # installed for the first time (an update keeps the permissions)
RESIGNED=0     # one now has another signature (the app's signed copy)
FAILED=()      # did not build or install
source "$R/lib/mac.sh"
source "$R/lib/app.sh"
source "$R/lib/helpers.sh"
# The omacvm the Bridge runs for the control centre's requests (control.swift
# checks it belongs to this user and nobody else can write it): only the
# installed checkout (cli_for_bridge). OmacVM.app's copy (OMACVM_APP_CLI, a
# copy of it runs this) is set by apply.sh: never this temporary copy.
me="$(cd "$R/.." && pwd -P)/omacvm"
if [[ -z ${OMACVM_APP_CLI:-} && -f $me ]] && cli_for_bridge "$me"; then
  (umask 077; printf '%s\n' "$me" > ~/Library/Application\ Support/omacvm/cli)
fi
# The token first: a Bridge starting without one makes its own, and two at
# once could end up with the file holding another token than the Bridge.
(( BRIDGE || GESTURES != -1 )) && bridge_token_ensure
(( BRIDGE )) && install_app "OmacVM Bridge" org.omacvm.bridge bridge/mac OmacVMBridge.app
# Gestures lets a VM in only when its daemon proves it knows the Bridge's
# token (made here when the Bridge is not installed).
case $GESTURES in
  1) install_app "OmacVM Gestures" org.omacvm.gestures gestures/mac OmacVMGestures.app ;;
  0) install_app "OmacVM Gestures" org.omacvm.gestures gestures/mac OmacVMGestures.app --keys-only ;;
esac
(( CLIP )) && install_app "OmacVM clipboard" org.omacvm.clip-in clipboard/mac
# Omanotch's own installer (it builds the app and starts it at login).
(( NOTCH )) && install_app "Omanotch" ch.gillesgoetsch.omanotch omanotch/mac
# The permissions macOS asks for now, once per app (they stay with later updates).
if [[ " ${INSTALLED[*]:-} " == *" OmacVM Gestures "* || " ${INSTALLED[*]:-} " == *" OmacVM Bridge "* ]]; then
  printf '\n  \033[1mmacOS asks for permissions now (once): please allow them.\033[0m\n'
  (( RESIGNED )) && printf '  (The helpers are now signed with OmacVM'"'"'s Developer ID: macOS asks once more, then keeps\n   the permissions across updates. An older "OmacVM Bridge"/"OmacVM Gestures" entry there can go: select it, -.)\n'
  printf '  In System Settings > Privacy & Security, turn on:\n'
  [[ " ${INSTALLED[*]} " == *" OmacVM Gestures "* ]] &&
    printf '    * Accessibility and Input Monitoring: OmacVM Gestures (trackpad gestures, scroll momentum, Cmd keys)\n'
  [[ " ${INSTALLED[*]} " == *" OmacVM Bridge "* ]] &&
    printf '    * Accessibility and Input Monitoring: OmacVM Bridge (media keys, brightness keys);\n      Location Services: OmacVM Bridge (Wi-Fi names); Bluetooth: OmacVM Bridge (your Bluetooth devices)\n'
  printf '  Until then those features wait; the build goes on either way.\n\n'
fi
if (( ${#FAILED[@]} )); then
  [[ -n ${OMACVM_MAC_FAILED_FILE:-} ]] && printf '%s\n' "${FAILED[@]}" > "$OMACVM_MAC_FAILED_FILE"
  echo "src/mac/install.sh: not installed: $(printf '%s, ' "${FAILED[@]}" | sed 's/, $//')" >&2
  exit 5
fi
(( QUIET )) || echo "OmacVM Mac side installed"
