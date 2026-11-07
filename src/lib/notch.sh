# OmacVM.app's notch setting on the Mac side (omacvm notch, omacvm check, the
# control centre through the Bridge): the same rules as
# app/app/Sources/OmacVMFeatures/NotchArea.swift, which the app uses at each
# VM start (src/tests/notch-setting.sh keeps them equal).
# Native (the default): full screen below the camera housing, Omanotch streams
# the bar into the strip. FullPanel (experimental, #339): QEMU's window covers
# the strip too and the VM draws its own bar there; Omanotch is off for such a
# start. A VM folder's `notch-mode` file: "fullpanel"; none (or anything else)
# is native. `fullpanel-ready` (omacvm apply): the VM's side can do it.

NOTCH_FILE=notch-mode
NOTCH_READY_FILE=fullpanel-ready
NOTCH_LOG_PREFIX="OmacVM: notch area: "   # NotchArea.logPrefix

notch_choice() {   # DIR -> native|fullpanel
  local c
  c=$(tr -d "[:space:]" 2>/dev/null < "$1/$NOTCH_FILE") || c=""
  [[ $c == fullpanel ]] && echo fullpanel || echo native
}

notch_title() {   # MODE (NotchMode.title)
  case $1 in fullpanel) echo "Full screen including notch, no Omanotch needed (experimental)" ;; *) echo "Full screen, notch via Omanotch" ;; esac
}

notch_set() {   # DIR MODE: fullpanel writes the file, native removes it
  case $2 in
    fullpanel) printf 'fullpanel\n' > "$1/$NOTCH_FILE.new" && mv -f "$1/$NOTCH_FILE.new" "$1/$NOTCH_FILE" ;;
    native) rm -f "$1/$NOTCH_FILE" ;;
    *) return 2 ;;
  esac
}

# The VM's side can do it: apply wrote fullpanel-ready, and Omanotch (whose
# bar it uses) is not off in the VM's features (NotchArea.guestReady).
notch_guest_ready() {   # DIR
  [[ -e $1/$NOTCH_READY_FILE ]] || return 1
  local f
  f=$(cat "$1/features" 2>/dev/null) || f=""
  [[ " $(printf '%s' "$f" | tr '\n\t' '  ') " != *" omanotch=off "* ]]
}

# Skip the notch (NotchSkip in NotchArea.swift; off by default): on the bar in
# the notch strip, items that do not fit on their side of the camera housing
# continue on its other side. A VM folder's `notch-skip` file: "on"; none (or
# anything else) is off. `notch-skip-ready` (omacvm apply): the VM's Omanotch
# bar can do it. The app gives it to the VM at each start and, while the VM
# runs, as soon as the file changes.
NOTCH_SKIP_FILE=notch-skip
NOTCH_SKIP_READY_FILE=notch-skip-ready

notch_skip() {   # DIR -> on|off
  local c
  c=$(tr -d "[:space:]" 2>/dev/null < "$1/$NOTCH_SKIP_FILE") || c=""
  [[ $c == on ]] && echo on || echo off
}

notch_skip_set() {   # DIR on|off: on writes the file, off removes it
  case $2 in
    on) printf 'on\n' > "$1/$NOTCH_SKIP_FILE.new" && mv -f "$1/$NOTCH_SKIP_FILE.new" "$1/$NOTCH_SKIP_FILE" ;;
    off) rm -f "$1/$NOTCH_SKIP_FILE" ;;
    *) return 2 ;;
  esac
}

# The VM's bar can do it: apply wrote notch-skip-ready, and Omanotch (whose
# bar it is) is not off in the VM's features (NotchSkip.guestReady).
notch_skip_ready() {   # DIR
  [[ -e $1/$NOTCH_SKIP_READY_FILE ]] || return 1
  local f
  f=$(cat "$1/features" 2>/dev/null) || f=""
  [[ " $(printf '%s' "$f" | tr '\n\t' '  ') " != *" omanotch=off "* ]]
}

# The app's "Start in" not Window (app-wide; Settings.startFullScreen, default on).
notch_app_full_screen() {
  [[ $(defaults read "${APP_ID:-org.omacvm.app}" startFullScreen 2>/dev/null) != 0 ]]
}

# The app's "Keep the Dock and hot corners away" (app-wide; Settings.keepDockAway,
# default on; QEMU's immersive=on). With it macOS's menu bar stays hidden in
# full screen, also with "Always show the menu bar in full screen" (#356,
# work/tracks/fullpanel-menubar.md).
notch_keep_dock_away() {
  [[ $(defaults read "${APP_ID:-org.omacvm.app}" keepDockAway 2>/dev/null) != 0 ]]
}

# macOS's "Always show the menu bar in full screen" is in the way of FullPanel
# (the menu bar over the strip): only without Keep the Dock away. Then QEMU
# uses normal full screen (omacvm_fp_menu_bar_in_the_way in
# omacvm-cocoa-fullpanel-logic.patch).
notch_menu_bar_in_the_way() {
  [[ $(defaults read NSGlobalDomain AppleMenuBarVisibleInFullscreen 2>/dev/null) == 1 ]] && ! notch_keep_dock_away
}

# The built-in display's notch as last measured on this Mac, kept by the app
# for starts with the lid closed (#716; NotchHousing in NotchArea.swift): the
# app's `builtinNotch` setting, "<mac> LxRxHxWxD", <mac> = notch_mac_key.
NOTCH_REMEMBERED_KEY=builtinNotch

# This Mac's key (NotchHousing.macKey): the first 16 hex digits of the SHA-256
# of its IOPlatformUUID (or of UUID).
notch_mac_key() {   # [UUID]
  local u=${1:-}
  [[ -n $u ]] || u=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null |
    LC_ALL=C sed -n 's/.*"IOPlatformUUID" = "\([^"]*\)".*/\1/p' | head -1)
  [[ -n $u ]] || return 1
  printf '%s' "$u" | shasum -a 256 | cut -c1-16
}

# The app's remembered notch is this Mac's and one a MacBook can have
# (NotchHousing.remembered, NotchGeometry.valid).
notch_remembered() {   # [STORED]
  local v k g
  if (( $# )); then v=$1; else v=$(defaults read "${APP_ID:-org.omacvm.app}" "$NOTCH_REMEMBERED_KEY" 2>/dev/null) || v=""; fi
  k=$(notch_mac_key) || return 1
  [[ ${v%% *} == "$k" ]] || return 1
  g=${v#* }
  [[ $g =~ ^[0-9]+(\.[0-9]*)?(x[0-9]+(\.[0-9]*)?){4}$ ]] || return 1
  printf '%s\n' "$g" | LC_ALL=C awk -F x '{ l = $1 + 0; r = $2 + 0; h = $3 + 0; w = $4 + 0; d = $5 + 0
    exit !(l > 0 && r > l && r < w && r - l < w / 3 && h >= 10 && h <= 100 && w >= 800 && d > h * 5) }'
}

# This Mac's notch for the next start, as the app's Mac.notch (MacNotch):
# notch (the built-in display has one now), remembered (that display is off,
# the lid closed: the notch the app measured last on this Mac) or none (no
# notch now: a Mac without one, the built-in display below the notch or
# mirrored, or off with nothing remembered).
notch_mac_state() {
  case $(mac_tool mac-notch builtin 2>/dev/null) in
    notch) echo notch ;;
    off) notch_remembered && echo remembered || echo none ;;
    *) echo none ;;
  esac
}

# What the next start does, as the app's NotchArea.start says it, without the
# geometry: "fullpanel" or "native" / "native (why)". MAC_NOTCH:
# notch|remembered|none (notch_mac_state), FULL: 1|0 (notch_app_full_screen).
notch_next_start() {   # DIR MAC_NOTCH FULL
  [[ $(notch_choice "$1") == fullpanel ]] || { echo native; return; }
  if ! notch_guest_ready "$1"; then
    echo "native (including notch is set, but the VM is not ready for it: Omanotch on, then Update VM or omacvm apply)"
  elif [[ $3 != 1 ]]; then
    echo "native (including notch is set, but the app starts VMs in a window)"
  elif [[ $2 != notch && $2 != remembered ]]; then
    echo "native (including notch is set, but this Mac's built-in display has no notch now)"
  else
    echo fullpanel
  fi
}

notch_this_start() {   # DIR -> the last start's record ("" when not known)
  [[ -r $1/logs/qemu.log ]] || return 0
  sed -n "s/^$NOTCH_LOG_PREFIX//p" "$1/logs/qemu.log" | tail -1
}

# The VM's current (or last) start was a FullPanel start: Omanotch has no link.
notch_fullpanel_this_start() {   # DIR
  [[ $(notch_this_start "$1") == fullpanel* ]]
}
