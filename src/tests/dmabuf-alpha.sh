#!/bin/bash
# Transparent panels on Hyprland 0.57 (#630): Hyprland 0.57.0 turns
# quirks:skip_non_kms_dmabuf_formats on, and on virtio-gpu apps then get no buffer
# format with alpha (the Omarchy shell's panels, notifications and menu black out the
# screen). Without a VM:
#  1. Lua (src/tests/omacvm_vm_test.lua, against a stand-in for Hyprland's config): on
#     every route the Lua files OmacVM's installers require from hyprland.lua turn it
#     off; omacvm_vm.lua's cases (0.56.2, no such key, the user's own setting, ...);
#  2. guest/hypr-vm.sh: the file before the line, one line however often it runs,
#     nothing without Omarchy 4's hyprland.lua; guest/install.sh runs it on every route;
#  3. omacvm check's "transparent panels" line (check.sh's dmabuf_alpha_line), and the
#     block that feeds it Hyprland's start (`hyprctl instances`, not ps's etimes).
#   LUA=lua5.5 src/tests/dmabuf-alpha.sh      (LUA: Lua 5.5, default lua)
#   OMACVM_SRC=DIR src/tests/dmabuf-alpha.sh  the same against another checkout's src/
#                                             (main before #630's fix fails)
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$(cd "${OMACVM_SRC:-$R}/src" && pwd)
LUA=${LUA:-lua}
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-dmabuf-alpha.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# ---------- 1. Lua ----------
# The Lua files each route's installers require from hyprland.lua (a feature's own
# pieces aside): the system steps (src/guest/*.sh) on every route, then the route's own.
route_files() {   # ROUTE-DIR...
  local d m f out=""
  for m in $( { for d in "$@"; do grep -ho 'require("hypr\.[A-Za-z0-9_]*")' "$SRC"/$d 2>/dev/null; done; } |
              sed 's/require("hypr\.\(.*\)")/\1/' | sort -u); do
    f=$(find "$SRC" -name "$m.lua" -not -path '*/tests/*' | head -1)
    [[ -n $f ]] && out+="${out:+,}$f"
  done
  echo "$out"
}
COMMON="guest/install.sh guest/hypr-vm.sh"
if ! command -v "$LUA" >/dev/null; then
  echo "FAIL no Lua 5.5 ($LUA): LUA=path/to/lua $0"; fail=1
else
  mkdir -p "$T/cfg" "$T/run" "$T/sys"
  XDG_CONFIG_HOME=$T/cfg XDG_RUNTIME_DIR=$T/run HOME=$T OMACVM_APP_LUA_SYS=$T/sys "$LUA" "$R/src/tests/omacvm_vm_test.lua" \
    "$SRC/guest/omacvm_vm.lua" \
    "app=$(route_files $COMMON 'app/guest/*.sh')" \
    "utm=$(route_files $COMMON 'utm/guest/*.sh')" \
    "parallels=$(route_files $COMMON 'display/guest/*.sh' 'clipboard/guest/*.sh')" \
    "fusion=$(route_files $COMMON 'fusion/guest/*.sh')" || fail=1
fi

# ---------- 2. guest/hypr-vm.sh ----------
installer() {
  G=$T/src/guest; mkdir -p "$G" "$T/home/.config/hypr" "$T/bin"
  cp "$SRC/guest/hypr-vm.sh" "$SRC/guest/omacvm_vm.lua" "$SRC/guest/home-files.sh" "$G/" 2>/dev/null
  # Whether the file was there when the line went in (home-files.sh's home_append, recorded).
  cat >> "$G/home-files.sh" <<'X'
home_append() { if [[ -f $H/.config/hypr/omacvm_vm.lua ]]; then echo file-first; else echo line-first; fi >> "$ORDER"; cat >> "$1"; }
X
  printf '#!/bin/sh\necho "u:x:1000:1000::%s/home:/bin/bash"\n' "$T" > "$T/bin/getent"; chmod +x "$T/bin/getent"
  HL=$T/home/.config/hypr/hyprland.lua; PIECE=$T/home/.config/hypr/omacvm_vm.lua
  run() { ORDER=$T/order PATH="$T/bin:$PATH" bash "$G/hypr-vm.sh" u 2>&1; echo "rc $?"; }
  lines() { grep -cxF 'require("hypr.omacvm_vm")' "$HL" 2>/dev/null || true; }
  expect "no hyprland.lua (Omarchy 3's hyprlang): nothing written" "rc 0|no file" \
    "$(run | tr '\n' '|' | sed 's/|$//')|$([[ -e $PIECE ]] && echo file || echo 'no file')"
  printf -- '-- hyprland\nrequire("hypr.looknfeel")\n' > "$HL"
  expect "first run: added" "added|rc 0" "$(run | tr '\n' '|' | sed 's/|$//')"
  expect "... the file before the line that requires it" "file-first" "$(cat "$T/order" 2>/dev/null)"
  expect "... the line once, at the end, the file as in src" "1 require(\"hypr.omacvm_vm\") same" \
    "$(lines) $(tail -1 "$HL") $(cmp -s "$PIECE" "$SRC/guest/omacvm_vm.lua" && echo same)"
  ino=$(ls -i "$PIECE" | awk '{print $1}')
  expect "run again: nothing to do" "rc 0" "$(run | tr '\n' '|' | sed 's/|$//')"
  expect "... one line, the file not written again" "1 $ino" "$(lines) $(ls -i "$PIECE" | awk '{print $1}')"
  echo "-- an older copy" > "$PIECE"
  expect "an older file: updated, still one line" "updated|rc 0|1" "$(run | tr '\n' '|' | sed 's/|$//')|$(lines)"
  grep -vxF 'require("hypr.omacvm_vm")' "$HL" > "$T/hl" && cat "$T/hl" > "$HL"; : > "$T/order"
  expect "the line gone, the file there: added again, the file first" "added|rc 0|1|file-first" \
    "$(run | tr '\n' '|' | sed 's/|$//')|$(lines)|$(cat "$T/order")"
}
if [[ -f $SRC/guest/hypr-vm.sh ]]; then installer; else echo "FAIL no guest/hypr-vm.sh"; fail=1; fi
# guest/install.sh: a system step (also a repair skips it), on every route (no TYPE test).
blk=$(awk '/^if system; then$/ {b = ""; on = 1} on {b = b $0 "\n"} on && /^fi$/ {if (b ~ /guest\/hypr-vm\.sh/) printf "%s", b; on = 0}' "$SRC/guest/install.sh")
expect "guest/install.sh runs hypr-vm.sh as a system step" yes "$([[ -n $blk ]] && echo yes || echo no)"
expect "... on every route (no VM type in that step)" "" "$(grep -n 'TYPE' <<<"$blk")"

# ---------- 3. omacvm check's line ----------
awk '/^dmabuf_alpha_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$SRC/guest/check.sh" > "$T/fn.sh"
if [[ ! -s $T/fn.sh ]]; then
  echo "FAIL no dmabuf_alpha_line in check.sh"; fail=1
else
  # shellcheck disable=SC1091
  source "$T/fn.sh"
  line() { dmabuf_alpha_line "$@" | cut -f1; }
  has() { dmabuf_alpha_line "$@" | grep -qF -- "$5" && echo yes || echo no; }   # ... TEXT
  expect "0.57 default on, no fix: warn, Update VM" "warn yes" \
    "$(line $'bool: true\nset: false' "" "" "") $(has $'bool: true\nset: false' "" "" "" "Update VM")"
  expect "0.56.2 default off: ok" ok "$(line $'bool: false\nset: false' "" 2000 "")"
  expect "0.56.2 default off, the fix written after this login: ok (nothing to wait for)" ok \
    "$(line $'bool: false\nset: false' 3000 2000 "")"
  expect "OmacVM's false, Hyprland started after the file: ok" ok "$(line $'bool: false\nset: true' 1000 2000 "")"
  expect "OmacVM's false, written after Hyprland started: log out and in (getoption false is no proof)" "human yes" \
    "$(line $'bool: false\nset: true' 3000 2000 "") $(has $'bool: false\nset: true' 3000 2000 "" "log out and in")"
  expect "... written in the second Hyprland started: log out and in" human "$(line $'bool: false\nset: true' 2000 2000 "")"
  # shellcheck disable=SC2088 # the text the line shows, not a path
  uf='~/.config/hypr/looknfeel.lua'
  expect "the user's true in looknfeel.lua: warn naming the file" "human yes" \
    "$(line $'bool: true\nset: true' 1000 2000 looknfeel.lua) $(has $'bool: true\nset: true' 1000 2000 looknfeel.lua "$uf")"
  expect "the user's false (#630's workaround): ok naming the file" "ok yes" \
    "$(line $'bool: false\nset: true' "" 2000 looknfeel.lua) $(has $'bool: false\nset: true' "" 2000 looknfeel.lua "looknfeel.lua")"
  expect "false set at run time, in no file: warn" warn "$(line $'bool: false\nset: true' "" 2000 "")"
  expect "Hyprland's start unknown: skip" skip "$(line $'bool: false\nset: true' 1000 "" "")"
  expect "an int (older Hyprland) 1: warn" warn "$(line $'int: 1\nset: false' "" 2000 "")"
  expect "an int 0 by default: ok" ok "$(line $'int: 0\nset: false' "" 2000 "")"
  expect "no answer: skip" skip "$(line "" "" 2000 "")"
  expect "no such option: skip" skip "$(line "no such option" "" 2000 "")"

  # The block that feeds it, with stand-ins for pgrep, ps, date, stat and hyprctl.
  # Hyprland's start must come from its instance signature (`hyprctl instances -j`, the
  # clock), not now minus ps's etimes: after a Mac sleep the VM's uptime stood still and its
  # clock was set on. Here Hyprland started at 1000, omacvm_vm.lua was written at 3000, the
  # clock says 5000, etimes 500 (now - etimes = 4500 would read "started after the file").
  awk '/^if \[\[ \$TYPE != fusion \]\]; then$/ {on=1} on {print} on && /^fi$/ {exit}' "$SRC/guest/check.sh" > "$T/blk.sh"
  S=$T/stub; mkdir -p "$S" "$T/bh/.config/hypr"
  printf 'require("hypr.looknfeel")\nrequire("hypr.omacvm_vm")\n' > "$T/bh/.config/hypr/hyprland.lua"
  echo "-- omacvm_vm.lua" > "$T/bh/.config/hypr/omacvm_vm.lua"
  printf '#!/bin/sh\necho 813\n' > "$S/pgrep"
  printf '#!/bin/sh\necho "  500"\n' > "$S/ps"
  printf '#!/bin/sh\necho 5000\n' > "$S/date"
  printf '#!/bin/sh\necho 3000\n' > "$S/stat"
  cat > "$S/hyprctl" <<'X'
#!/bin/sh
case "$1 $2" in
  "getoption quirks:skip_non_kms_dmabuf_formats") printf 'bool: false\nset: true\n' ;;
  "instances -j") cat "$INST" ;;
esac
X
  chmod +x "$S"/*
  # hyprctl's own JSON: one object per running Hyprland, only "\n]" when there is none.
  inst() {   # PID:TIME...
    local e out="["
    (( $# )) || { printf '\n]\n'; return; }
    for e in "$@"; do
      out+=$(printf '\n{\n    "instance": "abc_%s_1",\n    "time": %s,\n    "pid": %s,\n    "wl_socket": "wayland-1"\n},' "${e#*:}" "${e#*:}" "${e%%:*}")
    done
    printf '%s\n]\n' "${out%,}"
  }
  blk() {   # PID:TIME... -> what the block says
    inst "$@" > "$T/inst.json"
    # shellcheck disable=SC2034,SC2329 # used by the sourced block
    ( export INST=$T/inst.json PATH="$S:$PATH"; TYPE=app H=$T/bh U=u
      as_user() { "$@"; }; ok() { echo ok; }; warn() { echo "warn${3:+ $3}"; }; skip() { echo skip; }
      # shellcheck disable=SC1091
      source "$T/blk.sh" )
  }
  expect "check: OmacVM's file written after Hyprland started, then a Mac sleep: log out and in" "warn human" \
    "$(blk 700:900 813:1000)"
  expect "check: Hyprland started after the file: ok" ok "$(blk 813:4000)"
  expect "check: no instance for Hyprland's pid: skip (no time)" skip "$(blk 700:900)"
  expect "check: no instance at all: skip" skip "$(blk)"
fi
(( fail == 0 )) && echo "dmabuf-alpha: all passed"
exit $fail
