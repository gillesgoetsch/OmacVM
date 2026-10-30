#!/bin/bash
# OmacVM.app's fix for screenshots and screen sharing of HDR apps (#579,
# src/app/guest/hypr-capture/): Hyprland's cm_helpers.glsl with two changes,
# one folder per Hyprland release (0.56.2/, 0.57.0/), each put in only for
# that Hyprland.
#  0. The releases Omarchy ships (RELEASES: stable and edge) each have a folder.
#  1. Each folder's original names its tag's commit and files (downloaded);
#     its cm_helpers.glsl differs from the tag's only inside "OmacVM" blocks;
#     every shader variant that includes it compiles as with Hyprland's own
#     (hypr-capture-shaders.py, glslangValidator, the tag's own defines).
#  2. Our SDR white is omacvm-display-sync's sdr_max_luminance (203).
#  3. hypr-capture.sh in a fake root: in only beside a binary that carries the
#     tag's files and commit, the folder of that release (also when the binary
#     is another release's), out on any doubt (a changed byte, no binary, an
#     unreadable one, no python3, no fix folder), the hooks, a running Hyprland
#     reloaded only when it runs the installed binary, nobody else's file
#     touched (also another file of the five names ours works with), never an
#     exit code but 0, every --status word.
#  4. omacvm check's "HDR captures" line (hdr_capture_line, taken from check.sh).
# Linux (GNU tools, as in the VM). Parts 1 and 3 need github.com and part 1
# glslangValidator: skipped without, unless OMACVM_HC_STRICT=1 (CI), which
# fails instead.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
SRC=$here/../app/guest/hypr-capture
# Omarchy's Hyprland now: stable (pkgs.omarchy.org/stable) and edge (the dev channel). A new one: a folder first.
RELEASES="0.56.2 0.57.0"
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
expect() {   # WHAT CONDITION...
  local what=$1; shift
  if "$@"; then ok "$what"; else bad "$what"; fi
}
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-hypr-capture.XXXXXX")
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT

FOLDERS=$(cd "$SRC" && for d in */; do [[ -f $d/original ]] && printf '%s ' "${d%/}"; done)
V0=0.56.2   # the release the detailed fake-root rows below use

# --- 0: a folder for each release Omarchy ships
for v in $RELEASES; do
  expect "a fix folder for Hyprland $v" test -f "$SRC/$v/original" -a -f "$SRC/$v/cm_helpers.glsl"
done

# --- 2: one SDR white on both sides
for v in $FOLDERS; do
  white=$(sed -n 's/^#define OMACVM_SDR_WHITE \([0-9.]*\)$/\1/p' "$SRC/$v/cm_helpers.glsl")
  expect "$v: our SDR white ($white) is display-sync's sdr_max_luminance" \
    test "$(grep -c "sdr_max_luminance = ${white%.0}'" "$here/../app/guest/omacvm-display-sync")" = 2
  expect "$v: the file's header names its release" grep -q "^// OmacVM begin: Hyprland $v's src/render/shaders/glsl/cm_helpers.glsl " "$SRC/$v/cm_helpers.glsl"
done

# --- 4: the check line
awk '/^hdr_capture_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$here/../guest/check.sh" > "$T/fn.sh"
if [[ -s $T/fn.sh ]]; then
  # shellcheck disable=SC1091
  source "$T/fn.sh"
  line() {   # what, status text, HDR, want
    local got; got=$(hdr_capture_line "$2" "$3")
    if [[ $got == "$4" ]]; then ok "check: $1"; else bad "check: $1: got '$got', want '$4'"; fi
  }
  line "in place" $'ok\tfixed' 1 $'ok\tfixed'
  line "in place, HDR off" $'ok\tfixed' 0 $'ok\tfixed'
  line "the user's own file" $'own\tyours' 1 $'skip\tyours'
  line "the package's files" $'pkg\ttheirs' 1 $'skip\ttheirs'
  line "not covered, HDR on" $'uncovered\tno fix' 1 $'warn\tno fix'
  line "not covered, HDR off" $'uncovered\tno fix' 0 $'skip\tno fix'
  line "not in place, HDR on" $'missing\tapply' 1 $'warn\tapply'
  line "someone else's file, HDR on" $'other\tanother' 1 $'warn\tanother'
  line "a VM without the fix, HDR on" "" 1 \
    $'warn\tOmacVM\'s fix for screenshots and screen sharing of HDR apps (Chrome) is not in this VM: Update VM'
  line "a VM without the fix, HDR off" "" 0 \
    $'skip\tOmacVM\'s fix for screenshots and screen sharing of HDR apps (Chrome) is not in this VM: Update VM'
else
  bad "no hdr_capture_line in check.sh"
fi
expect "check.sh shows the line" grep -q 'ok "HDR captures"' "$here/../guest/check.sh"

# --- the hooks never stop a transaction and run the installed script
for h in "$SRC"/*.hook; do
  expect "$(basename "$h"): no AbortOnFail" test "$(grep -c AbortOnFail "$h")" = 0
  expect "$(basename "$h"): on /usr/bin/Hyprland itself" grep -qx 'Target = usr/bin/Hyprland' "$h"
done
expect "the pre hook takes ours out" grep -qx 'Exec = /usr/local/lib/omacvm/hypr-capture/hypr-capture.sh --hook-pre' "$SRC/05-omacvm-hypr-capture-pre.hook"
expect "the pre hook runs before" grep -qx 'When = PreTransaction' "$SRC/05-omacvm-hypr-capture-pre.hook"
expect "the post hook puts it back" grep -qx 'Exec = /usr/local/lib/omacvm/hypr-capture/hypr-capture.sh --hook-post' "$SRC/95-omacvm-hypr-capture.hook"

# --- 1: each release folder against its tag
fetch() {   # VERSION: the tag's shader folder and ShaderLoader.cpp in $T/hypr-VERSION
  local g=$T/hypr-$1
  git -c advice.detachedHead=false clone -q --depth 1 --branch "v$1" --filter=blob:none --no-checkout \
      https://github.com/hyprwm/Hyprland "$g" 2>/dev/null &&
    git -C "$g" sparse-checkout set --no-cone /src/render/shaders/glsl/ /src/render/ShaderLoader.cpp 2>/dev/null &&
    git -C "$g" checkout -q 2>/dev/null
}
for v in $FOLDERS; do
  if ! fetch "$v"; then
    if [[ ${OMACVM_HC_STRICT:-} == 1 ]]; then bad "cannot download Hyprland v$v (parts 1 and 3)"
    else echo "skip: cannot download Hyprland v$v (parts 1 and 3)"; fi
    (( fail == 0 )) && echo "hypr-capture: all passed (offline parts only)"
    exit $fail
  fi
done
for v in $FOLDERS; do
  G=$T/hypr-$v; GL=$G/src/render/shaders/glsl; TAG=v$v
  expect "$v: original names $TAG's commit" grep -qx "commit $(git -C "$G" rev-parse HEAD)" "$SRC/$v/original"
  while read -r kind sha size name first; do
    [[ $kind == file ]] || continue
    expect "$v: original: $name as in $TAG" test "$(sha256sum < "$GL/$name" | cut -d' ' -f1) $(( $(wc -c < "$GL/$name") )) $(head -n1 "$GL/$name")" = "$sha $size $first"
  done < "$SRC/$v/original"
  expect "$v: original lists the file we replace and those that call it" \
    test "$(grep -c '^file ' "$SRC/$v/original")" = 5
  outside=$(python3 - "$GL/cm_helpers.glsl" "$SRC/$v/cm_helpers.glsl" <<'PY'
import difflib, sys
a = open(sys.argv[1], encoding="utf-8").read().splitlines()
b = open(sys.argv[2], encoding="utf-8").read().splitlines()
inside, depth = set(), 0
for i, l in enumerate(b):
    if l.strip().startswith("// OmacVM begin"):
        depth += 1
    if depth:
        inside.add(i)
    if l.strip() == "// OmacVM end":
        depth -= 1
for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
    if op == "equal":
        continue
    # a change: what it adds lies in a block; what it drops sits where a block is
    if any(j not in inside for j in range(j1, j2)) or (j1 == j2 and j1 not in inside and j1 - 1 not in inside):
        print(f"{op} upstream {i1 + 1}-{i2} ours {j1 + 1}-{j2}")
print(f"blocks {sum(1 for l in b if l.strip().startswith('// OmacVM begin'))}")
PY
)
  expect "$v: our cm_helpers.glsl differs from $TAG's only in OmacVM blocks ($(tail -n1 <<<"$outside"))" \
    test "$(grep -vc '^blocks ' <<<"$outside")" = 0
  [[ $(grep -vc '^blocks ' <<<"$outside") == 0 ]] || grep -v '^blocks ' <<<"$outside"
  expect "$v: the same two OmacVM blocks and header as $V0's" \
    test "$(grep -v '^// OmacVM begin: Hyprland ' "$SRC/$v/cm_helpers.glsl" | sed -n '/OmacVM begin/,/OmacVM end/p')" = \
         "$(grep -v '^// OmacVM begin: Hyprland ' "$SRC/$V0/cm_helpers.glsl" | sed -n '/OmacVM begin/,/OmacVM end/p')"
  if command -v glslangValidator >/dev/null; then
    if python3 "$here/hypr-capture-shaders.py" "$GL" "$SRC/$v/cm_helpers.glsl"; then ok "$v: shader variants"
    else bad "$v: shader variants"; fi
  elif [[ ${OMACVM_HC_STRICT:-} == 1 ]]; then bad "glslangValidator missing (glslang-tools)"
  else echo "skip: $v: shader variants (no glslangValidator)"; fi
done

# --- 3: hypr-capture.sh in a fake root
R=$T/root
L=$T/lib                                   # /usr/local/lib/omacvm/hypr-capture
OURS=$R/usr/local/share/hypr/shaders/cm_helpers.glsl
LOG=$T/hyprctl.log
mkdir -p "$L" "$R/usr/bin" "$T/bin"
cp -R "$SRC"/. "$L"/
# a stand-in Hyprland binary: what the real one carries, between other bytes
G=$T/hypr-$V0; GL=$G/src/render/shaders/glsl
mkbin() {   # mkbin [sed expression for cm_helpers.glsl] [release: $V0]
  local g=$T/hypr-${2:-$V0}
  { head -c 4096 /dev/urandom; echo "Hyprland, built from commit $(git -C "$g" rev-parse HEAD)"
    for f in constants.h CM.glsl tonemap.glsl surface.frag; do cat "$g/src/render/shaders/glsl/$f"; printf '\0'; done
    if [[ -n ${1:-} ]]; then sed "$1" "$g/src/render/shaders/glsl/cm_helpers.glsl"; else cat "$g/src/render/shaders/glsl/cm_helpers.glsl"; fi
    head -c 4096 /dev/urandom; } > "$R/usr/bin/Hyprland"
}
cat > "$T/bin/hyprctl" <<EOF
#!/bin/bash
echo "\$HYPRLAND_INSTANCE_SIGNATURE \$XDG_RUNTIME_DIR \$*" >> "$LOG"
EOF
chmod 755 "$T/bin/hyprctl"
# running Hyprlands: the installed binary, a replaced one, another program
inst() {   # inst UID SIG PID EXE
  mkdir -p "$R/run/user/$1/hypr/$2" "$R/proc/$3"
  printf '%s\nwayland-1\n' "$3" > "$R/run/user/$1/hypr/$2/hyprland.lock"
  ln -sfn "$4" "$R/proc/$3/exe"
}
inst 1000 live_1_a 101 /usr/bin/Hyprland
inst 1000 old_2_b 102 '/usr/bin/Hyprland (deleted)'
inst 1001 other_3_c 103 /usr/bin/foot
run() { OMACVM_HC_ROOT=$R OMACVM_HC_HYPRCTL=$T/bin/hyprctl "$L/hypr-capture.sh" "$@"; }
reloads() { if [[ -f $LOG ]]; then grep -c reloadshaders "$LOG"; else echo 0; fi; }
status() { run --status "$@" | cut -f1; }
rc() { run "$@" >/dev/null 2>&1; echo $?; }

mkbin
: > "$LOG"
expect "the tag's binary: exit 0" test "$(rc)" = 0
expect "the tag's binary: ours in place" cmp -s "$SRC/$V0/cm_helpers.glsl" "$OURS"
expect "ours: 0644" test "$(stat -c %a "$OURS")" = 644
expect "the state names the release and our file" \
  test "$(cat "$R/var/lib/omacvm/hypr-capture")" = "$V0 $(sha256sum < "$OURS" | cut -d' ' -f1)"
expect "the running Hyprland of that binary reloaded, once, in its own runtime folder" \
  test "$(cat "$LOG")" = "live_1_a /run/user/1000 reloadshaders"
expect "status: ok" test "$(status)" = ok
: > "$LOG"; run >/dev/null
expect "again: nothing changes, no reload" test "$(reloads)" = 0
expect "pre hook: exit 0" test "$(rc --hook-pre)" = 0
expect "pre hook: ours out" test ! -e "$OURS"
expect "pre hook: no reload" test "$(reloads)" = 0
expect "status after the pre hook: missing" test "$(status)" = missing
expect "post hook: exit 0" test "$(rc --hook-post)" = 0
expect "post hook: ours back" cmp -s "$SRC/$V0/cm_helpers.glsl" "$OURS"
expect "post hook: the live Hyprland reloaded" test "$(reloads)" = 1
mkbin 's/SDR_MAX_LUMINANCE));/SDR_MAX_LUMINANCE)); /'
: > "$LOG"
expect "one byte changed in the binary's cm_helpers.glsl: exit 0" test "$(rc --hook-post)" = 0
expect "one byte changed: ours out" test ! -e "$OURS"
expect "one byte changed: the live Hyprland reloaded (its own copy again)" test "$(reloads)" = 1
expect "one byte changed: status uncovered" test "$(status)" = uncovered
expect "one byte changed: says which file" grep -q "cm_helpers.glsl is not the one" <(run --status)
mkbin; run >/dev/null
sed -i "s/$(git -C "$G" rev-parse HEAD)/0000000000000000000000000000000000000000/" "$R/usr/bin/Hyprland"
expect "another commit: ours out" test "$(rc; [[ -e $OURS ]] && echo there)" = 0
mkbin; run >/dev/null
rm "$R/usr/bin/Hyprland"
expect "no binary: exit 0, ours out" test "$(rc; [[ -e $OURS ]] && echo there)" = 0
expect "no binary: status uncovered" test "$(status)" = uncovered
mkbin; run >/dev/null
chmod 000 "$R/usr/bin/Hyprland"
if [[ -r $R/usr/bin/Hyprland ]]; then echo "skip: an unreadable binary (root reads it anyway)"
else expect "an unreadable binary: exit 0, ours out" test "$(rc; [[ -e $OURS ]] && echo there)" = 0; fi
chmod 644 "$R/usr/bin/Hyprland"; run >/dev/null
# without python3: the tools the script uses, nothing else
mkdir -p "$T/nopy"
for t in bash sha256sum cut cat chmod mv mkdir mktemp rm cmp dirname basename readlink head tail getent id env \
         setsid setpriv timeout grep; do
  p=$(command -v "$t") && ln -sf "$p" "$T/nopy/$t"
done
expect "no python3: exit 0, ours out" \
  test "$(PATH=$T/nopy OMACVM_HC_ROOT=$R OMACVM_HC_HYPRCTL=$T/bin/hyprctl "$T/nopy/bash" "$L/hypr-capture.sh" >/dev/null 2>&1; echo $?; [[ -e $OURS ]] && echo there)" = 0
run >/dev/null
mkdir -p "$T/nofix"; cp "$L/hypr-capture.sh" "$T/nofix/"
expect "no fix folder beside the script: exit 0, ours out" \
  test "$(OMACVM_HC_ROOT=$R OMACVM_HC_HYPRCTL=$T/bin/hyprctl "$T/nofix/hypr-capture.sh" >/dev/null 2>&1; echo $?; [[ -e $OURS ]] && echo there)" = 0
# a file of an older OmacVM (recorded in the state) is replaced
echo "// an older OmacVM fix" > "$OURS"
echo "$V0 $(sha256sum < "$OURS" | cut -d' ' -f1)" > "$R/var/lib/omacvm/hypr-capture"
run >/dev/null
expect "an older OmacVM file: replaced by this one" cmp -s "$SRC/$V0/cm_helpers.glsl" "$OURS"
# an older OmacVM file whose record is gone: known by its header, so the pre
# hook still takes it out and an apply replaces it
older() { sed 's/OMACVM_SDR_WHITE 203.0/OMACVM_SDR_WHITE 200.0/' "$SRC/$V0/cm_helpers.glsl" > "$OURS"; rm -f "$R/var/lib/omacvm/hypr-capture"; }
older
expect "an older OmacVM file, no record: status missing" test "$(status)" = missing
run --hook-pre >/dev/null
expect "an older OmacVM file, no record: the pre hook takes it out" test ! -e "$OURS"
older; run >/dev/null
expect "an older OmacVM file, no record: replaced by this one" cmp -s "$SRC/$V0/cm_helpers.glsl" "$OURS"
# nobody else's file is touched
echo "// someone's own" > "$OURS"; rm -f "$R/var/lib/omacvm/hypr-capture"
run >/dev/null; run --hook-pre >/dev/null; run --remove >/dev/null
expect "someone else's file in /usr/local/share/hypr/shaders: left" grep -qx "// someone's own" "$OURS"
expect "someone else's file: status other" test "$(status)" = other
rm "$OURS"; run >/dev/null
mkdir -p "$R/usr/share/hypr/shaders"; echo "// the package's" > "$R/usr/share/hypr/shaders/cm_helpers.glsl"
run >/dev/null
expect "the package ships shader files: ours out" test ! -e "$OURS"
expect "the package ships shader files: status pkg" test "$(status)" = pkg
expect "the package's file left" grep -qx "// the package's" "$R/usr/share/hypr/shaders/cm_helpers.glsl"
rm "$R/usr/share/hypr/shaders/cm_helpers.glsl"
echo "// the package's" > "$R/usr/share/hypr/shaders/CM.glsl"
run >/dev/null
expect "the package ships CM.glsl only: ours out" test ! -e "$OURS"
expect "the package ships CM.glsl only: status pkg, names it" grep -q "^pkg.*(CM.glsl)" <(run --status)
rm -r "$R/usr/share/hypr"; run >/dev/null
echo "// someone's" > "$R/usr/local/share/hypr/shaders/tonemap.glsl"
expect "another tonemap.glsl beside ours: exit 0" test "$(rc)" = 0
expect "another tonemap.glsl beside ours: ours out" test ! -e "$OURS"
expect "another tonemap.glsl beside ours: status other, names it" grep -q "^other.*another tonemap.glsl" <(run --status)
expect "another tonemap.glsl beside ours: left" grep -qx "// someone's" "$R/usr/local/share/hypr/shaders/tonemap.glsl"
rm "$R/usr/local/share/hypr/shaders/tonemap.glsl"; run >/dev/null
me=$(id -un); hm=$(getent passwd "$me" | cut -d: -f6)
mkdir -p "$R$hm/.config/hypr/shaders"; echo "// mine" > "$R$hm/.config/hypr/shaders/cm_helpers.glsl"
expect "the user's own file: status own" test "$(status "$me")" = own
expect "the user's own file: ours stays in place (theirs wins in Hyprland)" test -e "$OURS"
rm "$R$hm/.config/hypr/shaders/cm_helpers.glsl"; echo "// mine" > "$R$hm/.config/hypr/shaders/constants.h"
expect "the user's own constants.h: status own, names it" grep -q "^own.*shaders/constants.h is used" <(run --status "$me")
rm -r "$R$hm/.config"
# the shader folder cannot be written: Hyprland's own copy, and says so
run --remove >/dev/null; chmod 555 "$R/usr/local/share/hypr/shaders"
if touch "$R/usr/local/share/hypr/shaders/.w" 2>/dev/null; then
  rm -f "$R/usr/local/share/hypr/shaders/.w"; echo "skip: a folder that cannot be written (root writes anyway)"
else
  expect "cannot write ours: exit 0, says so" grep -q "could not be written" <(run 2>&1)
  expect "cannot write ours: not there" test ! -e "$OURS"
fi
chmod 755 "$R/usr/local/share/hypr/shaders"; run >/dev/null
: > "$LOG"
expect "--remove: exit 0" test "$(rc --remove)" = 0
expect "--remove: ours out, the live Hyprland reloaded" test "$(reloads; [[ -e $OURS ]] && echo there)" = 1
expect "a wrong option: usage, exit 2" test "$(rc --nope)" = 2
expect "the replaced and the other program never reloaded" test "$(grep -c 'old_2_b\|other_3_c' "$LOG")" = 0

# each release's binary gets its own folder's file (also right after another release's was in place)
for v in $FOLDERS; do
  mkbin "" "$v"; : > "$LOG"
  expect "Hyprland $v's binary: exit 0" test "$(rc --hook-post)" = 0
  expect "Hyprland $v's binary: the $v folder's file in place" cmp -s "$SRC/$v/cm_helpers.glsl" "$OURS"
  expect "Hyprland $v's binary: the state names $v" test "$(cut -d' ' -f1 "$R/var/lib/omacvm/hypr-capture")" = "$v"
  expect "Hyprland $v's binary: status ok, names $v" grep -q "^ok.*for Hyprland $v)" <(run --status)
  expect "Hyprland $v's binary: the live Hyprland reloaded" test "$(reloads)" = 1
  for o in $FOLDERS; do
    [[ $o == "$v" ]] && continue
    mkdir -p "$T/only-$o"; cp "$L/hypr-capture.sh" "$L/guard.py" "$T/only-$o/"; cp -R "$L/$o" "$T/only-$o/"
    expect "Hyprland $v's binary, only the $o folder: ours out, status uncovered" \
      test "$(OMACVM_HC_ROOT=$R OMACVM_HC_HYPRCTL=$T/bin/hyprctl "$T/only-$o/hypr-capture.sh" >/dev/null 2>&1; [[ -e $OURS ]] && echo there; OMACVM_HC_ROOT=$R "$T/only-$o/hypr-capture.sh" --status | cut -f1)" = uncovered
    run >/dev/null
  done
done

# the reason names the installed hyprland package (pacman's database: the entry named hyprland itself, not
# hyprland-guiutils or -protocols beside it; no epoch) and the releases OmacVM has fixes for
LAST=${FOLDERS% }; LAST=${LAST##* }
PDB=$R/var/lib/pacman/local
pkg() {   # pkg NAME VERSION: an installed package's record
  mkdir -p "$PDB/$1-${2#*:}"; printf '%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n%%BASE%%\n%s\n\n' "$1" "$2" "$1" > "$PDB/$1-${2#*:}/desc"
}
why() { run --status | cut -f2 | sed 's/: screenshots and screen sharing.*//'; }
# shellcheck disable=SC2086
set -- $FOLDERS; have=$1; shift; while (( $# > 1 )); do have+=", $1"; shift; done; (( $# )) && have+=" and $1"
pkg hyprland-guiutils 0.2.2-4; pkg hyprland-protocols 0.8.0-1
mkbin "" "$LAST"; sed -i "s/$(git -C "$T/hypr-$LAST" rev-parse HEAD)/1111111111111111111111111111111111111111/" "$R/usr/bin/Hyprland"
expect "no hyprland record (only hyprland-guiutils and -protocols): version not known" \
  test "$(why)" = "no OmacVM fix for this Hyprland (its version is not known; OmacVM has fixes for $have)"
pkg hyprland 0.58.0-1
expect "an unknown release: names it and what OmacVM has" test "$(why)" = "no OmacVM fix for Hyprland 0.58.0-1 yet (OmacVM has fixes for $have)"
expect "an unknown release: the apply says the same" grep -q "Hyprland's own copy: no OmacVM fix for Hyprland 0.58.0-1 yet (OmacVM has fixes for $have)" <(run --hook-post)
rm -r "$PDB/hyprland-0.58.0-1"; pkg hyprland 1:0.58.0-2
expect "an epoch: left out" test "$(why)" = "no OmacVM fix for Hyprland 0.58.0-2 yet (OmacVM has fixes for $have)"
rm -r "$PDB/hyprland-0.58.0-2"; pkg hyprland "$LAST-9"
mkbin 's/^#ifndef ALLOW_INCLUDES$/#ifndef ALLOW_INCLUDES /' "$LAST"
expect "a known release, another build: says which file" \
  test "$(why)" = "no OmacVM fix for this build of Hyprland $LAST-9 (its cm_helpers.glsl is not the one OmacVM's $LAST fix is made for)"
mkbin "" "$LAST"
expect "that release's own build: ok again" test "$(status)" = ok
# #630's reporter: Hyprland 0.57.0-2 with only the 0.56.2 folder said "0.56.2: not built from commit efb50993"
rm -r "$PDB/hyprland-$LAST-9"; pkg hyprland 0.57.0-2; mkbin "" 0.57.0
mkdir -p "$T/only-0.56.2"; cp "$L/hypr-capture.sh" "$L/guard.py" "$T/only-0.56.2/"; cp -R "$L/0.56.2" "$T/only-0.56.2/"
expect "0.57.0-2 with the 0.56.2 folder only: names 0.57.0-2, not 0.56.2's commit" \
  test "$(OMACVM_HC_ROOT=$R "$T/only-0.56.2/hypr-capture.sh" --status | cut -f2 | sed 's/: screenshots.*//')" = \
       "no OmacVM fix for Hyprland 0.57.0-2 yet (OmacVM has a fix for 0.56.2)"
rm -r "$PDB"; run >/dev/null

(( fail == 0 )) && echo "hypr-capture: all passed"
exit $fail
