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

# The app's "Start in" not Window (app-wide; Settings.startFullScreen, default on).
notch_app_full_screen() {
  [[ $(defaults read "${APP_ID:-org.omacvm.app}" startFullScreen 2>/dev/null) != 0 ]]
}

# What the next start does, as the app's NotchArea.start says it, without the
# geometry: "fullpanel" or "native" / "native (why)". MAC_NOTCH: notch|none
# (mac_tool mac-notch), FULL: 1|0 (notch_app_full_screen).
notch_next_start() {   # DIR MAC_NOTCH FULL
  [[ $(notch_choice "$1") == fullpanel ]] || { echo native; return; }
  if ! notch_guest_ready "$1"; then
    echo "native (including notch is set, but the VM is not ready for it: Omanotch on, then Update VM or omacvm apply)"
  elif [[ $3 != 1 ]]; then
    echo "native (including notch is set, but the app starts VMs in a window)"
  elif [[ $2 != notch ]]; then
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
