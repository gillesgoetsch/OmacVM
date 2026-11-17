#!/bin/bash
# hdiutil-create.sh SECONDS ARGS...: `hdiutil create ARGS...` with a time limit, for tests.
# On 2026-11-07 `hdiutil create -fs HFS+` / `-fs JHFS+` hung inside newfs_hfs twice on the mini's CI host
# (app-move-vm.sh, app-storage.sh): the job sat until its 90-minute limit and newfs_hfs ran on as an orphan,
# its image still attached. On 11-08 `-fs APFS` (app-drive-drop.sh) hung the same way: newfs_apfs waited in
# open() of the new image's /dev/rdiskNs1, nobody else had it open (sample, lsof). So any file system.
# Past SECONDS this prints what hung (ps; a 2 s sample of each newfs_* process, its call graph's top
# lines, the whole sample in HDIUTIL_HANG_DIR or TMPDIR), kills hdiutil and its children (and newfs_*
# of the same -volname) and detaches the image (the last argument, any extension).
# Then it tries once more (with -ov, over the half-made image), only after a hang and only when the hung
# image is detached: the hang came back once a week or so on the mini (#740, #815, #824), never twice
# in a row. A second hang, or a hung image still attached, exits 124. The retry is said in the log
# (and as a warning on GitHub Actions), so a hang is never hidden. HDIUTIL_CREATE_TRIES: 1 = no retry.
# Any other failure: hdiutil's own exit code, at once.
# HDIUTIL_CREATE_BIN: another program in place of hdiutil (the test, src/tests/hdiutil-create-test.sh).
set -u
secs=${1:?usage: hdiutil-create.sh SECONDS ARGS...}; shift
tries=${HDIUTIL_CREATE_TRIES:-2}
img=${!#}
# the image as hdiutil info may name it: the path given or its real path (/private/var/... for /var/...)
real_img=$(cd -P "$(dirname "$img")" 2>/dev/null && pwd)/$(basename "$img")
vol=""; prev=""
for a in "$@"; do [[ $prev == -volname ]] && vol=$a; prev=$a; done

descendants() { local c; for c in $(pgrep -P "$1"); do echo "$c"; descendants "$c"; done; }
# the disks of this image that hdiutil still has attached
attached() {
  hdiutil info 2>/dev/null | awk -v i="$img" -v r="$real_img" '/^image-path/ { p = substr($0, index($0, ":") + 2) }
    /^\/dev\/disk[0-9]+[ \t]/ { if (index(p, i) == 1 || index(p, r) == 1) print $1 }' | sort -u
}

# create_once ARGS...: 0..n hdiutil's exit code; 124 hung (stopped, image detached); 125 hung, image left attached
create_once() {
  "${HDIUTIL_CREATE_BIN:-hdiutil}" create "$@" &
  local pid=$! end=$((SECONDS + secs)) hung p f d left=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS >= end )); then
      hung="$pid $(descendants "$pid")"
      [[ -n $vol ]] && hung+=" $(pgrep -f "newfs_[a-z]+ .*-v $vol( |$)" | tr '\n' ' ')"
      echo "hdiutil-create.sh: hdiutil create hung for $secs s ($img): killing it"
      ps -o pid=,ppid=,etime=,stat=,command= -p "$(echo $hung | tr ' ' ',')" 2>/dev/null | sed 's/^/  /'
      dir=${HDIUTIL_HANG_DIR:-${TMPDIR:-/tmp}}
      for p in $hung; do
        [[ $(ps -o command= -p "$p" 2>/dev/null) == *newfs_* ]] || continue
        f=${dir%/}/hdiutil-hang-$p.txt
        sample "$p" 2 -file "$f" >/dev/null 2>&1 && { echo "  sample of $p: $f"; sed -n '/^Call graph:/,/^$/p' "$f" | head -25 | sed 's/^/  /'; }
      done
      kill -9 $hung 2>/dev/null
      wait "$pid" 2>/dev/null
      for d in $(attached); do
        if hdiutil detach -force "$d" >/dev/null 2>&1; then echo "  detached $d"; else echo "  could not detach $d"; left=1; fi
      done
      return $((124 + left))
    fi
    sleep 1
  done
  wait "$pid"
}

try=1
while :; do
  if (( try == 1 )); then create_once "$@"; else create_once -ov "$@"; fi
  rc=$?
  (( rc == 124 || rc == 125 )) || exit "$rc"
  if (( rc == 125 )); then echo "hdiutil-create.sh: the hung image is still attached: no new try"; exit 124; fi
  if (( try >= tries )); then echo "hdiutil-create.sh: hung on all $tries tries ($img)"; exit 124; fi
  try=$((try + 1))
  msg="stopped a hung hdiutil create ($img): try $try of $tries"
  echo "hdiutil-create.sh: $msg"
  [[ ${GITHUB_ACTIONS:-} == true ]] && echo "::warning title=hdiutil create hung::$msg"
done
