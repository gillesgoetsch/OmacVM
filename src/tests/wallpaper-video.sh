#!/bin/bash
# A video or animated background sends the Mac one picture, its first frame
# (#747), without a VM: src/wallpaper/guest/omacvm-wallpaper with stand-ins
# for file, ffmpeg, magick, omacvm-bridge, mktemp, stat and timeout, on a PATH
# of its own (a real ffmpeg or magick here is never used).
#  - video/*: ffmpeg's first frame (-frames:v 1); an animation: magick "[0]";
#  - nothing sent (and nothing recorded) when no picture came out, or ffmpeg
#    is missing; PNG and JPEG go as they are; a failed send records nothing;
#  - no files left behind, and up to 3.4.1's frame files in the temp folder
#    go once.
#   src/tests/wallpaper-video.sh
#   OMACVM_SRC=DIR src/tests/wallpaper-video.sh  against another checkout's src/
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$(cd "${OMACVM_SRC:-$R}/src" && pwd)
W=$SRC/wallpaper/guest/omacvm-wallpaper
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-wallpaper.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}
B=$T/bin F=$T/ff M=$T/min; mkdir -p "$B" "$F" "$M"
for t in readlink cat rm mkdir dirname tr head wc sed ls od; do
  p=$(command -v "$t") && ln -s "$p" "$M/$t"
done
PNG='\211PNG\r\n\032\n'
# file: the type by the name's extension
cat > "$B/file" <<'EOF'
#!/bin/bash
case ${@: -1} in
  *.mp4) echo video/mp4 ;; *.webm) echo video/webm ;; *.gif) echo image/gif ;;
  *.png) echo image/png ;; *.jpg) echo image/jpeg ;; *) echo application/octet-stream ;;
esac
EOF
# mktemp [--suffix S]: $TMPDIR/tmp.XXXXXXXXXX[S], as coreutils' (macOS's has no --suffix)
cat > "$B/mktemp" <<'EOF'
#!/bin/bash
s=""; [[ ${1:-} == --suffix ]] && s=$2
n=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 10)
f=${TMPDIR:-/tmp}/tmp.$n$s; : > "$f"; echo "$f"
EOF
printf '#!/bin/bash\necho 1700000000\n' > "$B/stat"
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$B/timeout"
# ffmpeg ... -i IN ... OUT: one PNG for -frames:v 1 ($FFMPEG=fail: exit 1, =empty: writes nothing)
cat > "$F/ffmpeg" <<EOF
#!/bin/bash
echo "ffmpeg \$*" >> "\$CALLS"
[[ \${FFMPEG:-} == fail ]] && exit 1
[[ \${FFMPEG:-} == empty ]] && exit 0
[[ " \$* " == *" -frames:v 1 "* ]] || exit 2
printf '$PNG' > "\${@: -1}"; printf 'first-frame' >> "\${@: -1}"
EOF
# magick IN -strip OUT: one file per frame (OUT-0.png ...) for a video or an animation,
# one file for IN[0]; $MAGICK=fail: exit 1
cat > "$B/magick" <<EOF
#!/bin/bash
echo "magick \$*" >> "\$CALLS"
[[ \${MAGICK:-} == fail ]] && exit 1
in=\$1 out=\${@: -1}
if [[ \$in == *"[0]" ]]; then printf '$PNG' > "\$out"; printf 'frame0' >> "\$out"; exit 0; fi
case \$in in *.mp4|*.webm|*.gif) for i in 0 1 2; do printf '$PNG' > "\${out%.png}-\$i.png"; done ;; *) printf '$PNG' > "\$out" ;; esac
EOF
# omacvm-bridge wallpaper FILE NAME: records what the Mac would get ($BRIDGE=fail: the Mac's 400)
cat > "$B/omacvm-bridge" <<'EOF'
#!/bin/bash
[[ ${BRIDGE:-} == fail ]] && { echo "curl: (22) The requested URL returned error: 400" >&2; exit 22; }
f=$2; echo "sent $(wc -c < "$f" | tr -d ' ') $(head -c 4 "$f" | od -An -c | tr -d ' ') $([[ $f == "$BG" ]] && echo itself || echo copy) $3" >> "$CALLS"
EOF
chmod +x "$B"/* "$F"/*

H=$T/home TMP=$T/tmp CALLS=$T/calls
CUR=$H/.local/state/omarchy/current ST=$H/.local/state/omacvm/wallpaper-sent
setbg() {   # FILE [CONTENT]: the theme's background
  rm -rf "$H" "$TMP"; mkdir -p "$CUR" "$TMP" "$H/bg"; : > "$CALLS"
  printf '%s' "${2:-data}" > "$H/bg/$1"; ln -s "$H/bg/$1" "$CUR/background"; echo "tokyo" > "$CUR/theme.name"
}
run() {   # [nofff]: run as the session's service would, the PATH only ours
  local path=$B:$F:$M
  [[ ${1:-} == noff ]] && path=$B:$M
  env -i HOME="$H" TMPDIR="$TMP" PATH="$path" CALLS="$CALLS" BG="$(readlink -f "$CUR/background")" \
    FFMPEG="${FFMPEG:-}" MAGICK="${MAGICK:-}" BRIDGE="${BRIDGE:-}" "$BASH" "$W" 2>&1
  echo "rc $?"
}
sent() { grep '^sent' "$CALLS" | tr '\n' ';'; }
left() { ls -A "$TMP" | tr '\n' ' '; }
rec() { [[ -f $ST ]] && echo recorded || echo "not recorded"; }

for v in bg.mp4 bg.webm; do
  setbg "$v"; out=$(run)
  expect "$v: the Mac gets one PNG, the first frame (not 0 bytes)" "sent 19 211PNG copy tokyo;" "$(sent)"
  expect "$v: through ffmpeg -frames:v 1, magick not used" "yes no" \
    "$(grep -q '^ffmpeg .*-i .*/bg/'"$v"' .*-frames:v 1 ' "$CALLS" && echo yes || echo no) $(grep -q '^magick' "$CALLS" && echo yes || echo no)"
  expect "$v: recorded, says so, nothing left in the temp folder" "recorded|omacvm-wallpaper: tokyo -> the Mac|rc 0|" \
    "$(rec)|$(tr '\n' '|' <<<"$out")$(left)"
done
setbg bg.mp4; run > /dev/null; : > "$CALLS"; run > /dev/null
expect "the same video again: not sent again" "" "$(sent)"

setbg bg.gif; out=$(run)
expect "an animated GIF: magick's first frame only ([0]), one PNG sent" "yes|sent 14 211PNG copy tokyo;|" \
  "$(grep -q '^magick .*bg.gif\[0\] -strip ' "$CALLS" && echo yes || echo no)|$(sent)|$(left)"

for c in fail empty; do
  setbg bg.mp4; out=$(FFMPEG=$c run)
  expect "ffmpeg $c: nothing sent, nothing recorded, exit 0, one line" \
    "|not recorded|omacvm-wallpaper: no picture from bg.mp4 (video/mp4): not sent|rc 0|" "$(sent)|$(rec)|$(tr '\n' '|' <<<"$out")$(left)"
done
setbg bg.mp4; out=$(run noff)
expect "no ffmpeg: a video is not sent, says why" \
  "|not recorded|omacvm-wallpaper: bg.mp4 is a video and ffmpeg is not installed: not sent|rc 0|" "$(sent)|$(rec)|$(tr '\n' '|' <<<"$out")$(left)"
setbg bg.bin; out=$(MAGICK=fail run)
expect "a file magick cannot read: nothing sent, nothing recorded" "|not recorded|rc 0" "$(sent)|$(rec)|$(tail -1 <<<"$out")"

setbg bg.png; run > /dev/null
expect "a PNG: the file itself, no copy" "sent 4 data itself tokyo;|recorded" "$(sent)|$(rec)"
setbg bg.jpg; run > /dev/null
expect "a JPEG: the file itself" "sent 4 data itself tokyo;" "$(sent)"

setbg bg.mp4; out=$(BRIDGE=fail run)
expect "the Mac refuses it: an error, nothing recorded (tried again next time), no temp file left" \
  "rc 22|not recorded|" "$(tail -1 <<<"$out")|$(rec)|$(left)"

# Up to 3.4.1: magick's frame files (tmp.XXXXXXXXXX-N.png) stayed in the temp folder: they go once.
setbg bg.png
for f in tmp.AbCdEfGhIj-0.png tmp.AbCdEfGhIj-17.png tmp.AbCdEfGhIj.png tmp.short-1.png other-1.png tmp.AbCdEfGhIj-x.png; do : > "$TMP/$f"; done
run > /dev/null
expect "old frame files go, nothing else" "other-1.png tmp.AbCdEfGhIj-x.png tmp.AbCdEfGhIj.png tmp.short-1.png " "$(left)"
: > "$TMP/tmp.KlMnOpQrSt-3.png"; run > /dev/null
expect "... only once (a later file of that shape stays)" yes "$([[ -f $TMP/tmp.KlMnOpQrSt-3.png ]] && echo yes || echo no)"

(( fail == 0 )) && echo "wallpaper-video: all passed"
exit $fail
