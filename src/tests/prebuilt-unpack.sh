#!/bin/bash
# The prebuilt disk comes out of its tar stream with src/prebuilt/unpack.py,
# not tar -xS: the file is made at its full size first and every write lands
# inside it, so APFS never fills a gap past the end with zeros (2026-11-11:
# bsdtar's last write, 56 GB past the end, took 61 GB and filled a Mac). Here:
# the same bytes as bsdtar gives, sparse; every odd archive refused with the
# file gone; the free-space floor and the allocation bound stop it; the unpack
# folder is cleared only when it carries OmacVM's marker; the message reaches
# the app. Under every python3 found (the app's own 3.13 when built, or
# OMACVM_TEST_PYTHON). macOS only (APFS holes).
#   src/tests/prebuilt-unpack.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
[[ $(uname) == Darwin ]] || { echo "skip: macOS only"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
U=$R/src/prebuilt/unpack.py
kb() { echo $(( $(stat -f %b "$1") / 2 )); }
GIB=1073741824

# A 1 GiB raw disk shaped like the image's: data at the start, at 20 MiB, and
# a 1 MiB region in the last MiB (the backup GPT), holes between.
mkdir -p "$T/w/Omarchy"; d=$T/w/Omarchy/disk.img
: > "$d"; truncate -s $GIB "$d" 2>/dev/null || dd if=/dev/null of="$d" bs=1 seek=$GIB 2>/dev/null
printf 'start' | dd of="$d" conv=notrunc status=none
dd if=/dev/urandom of="$d" bs=4k count=3 seek=$(( 20 * 256 + 5 )) conv=notrunc status=none
dd if=/dev/urandom of="$d" bs=1m count=1 seek=1023 conv=notrunc status=none
COPYFILE_DISABLE=1 tar --no-xattrs --uid 0 --gid 0 --uname root --gname root -C "$T/w" -cf "$T/img.tar" Omarchy
expect "test archive is GNU sparse 1.0 (as make-image.sh writes)" 1 \
  "$(( $(LC_ALL=C grep -c -a 'GNU.sparse.major=1' "$T/img.tar") > 0 ))"
want=$(tar -xOf "$T/img.tar" Omarchy/disk.img | shasum -a 256)

# Every python3 here: PATH's, and the app's own (built by fetch-python.sh).
pys=(python3)
for p in "${OMACVM_TEST_PYTHON:-}" "$R"/app/.build/python-*/python/bin/python3; do
  [[ -n $p && -x $p ]] && pys+=("$p")
done
(( ${#pys[@]} > 1 )) || echo "note: no app python3 here (app/.build or OMACVM_TEST_PYTHON): PATH's only"

for py in "${pys[@]}"; do
  v=$("$py" -I -c 'import sys; print("%d.%d" % sys.version_info[:2])')
  x() { "$py" -I "$U" "$@"; }
  o=$T/out-$v.img; rm -f "$o"
  x extract Omarchy/disk.img "$o" $GIB < "$T/img.tar"; rc=$?
  expect "py $v: extract runs" 0 "$rc"
  expect "py $v: the same bytes as bsdtar" "$want" "$(shasum -a 256 < "$o")"
  expect "py $v: full size" $GIB "$(stat -f %z "$o")"
  expect "py $v: sparse (data only, 2 MiB at most)" 1 "$(( $(kb "$o") <= 2048 ))"
  expect "py $v: refuses an existing file" 1 "$(x extract Omarchy/disk.img "$o" $GIB < "$T/img.tar" 2>/dev/null; echo $?)"
  ln -s "$T/victim" "$T/link-$v"
  expect "py $v: refuses a symlink as OUT" 1 "$(x extract Omarchy/disk.img "$T/link-$v" $GIB < "$T/img.tar" 2>/dev/null; echo $?)"
  expect "py $v: nothing made through it" no "$([[ -e $T/victim ]] && echo yes || echo no)"
  c=$T/copy-$v.img
  x copy "$o" "$c"; expect "py $v: copy runs" 0 $?
  expect "py $v: copy: same bytes" "$want" "$(shasum -a 256 < "$c")"
  expect "py $v: copy: sparse" 1 "$(( $(kb "$c") <= 2048 ))"
  rm -f "$c"
done
py=${pys[${#pys[@]}-1]}
x() { "$py" -I "$U" "$@"; }

# refused WHAT ARCHIVE [SIZE] [OPTS...]: exit 1, a message, no file left.
refused() {
  local what=$1 a=$2 size=${3:-$GIB} o=$T/r.img err; shift 3 2>/dev/null || shift $#
  rm -f "$o"
  err=$(x extract Omarchy/disk.img "$o" "$size" "$@" < "$a" 2>&1 >/dev/null); local rc=$?
  expect "refused: $what" "1 yes no" "$rc $([[ -n $err ]] && echo yes || echo no) $([[ -e $o ]] && echo yes || echo no)"
  LAST=$err
}
refused "a disk of another size than the manifest's" "$T/img.tar" $(( 2 * GIB ))
expect "  says so" yes "$([[ $LAST == *"manifest says"* ]] && echo yes || echo "$LAST")"
head -c 600000 "$T/img.tar" > "$T/short.tar"
refused "an archive that ends early" "$T/short.tar"
expect "  says so" yes "$([[ $LAST == *"ended early"* ]] && echo yes || echo "$LAST")"
cp "$T/img.tar" "$T/bad.tar"; printf 'X' | dd of="$T/bad.tar" bs=1 seek=10 conv=notrunc status=none
refused "a damaged header" "$T/bad.tar"
refused "the free-space floor (before the first byte)" "$T/img.tar" $GIB --min-free 999999999999999999
expect "  says the disk is nearly full" yes "$([[ $LAST == "Stopped: the Mac's disk is nearly full"*"The unfinished VM was removed." ]] && echo yes || echo "$LAST")"
refused "the allocation bound" "$T/img.tar" $GIB --max-alloc 4096
expect "  says what it took" yes "$([[ $LAST == "Stopped: disk.img took"* ]] && echo yes || echo "$LAST")"

# The test hook: OMACVM_TEST_FREE_FILE's number (KiB) counts as the free space
# when it is smaller than the volume's, never when bigger, and it is read at
# every check, so guard rows need no full volume (PANIC-1111).
export OMACVM_TEST_FREE_FILE=$T/free
echo 1 > "$T/free"
refused "hook: 1 KiB free, floor 1 GiB (before the first byte)" "$T/img.tar" $GIB --min-free $GIB
expect "  says the disk is nearly full" yes "$([[ $LAST == "Stopped: the Mac's disk is nearly full (0.0 GB free). The unfinished VM was removed." ]] && echo yes || echo "$LAST")"
echo 999999999999999 > "$T/free"
refused "hook: a number bigger than the volume's free space does not count" "$T/img.tar" $GIB --min-free 999999999999999999
for v in abc "" 2097152; do
  echo "$v" > "$T/free"; rm -f "$T/h.img"
  x extract Omarchy/disk.img "$T/h.img" $GIB --min-free $GIB < "$T/img.tar" 2>/dev/null
  expect "hook: '$v' (bad, empty, 2 GiB over a 1 GiB floor): runs" "0 $GIB" "$? $(stat -f %z "$T/h.img" 2>/dev/null)"
done
# Free space that drops while it runs: a plain 1 GiB member of zeros (takes no
# blocks); the feeder lowers the number after 300 MiB, so the check at 256 MiB
# passes and the one at 512 MiB stops it.
feed() {
  python3 -c '
import sys, tarfile
i = tarfile.TarInfo("Omarchy/disk.img"); i.size = 1 << 30
out, sent, z = sys.stdout.buffer, 0, bytes(1 << 20)
try:
    out.write(i.tobuf(tarfile.USTAR_FORMAT))
    while sent < i.size:
        if sent == 300 << 20:
            out.flush()
            with open(sys.argv[1], "w") as f:
                f.write("1\n")
        out.write(z)
        sent += len(z)
    out.write(bytes(1024))
    out.flush()
except BrokenPipeError:
    pass
with open(sys.argv[2], "w") as f:
    f.write("%d\n" % (sent >> 20))
' "$T/free" "$T/fed" 2>/dev/null
}
echo 999999999999999 > "$T/free"; rm -f "$T/h.img"
feed | x extract Omarchy/disk.img "$T/h.img" $GIB --min-free $GIB 2> "$T/h.err"
rc=${PIPESTATUS[1]}; fed=$(cat "$T/fed")
expect "hook: free space dropping mid-run stops it, file gone" "1 no" "$rc $([[ -e $T/h.img ]] && echo yes || echo no)"
expect "  between the checks (300 < MiB sent < 1024)" 1 "$(( fed > 300 && fed < 1024 ))"
expect "  with the message" yes "$([[ $(tail -n 1 "$T/h.err") == "Stopped: the Mac's disk is nearly full (0.0 GB free). The unfinished VM was removed." ]] && echo yes || cat "$T/h.err")"
unset OMACVM_TEST_FREE_FILE

# Archives made by hand (tarfile writes them; unpack.py does not use it).
mk() {   # mk NAME KIND: an odd archive into $T/NAME.tar
  python3 - "$T/$1.tar" "$2" "$T/victim" <<'PY'
import io, sys, tarfile
path, kind, victim = sys.argv[1:]
def f(t, name, data=b"x"):
    i = tarfile.TarInfo(name); i.size = len(data); t.addfile(i, io.BytesIO(data))
def member(t, body, real, name="Omarchy/disk.img"):
    i = tarfile.TarInfo("Omarchy/GNUSparseFile.0/disk.img"); i.size = len(body)
    i.pax_headers = {"GNU.sparse.major": "1", "GNU.sparse.minor": "0", "GNU.sparse.name": name,
                     "GNU.sparse.realsize": str(real)}
    t.addfile(i, io.BytesIO(body))
def sparse(t, regions, real, data=None):   # GNU sparse 1.0, as bsdtar writes it
    m = ("%d\n" % len(regions) + "".join("%d\n%d\n" % r for r in regions)).encode()
    m += bytes(-len(m) % 512)
    member(t, m + (data if data is not None else b"".join(b"\1" * n for _, n in regions)), real)
G = 1 << 30
with tarfile.open(path, "w", format=tarfile.PAX_FORMAT) as t:
    d = tarfile.TarInfo("Omarchy"); d.type = tarfile.DIRTYPE; t.addfile(d)
    if kind == "other-after": sparse(t, [(0, 512)], G); f(t, "Omarchy/other")
    elif kind == "other-before": f(t, "Omarchy/other"); sparse(t, [(0, 512)], G)
    elif kind == "outside": f(t, "../disk.img")
    elif kind == "twice": sparse(t, [(0, 512)], G); sparse(t, [(0, 512)], G)
    elif kind == "symlink":
        i = tarfile.TarInfo("Omarchy/disk.img"); i.type = tarfile.SYMTYPE; i.linkname = victim; t.addfile(i)
    elif kind == "hardlink":
        i = tarfile.TarInfo("Omarchy/disk.img"); i.type = tarfile.LNKTYPE; i.linkname = victim; t.addfile(i)
    elif kind == "past-end": sparse(t, [(0, 512), (G, 4096)], G)
    elif kind == "overlap": sparse(t, [(4096, 512), (0, 8192)], G)
    elif kind == "map-mismatch": sparse(t, [(0, 512)], G, data=b"\1" * 1024)
    elif kind == "huge-map": member(t, b"99999999999\n" + bytes(500), G)
    elif kind == "old-sparse":
        i = tarfile.TarInfo("Omarchy/disk.img"); i.size = 1
        i.pax_headers = {"GNU.sparse.offset": "0", "GNU.sparse.numbytes": "1", "GNU.sparse.size": str(G)}
        t.addfile(i, io.BytesIO(b"x"))
    elif kind == "none": f(t, "Omarchy/other.img")
    elif kind == "plain-ok": sparse(t, [(0, 4096), (G - 4096, 4096)], G)
PY
}
echo secret > "$T/victim"
for k in other-after other-before outside twice symlink hardlink past-end overlap map-mismatch huge-map old-sparse none; do
  mk "$k" "$k"; refused "$k" "$T/$k.tar"; echo "       ($LAST)"
done
expect "a link's target untouched, one link" "secret 1" "$(cat "$T/victim") $(stat -f %l "$T/victim")"
mk plain-ok plain-ok; rm -f "$T/p.img"
x extract Omarchy/disk.img "$T/p.img" $GIB < "$T/plain-ok.tar"
expect "a hand-made sparse archive: taken, data at both ends" "$GIB 1" \
  "$(stat -f %z "$T/p.img") $(( $(head -c 1 "$T/p.img" | od -An -tu1) == 1 && $(tail -c 1 "$T/p.img" | od -An -tu1) == 1 ))"
expect "  and sparse" 1 "$(( $(kb "$T/p.img") <= 1024 ))"

# lib.sh: the whole unpack as prebuilt-vm.sh runs it.
if command -v zstd >/dev/null; then
  (
    source "$R/src/lib/mac.sh"; source "$R/src/prebuilt/lib.sh"
    PREBUILT_CACHE=$T/cache; mkdir -p "$T/cache/app"
    part=omacvm-prebuilt-9.9.9-app.tar.zst.part-aa
    zstd -q -c --long=27 "$T/img.tar" > "$T/cache/app/$part"
    printf '{"parts": [{"name": "%s", "size": %s, "sha256": "%s"}]}' "$part" "$(stat -f %z "$T/cache/app/$part")" \
      "$(shasum -a 256 < "$T/cache/app/$part" | cut -d' ' -f1)" > "$T/cache/app/m.json"
    # manifest.py parts checks a signed manifest; here only the list matters.
    python3() { if [[ ${1:-} == */manifest.py && ${2:-} == parts ]]; then echo "$part 0 0"; else command python3 "$@"; fi; }
    PB_MANIFEST=$T/cache/app/m.json PB_BUNDLE=Omarchy PB_DISK_GB=1 PB_UNPACKED_KB=2048
    V=$T/vm; mkdir -p "$V"
    run() { rm -f "$V/disk.img"; (prebuilt_unpack_disk "$V/.unpack" "$V/disk.img") 2>&1; }
    out=$(run); rc=$?
    expect "lib: unpacked" 0 "$rc"
    expect "lib: the same bytes" "$want" "$(shasum -a 256 < "$V/disk.img")"
    expect "lib: sparse, no warning" "1 no" "$(( $(kb "$V/disk.img") <= 2048 )) $([[ $out == *WARN* ]] && echo yes || echo no)"
    expect "lib: the unpack folder is gone" no "$([[ -e $V/.unpack ]] && echo yes || echo no)"
    out=$(PREBUILT_MAC_RESERVE_KB=999999999999999; run); rc=$?
    expect "lib: the floor stops it" 1 "$rc"
    expect "lib: its message is the one shown" yes "$([[ $out == *"Stopped: the Mac's disk is nearly full"* ]] && echo yes || echo "$out")"
    expect "lib: nothing left" "no no" "$([[ -e $V/disk.img ]] && echo yes || echo no) $([[ -e $V/.unpack ]] && echo yes || echo no)"
    out=$(echo 1 > "$T/free"; export OMACVM_TEST_FREE_FILE=$T/free; run); rc=$?
    expect "lib: the hook's 1 KiB stops it, with the message, nothing left" "1 yes no no" \
      "$rc $([[ $out == *"Stopped: the Mac's disk is nearly full (0.0 GB free)"* ]] && echo yes || echo "$out") $([[ -e $V/disk.img ]] && echo yes || echo no) $([[ -e $V/.unpack ]] && echo yes || echo no)"
    # A stop partway, with zstd still writing: the reason is a line of its own
    # (zstd -q wrote "zstd: " with no newline into it when the pipe closed).
    python3 -c '
import sys, tarfile
i = tarfile.TarInfo("Omarchy/disk.img"); i.size = 1 << 30
o = sys.stdout.buffer; o.write(i.tobuf(tarfile.USTAR_FORMAT)); z = bytes(1 << 20)
for _ in range(1024): o.write(z)
o.write(bytes(1024))' | zstd -q -c --long=27 > "$T/cache/app/$part"
    out=$(echo 1 > "$T/free"; export OMACVM_TEST_FREE_FILE=$T/free; run); rc=$?
    expect "lib: stopped with zstd mid-stream: the reason starts its own line" "1 yes no" \
      "$rc $(grep -q "^$(printf '\033')\[1;31merror:$(printf '\033')\[0m Stopped: the Mac's disk is nearly full" <<<"$out" && echo yes || echo "$out") $([[ $out == *"zstd:"* ]] && echo yes || echo no)"
    zstd -q -c --long=27 "$T/img.tar" > "$T/cache/app/$part"
    out=$(PB_DISK_GB=2; run); rc=$?
    expect "lib: a disk of another size is refused, with the reason" "1 yes" "$rc $([[ $out == *"manifest says"* ]] && echo yes || echo "$out")"
    # What a killed run leaves: marked, so the next run clears it.
    mkdir -p "$V/.unpack"; : > "$V/.unpack/$PREBUILT_UNPACK_MARK"; mkfile -n 1m "$V/.unpack/disk.img"
    out=$(run); rc=$?
    expect "lib: a marked leftover is cleared and the unpack runs" "0 yes" "$rc $([[ -f $V/disk.img ]] && echo yes || echo no)"
    rm -f "$V/disk.img"; mkdir -p "$V/.unpack"; echo mine > "$V/.unpack/keep"
    out=$(run); rc=$?
    expect "lib: an unmarked folder is not OmacVM's: refused" "1 yes" "$rc $([[ $out == *"not made by OmacVM"* ]] && echo yes || echo "$out")"
    expect "lib: and left as it was" mine "$(cat "$V/.unpack/keep")"
    expect "lib: drop leaves it too" "1 mine" "$(prebuilt_unpack_drop "$V/.unpack"; echo "$? $(cat "$V/.unpack/keep")")"
    rm -rf "$V/.unpack"; ln -s "$T/w" "$V/.unpack"
    expect "lib: a symlink as the folder is not cleared" "1 yes" "$(prebuilt_unpack_drop "$V/.unpack"; echo "$? $([[ -d $T/w/Omarchy ]] && echo yes || echo no)")"
    rm -f "$V/.unpack"
    (( fail )) && exit 1; exit 0
  ) || fail=1
else
  echo "skip lib.sh tests: no zstd"
fi

# The free-space check: the VM disk, the download (same drive) and 10 GiB for
# macOS, the app's own reserve (DiskSize.macReserve).
(
  source "$R/src/lib/mac.sh"; source "$R/src/prebuilt/lib.sh"
  PREBUILT_CACHE=$T/c2; free=$(df -Pk "$T" | awk 'NR == 2 { print $4 }')
  PB_SIZE=$(( 3 * 1000000000 )) PB_UNPACKED_KB=$(( free - PREBUILT_MAC_RESERVE_KB - 3 * 1000000000 / 1024 + 524288 ))
  (( PB_UNPACKED_KB > 2097152 )) || { echo "skip space rows: too little free here"; exit 0; }
  out=$(prebuilt_space_ok "$T" 2>&1); rc=$?
  expect "space: 512 MiB short of disk + download + reserve: refused" 1 "$rc"
  expect "space: says what for" yes "$([[ $out == "Not enough free space on "*"GB needed (VM disk "*" GB, download 3.0 GB, 10.7 GB kept free for macOS), "*" GB free. Free some space and try again." ]] && echo yes || echo "$out")"
  PB_UNPACKED_KB=$(( PB_UNPACKED_KB - 2621440 ))
  expect "space: 2 GiB to spare: fine" 0 "$(prebuilt_space_ok "$T" >/dev/null 2>&1; echo $?)"
  # The hook: 1 GiB disk + 1 GB download + 10 GiB reserve = 11.9 GiB needed.
  PB_SIZE=1000000000 PB_UNPACKED_KB=1048576
  (( free > 13 * 1048576 )) || { echo "skip space hook rows: too little free here"; exit $fail; }
  export OMACVM_TEST_FREE_FILE=$T/free
  echo $(( 11 * 1048576 )) > "$T/free"
  out=$(prebuilt_space_ok "$T" 2>&1); rc=$?
  expect "space: the hook's 11 GiB: refused up front, with its number" "1 yes" \
    "$rc $([[ $out == "Not enough free space on "*"12.8 GB needed (VM disk 1.1 GB, download 1.0 GB, 10.7 GB kept free for macOS), 11.8 GB free. Free some space and try again." ]] && echo yes || echo "$out")"
  echo $(( 13 * 1048576 )) > "$T/free"
  expect "space: the hook's 13 GiB: fine" 0 "$(prebuilt_space_ok "$T" >/dev/null 2>&1; echo $?)"
  echo 999999999999999 > "$T/free"; PB_UNPACKED_KB=$(( free - PREBUILT_MAC_RESERVE_KB ))
  expect "space: a hook number bigger than df's does not count" 1 "$(prebuilt_space_ok "$T" >/dev/null 2>&1; echo $?)"
  unset OMACVM_TEST_FREE_FILE
  (( fail )) && exit 1; exit 0
) || fail=1
expect "reserve: the same 10 GiB as DiskSize.macReserve" "1 1" \
  "$(grep -c 'macReserve: Int64 = 10 \* gib' "$R/app/app/Sources/OmacVMWindow/DiskSize.swift") $(grep -c '^PREBUILT_MAC_RESERVE_KB=10485760$' "$R/src/prebuilt/lib.sh")"

# prebuilt-vm.sh: a leftover goes before the space check; the trap removes only a marked folder.
P=$R/app/scripts/prebuilt-vm.sh
expect "setup: leftover cleared before the space check" 1 \
  "$(grep -A1 'prebuilt_unpack_drop "$VM_DIR/.unpack" || die' "$P" | grep -c 'prebuilt_space_ok')"
expect "setup: no unmarked rm -rf of the unpack folder" 0 "$(grep -c 'rm -rf "$VM_DIR/.unpack"' "$P")"
expect "no tar -xS left for the disk (code, not comments)" 0 "$(cat "$R/src/prebuilt/lib.sh" "$R/src/prebuilt/make-image.sh" | grep -c '^[^#]*tar -xS')"
expect "no dd conv=sparse left in make-image.sh" 0 "$(grep -c '^[^#]*conv=sparse' "$R/src/prebuilt/make-image.sh")"
expect "make-image.sh: package and repack use unpack.py" "1 1" \
  "$(grep -c 'unpack.py" copy "$b/disk.img" "$stage/disk.img"' "$R/src/prebuilt/make-image.sh") $(grep -c 'unpack.py" extract "$PREBUILT_NAME/disk.img" "$stage/disk.img"' "$R/src/prebuilt/make-image.sh")"

(( fail )) && { echo "prebuilt-unpack: FAILED"; exit 1; }
echo "prebuilt-unpack: all passed"
