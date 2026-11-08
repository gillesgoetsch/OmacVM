#!/bin/bash
# hdiutil-create.sh SECONDS ARGS...: `hdiutil create ARGS...` with a time limit, for tests.
# On 2026-11-07 `hdiutil create -fs HFS+` / `-fs JHFS+` hung inside newfs_hfs twice on the mini's CI host
# (app-move-vm.sh, app-storage.sh): the job sat until its 90-minute limit and newfs_hfs ran on as an orphan,
# its image still attached. On 11-08 `-fs APFS` (app-drive-drop.sh) hung the same way: newfs_apfs waited in
# open() of the new image's /dev/rdiskNs1, nobody else had it open (sample, lsof). So any file system.
# Past SECONDS this prints what hung (ps; a 2 s sample of each newfs_* process, its call graph's top
# lines, the whole sample in HDIUTIL_HANG_DIR or TMPDIR), kills hdiutil and its children (and newfs_*
# of the same -volname), detaches the image (the last argument, any extension) and exits 124.
# Otherwise hdiutil's own exit code.
# HDIUTIL_CREATE_BIN: another program in place of hdiutil (the test, src/tests/hdiutil-create-test.sh).
set -u
secs=${1:?usage: hdiutil-create.sh SECONDS ARGS...}; shift
img=${!#}
vol=""; prev=""
for a in "$@"; do [[ $prev == -volname ]] && vol=$a; prev=$a; done
"${HDIUTIL_CREATE_BIN:-hdiutil}" create "$@" &
pid=$!
end=$((SECONDS + secs))
while kill -0 "$pid" 2>/dev/null; do
  if (( SECONDS >= end )); then
    descendants() { local c; for c in $(pgrep -P "$1"); do echo "$c"; descendants "$c"; done; }
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
    hdiutil info 2>/dev/null | awk -v i="$img" '/^image-path/ { p = substr($0, index($0, ":") + 2) }
      /^\/dev\/disk[0-9]+[ \t]/ { if (index(p, i) == 1) print $1 }' | sort -u |
      while read -r d; do hdiutil detach -force "$d" >/dev/null 2>&1 && echo "  detached $d" || echo "  could not detach $d"; done
    exit 124
  fi
  sleep 1
done
wait "$pid"
