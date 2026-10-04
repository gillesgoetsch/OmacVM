#!/bin/bash
# OmacVM.app: Chrome, Chromium and Brave encode WebRTC video (camera, screen
# sharing) on the Mac's media engine. Run as root: browser-video-encode.sh <user> on|off
# Chrome's VA-API encoder is off on Linux unless both features are enabled.
# Chrome takes only the LAST --enable-features of its command line, and
# Omarchy's flags files already have one, so a line of our own would be lost:
# the features go into the last --enable-features line the browser reads
# (or a new line when there is none). A marker remembers what OmacVM added,
# so "off" never removes a feature the user set.
# Firefox (157) has no VA-API encoder on Linux: nothing to switch there.
set -euo pipefail
U=${1:?usage: browser-video-encode.sh <user> on|off}; ON=${2:?on|off}
H=$(getent passwd "$U" | cut -d: -f6)
FEATURES=(AcceleratedVideoEncoder VaapiVideoEncoder)
MARK=$H/.local/state/omacvm/video-encode-flags   # lines: FILE<TAB>FEATURE

# The files each browser reads, in order; the user's file comes last.
# Chrome: /etc/chrome-flags.conf through src/bench/install-chrome.sh's
# launcher, ~/.config/chrome-flags.conf through it and the AUR package's.
# Brave: only ~/.config/brave-flags.conf.
browser_files() {
  case $1 in
    chromium) echo /etc/chromium-flags.conf "$H/.config/chromium-flags.conf" ;;
    chrome)   echo /etc/chrome-flags.conf "$H/.config/chrome-flags.conf" ;;
    brave)    echo "$H/.config/brave-flags.conf" ;;
  esac
}

installed() {
  case $1 in
    chromium) command -v chromium ;;
    chrome)   command -v google-chrome-stable || command -v google-chrome ;;
    brave)    command -v brave ;;
  esac >/dev/null 2>&1
}

has_feature() {   # FILE FEATURE: on any --enable-features line
  grep -E -- '^[[:space:]]*--enable-features=' "$1" 2>/dev/null |
    sed 's/^[[:space:]]*--enable-features=//' | tr ',' '\n' | grep -qxF -- "$2"
}

add() {   # BROWSER
  local files f target="" new=0 feat
  read -ra files <<< "$(browser_files "$1")"
  for f in "${files[@]}"; do
    grep -qE -- '^[[:space:]]*--enable-features=' "$f" 2>/dev/null && target=$f
  done
  # None has the switch: a new line in the user's file (created if missing).
  [[ -n $target ]] || { target=${files[${#files[@]}-1]}; new=1; }
  for feat in "${FEATURES[@]}"; do
    has_feature "$target" "$feat" && continue
    if (( new )) || ! grep -qE -- '^[[:space:]]*--enable-features=' "$target" 2>/dev/null; then
      printf -- '--enable-features=%s\n' "$feat" >> "$target"
      new=0
    else
      # Append to the last --enable-features line of the file.
      local n
      n=$(grep -nE -- '^[[:space:]]*--enable-features=' "$target" | tail -1 | cut -d: -f1)
      sed -i "${n}s/[[:space:]]*\$/,$feat/; ${n}s/=,/=/" "$target"
    fi
    printf '%s\t%s\n' "$target" "$feat" >> "$MARK"
  done
  [[ $target == "$H"/* ]] && chown "$U:$U" "$target"
  return 0
}

remove() {   # everything the marker lists
  local f feat
  [[ -f $MARK ]] || return 0
  while IFS=$'\t' read -r f feat; do
    [[ -f $f && -n $feat ]] || continue
    # Drop FEATURE from --enable-features lines; a line left empty goes.
    sed -i -E "/^[[:space:]]*--enable-features=/{
      s/([=,])$feat(,|[[:space:]]*\$)/\1\2/
      s/,,/,/; s/=,/=/; s/,([[:space:]]*)\$/\1/
    }" "$f"
    sed -i -E '/^[[:space:]]*--enable-features=[[:space:]]*$/d' "$f"
    [[ -s $f ]] || rm -f "$f"   # it held only our line
  done < "$MARK"
  rm -f "$MARK"
}

remove
if [[ $ON == on ]]; then
  install -d -o "$U" -g "$U" "$(dirname "$MARK")"
  for b in chromium chrome brave; do
    # Brave and Chrome only when installed or already configured; Chromium
    # always (Omarchy's browser; Arch Linux ARM's has no VA-API yet).
    if [[ $b == chromium ]] || installed "$b" || [[ -f $H/.config/$b-flags.conf ]]; then
      add "$b"
    fi
  done
  [[ -f $MARK ]] && chown "$U:$U" "$MARK"
fi
exit 0
