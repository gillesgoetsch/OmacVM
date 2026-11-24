#!/bin/bash
# Keyboard layouts, offline (#784): a new VM gets XKB's Mac variant where the
# Mac's layout has one (mac-layout.sh), VMs before keep the PC layout (--pc,
# omacvm apply's fallback), the row's two ways (--mac-of, --pc-of), every Mac
# variant types level 3 with the right Option key only, and the guest side
# takes XKB names only. A stand-in for macOS's `defaults`; no VM.
#   src/keyboard/test.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
K=$R/src/keyboard
T=$(mktemp -d "${TMPDIR:-/tmp}/keyboard-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}
mkdir "$T/bin"
printf '#!/bin/bash\necho "com.apple.keylayout.$FAKE_ID"\n' > "$T/bin/defaults"
chmod +x "$T/bin/defaults"
layout() { FAKE_ID=$1 PATH=$T/bin:$PATH /bin/bash "$K/mac-layout.sh" ${2:+"$2"} 2>/dev/null; }

# A new VM: the Mac variant for the Mac's own layouts.
while read -r id want; do
  expect "new VM, macOS $id" "$want" "$(layout "$id")"
done <<'EOF'
German de mac
SwissGerman ch de_mac
SwissFrench ch fr_mac
French fr mac
British gb mac
Italian it mac
Italian-Pro it mac
Dutch nl mac
Portuguese pt mac
Swedish se mac
Swedish-Pro se mac
Danish dk mac
Finnish fi mac
FinnishExtended fi mac
Icelandic is mac
Spanish es
Spanish-ISO es
Norwegian no
US us
ABC us
Austrian at
British-PC gb
French-PC fr
French-numerical fr
ABC-QWERTZ gb
FinnishSami-PC fi
EOF
expect "an unknown layout: us" "us" "$(layout Klingon)"
expect "an unknown layout: said on stderr" "keyboard: no Linux match for macOS layout 'Klingon', using us" \
  "$(FAKE_ID=Klingon PATH=$T/bin:$PATH /bin/bash "$K/mac-layout.sh" 2>&1 >/dev/null)"

# VMs before (omacvm apply without a layout in vm.env): the PC layout as before.
while read -r id want; do
  expect "--pc, macOS $id" "$want" "$(layout "$id" --pc)"
done <<'EOF'
German de
SwissGerman ch de
SwissFrench ch fr
British gb
Swedish se
US us
EOF

# The settings row: both ways, nothing for a layout without a Mac variant.
expect "--mac-of de" "de mac" "$("$K/mac-layout.sh" --mac-of de)"
expect "--mac-of ch de" "ch de_mac" "$("$K/mac-layout.sh" --mac-of "ch de")"
expect "--pc-of ch fr_mac" "ch fr" "$("$K/mac-layout.sh" --pc-of "ch fr_mac")"
out=$("$K/mac-layout.sh" --mac-of us); expect "--mac-of us: none" "1:" "$?:$out"
out=$("$K/mac-layout.sh" --mac-of "de mac"); expect "--mac-of a Mac variant: none" "1:" "$?:$out"
out=$("$K/mac-layout.sh" --pc-of de); expect "--pc-of a PC layout: none" "1:" "$?:$out"
out=$("$K/mac-layout.sh" --mac-of ""); expect "--mac-of nothing: none" "1:" "$?:$out"
"$K/mac-layout.sh" --bogus >/dev/null 2>&1; expect "an unknown option: usage" 2 $?
grep -q 'declare -A\|mapfile\|\${[a-z_]*,,}' "$K/mac-layout.sh"; expect "macOS's bash 3.2 only" 1 $?

# Each pair: a Mac variant that XKB has, and only for these layouts (es and
# no stay PC: XKB has no es(mac), and no(mac) has no level 3 key).
pairs=$(awk '/^pairs=/{on=1; sub(/^pairs=./,"")} on{print} /\x27$/{on=0}' "$K/mac-layout.sh" | tr -d "'")
expect "pairs: the twelve Mac variants" "de ch_de ch_fr fr gb it nl pt se dk fi is" \
  "$(cut -d'|' -f1 <<< "$pairs" | tr ' ' '_' | tr '\n' ' ' | sed 's/ $//')"
while IFS='|' read -r pc mac; do
  [[ -n $pc ]] || continue
  [[ $mac =~ ^[a-z]{2}\ (mac|de_mac|fr_mac)$ ]]; expect "pair $pc: an XKB Mac variant ($mac)" 0 $?
  expect "pair $pc: the same layout" "${pc%% *}" "${mac%% *}"
done <<< "$pairs"

# The app's row (MacKeyLayout.swift) has the same pairs.
SW=$R/app/app/Sources/OmacVMFeatures/MacKeyLayout.swift
expect "the app's pairs are mac-layout.sh's" "$pairs" \
  "$(sed -n 's/^ *("\([^"]*\)", "\([^"]*\)"),$/\1|\2/p' "$SW")"

# Level 3 with the right Option only, when xkeyboard-config is here (the CI's
# Linux runner): each variant includes level3(ralt_switch) itself or through
# what it includes, and none takes the left Alt.
X=${OMACVM_XKB_SYMBOLS:-/usr/share/X11/xkb/symbols}
if [[ -d $X ]]; then
  body() { awk -v v="\"$2\"" '$1 == "xkb_symbols" && $2 == v {on=1} on {print} on && /^};/ {exit}' "$X/$1"; }
  l3() {   # LAYOUT VARIANT [DEPTH]: 0 when it reaches ralt_switch
    local b inc d=${3:-0}
    (( d < 4 )) || return 1
    b=$(body "$1" "$2")
    grep -q 'lalt_switch' <<< "$b" && return 2
    grep -q 'level3(ralt_switch)' <<< "$b" && return 0
    while read -r inc; do
      [[ $inc =~ ^([a-z]+)\(([a-z_0-9]+)\)$ ]] && [[ -f $X/${BASH_REMATCH[1]} ]] &&
        l3 "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" $((d + 1)) && return 0
    done < <(sed -n 's/.*include "\([^"]*\)".*/\1/p' <<< "$b")
    return 1
  }
  while IFS='|' read -r pc mac; do
    [[ -n $pc ]] || continue
    l3 "${mac%% *}" "${mac#* }"; expect "xkb ${mac%% *}(${mac#* }): level 3 on the right Option only" 0 $?
  done <<< "$pairs"
else
  echo "skip level 3 check (no $X here)"
fi

# The guest side takes XKB names only (they go into Hyprland's Lua config).
G=$(cat "$K/guest/install.sh")
case $G in *'[[ $L =~ ^[a-z]{2,8}$ && $V =~ ^[A-Za-z0-9_-]{0,32}$ ]]'*) echo "ok   guest: XKB names only" ;;
  *) echo "FAIL guest: XKB names only"; fail=1 ;; esac
A=$(cat "$R/src/cmd/apply.sh")
case $A in *'KB=$("$R/src/keyboard/mac-layout.sh" --pc)'*) echo "ok   apply: a VM without a layout keeps the PC one" ;;
  *) echo "FAIL apply: a VM without a layout keeps the PC one"; fail=1 ;; esac
case $A in *'[[ $KB =~ ^[a-z]{2,8}( [A-Za-z0-9_-]{1,32})?$ ]] || die'*) echo "ok   apply: XKB names only" ;;
  *) echo "FAIL apply: XKB names only"; fail=1 ;; esac
for kb in 'de mac' 'ch de_mac' 'us' 'us alt-intl'; do
  [[ $kb =~ ^[a-z]{2,8}( [A-Za-z0-9_-]{1,32})?$ ]]; expect "apply takes '$kb'" 0 $?
done
for kb in "de' ; reboot '" 'de "mac"' 'de mac x' ''; do
  [[ $kb =~ ^[a-z]{2,8}( [A-Za-z0-9_-]{1,32})?$ ]]; expect "apply refuses '$kb'" 1 $?
done
exit $fail
