#!/usr/bin/env python3
"""The prebuilt image's disk out of its tar stream, sparse and bounded.

    unpack.py extract MEMBER OUT SIZE [--max-alloc BYTES] [--min-free BYTES] < tar
    unpack.py copy SRC OUT [--min-free BYTES]

extract: MEMBER (e.g. Omarchy/disk.img) out of the tar on stdin into OUT, a
new file. The archive may hold the member's folder and the member, nothing
else: any other entry, a link, a member of another SIZE (the signed manifest's
disk size), a sparse region past SIZE or an archive that ends early is
refused. It stops at the archive's end marker; the caller reads the rest.
copy: SRC into OUT, a new file of the same size (make-image.sh).

Why not tar -xS: bsdtar writes a sparse file's last region with a seek and a
write that starts far past the end of the file (the disk's backup GPT, 56 GB
past its data), and APFS sometimes fills that gap with real zero blocks inside
that one write: 61 GB of zeros, a full Mac (2026-11-11, work/prebuilt-unpack-1111).
Here OUT is made at its full size while it is still empty (one hole), and
every write lands inside that size; all-zero 64 KiB chunks stay holes. As
FolderMover.copy does for a VM that moves (Storage.swift).

Every 256 MiB it checks the volume's free space (statvfs, not the "important"
figure that counts purgeable space) against --min-free and what OUT takes on
the Mac against --max-alloc, and stops with a message before the Mac fills.
On any failure OUT (which it made) is removed and the exit status is 1; the
message is the last line on stderr.

The format is the one make-image.sh writes with macOS's tar: ustar headers,
pax extended headers, GNU sparse 1.0 (the map at the start of the data). Its
own parser: tarfile's stream internals differ between Python versions.
Python 3.9 and later (Command Line Tools' and OmacVM.app's own).
"""
import os
import sys

BLOCK = 512
CHUNK = 1 << 16          # holes are made per 64 KiB
READ = 1 << 20
CHECK_EVERY = 256 << 20
ZERO = bytes(CHUNK)
MAX_PAX = 1 << 20        # a pax header bigger than this is not ours
MAX_REGIONS = 1 << 20


class Refused(Exception):
    pass


def gb(n):
    return "%.1f" % (n / 1e9)


def printable(s):
    return "".join(c if " " <= c <= "~" else "?" for c in s)[:120]


class Stream:
    """Exact reads from a pipe, counting the bytes taken."""

    def __init__(self, f):
        self.f = f

    def read(self, n):
        out = bytearray()
        while len(out) < n:
            b = self.f.read(min(n - len(out), READ))
            if not b:
                raise Refused("the image ended early (a part missing or cut short?)")
            out += b
        return bytes(out)

    def skip(self, n):
        while n:
            n -= len(self.read(min(n, READ)))


def octal(field, what):
    if field and field[0] & 0x80:            # base-256 (GNU, big sizes)
        if field[0] & 0x40:
            raise Refused("negative %s in the image" % what)
        v = field[0] & 0x3F
        for b in field[1:]:
            v = (v << 8) | b
        return v
    s = field.split(b"\0", 1)[0].strip(b" ")
    if not s:
        return 0
    try:
        return int(s, 8)
    except ValueError:
        raise Refused("bad %s in the image's archive" % what)


def header(blk):
    """A ustar header's fields; None for the end marker (a zero block)."""
    if blk == bytes(BLOCK):
        return None
    want = octal(blk[148:156], "header checksum")
    if want != sum(blk[:148]) + 8 * 32 + sum(blk[156:]):
        raise Refused("the image's archive is damaged (header checksum)")
    if blk[257:262] != b"ustar":
        raise Refused("the image's archive is not a ustar/pax tar")
    name = blk[0:100].split(b"\0", 1)[0]
    prefix = blk[345:500].split(b"\0", 1)[0] if blk[257:263] == b"ustar\0" else b""
    if prefix:
        name = prefix + b"/" + name
    return {
        "name": name.decode("utf-8", "replace"),
        "size": octal(blk[124:136], "size"),
        "type": blk[156:157] or b"\0",
    }


def pax_records(data):
    """'LEN key=value\\n' records into a dict (strict)."""
    out, i = {}, 0
    while i < len(data):
        sp = data.find(b" ", i)
        if sp < 0:
            raise Refused("bad pax header in the image")
        try:
            n = int(data[i:sp])
        except ValueError:
            raise Refused("bad pax header in the image")
        rec = data[sp + 1:i + n]
        if n <= 0 or i + n > len(data) or not rec.endswith(b"\n") or b"=" not in rec:
            raise Refused("bad pax header in the image")
        k, v = rec[:-1].split(b"=", 1)
        out[k.decode("utf-8", "replace")] = v.decode("utf-8", "replace")
        i += n
    return out


def number(s, what, top=1 << 62):
    if not s.isdigit() or len(s) > 19 or int(s) > top:
        raise Refused("bad %s in the image" % what)
    return int(s)


def clean(name):
    while name.startswith("./"):
        name = name[2:]
    return name.rstrip("/")


class Writer:
    """OUT made at SIZE while empty, then only written inside SIZE."""

    def __init__(self, path, size, max_alloc, min_free):
        self.path, self.size = path, size
        self.max_alloc, self.min_free = max_alloc, min_free
        self.dir = os.path.dirname(os.path.abspath(path))
        self.since = 0
        self.fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
        try:
            self.check()                     # before the first byte
            os.ftruncate(self.fd, size)      # the whole disk one hole, while it is empty
        except BaseException:
            self.drop()
            raise

    def check(self):
        if self.min_free:
            st = os.statvfs(self.dir)
            free = st.f_bavail * st.f_frsize
            if free < self.min_free:
                raise Refused("Stopped: the Mac's disk is nearly full (%s GB free). The unfinished VM was removed." % gb(free))
        if self.max_alloc:
            took = os.fstat(self.fd).st_blocks * 512
            if took > self.max_alloc:
                raise Refused("Stopped: disk.img took %s GB on the Mac, more than the %s GB it may take. "
                              "The unfinished VM was removed." % (gb(took), gb(self.max_alloc)))

    def write(self, off, data):
        """DATA at OFF (inside SIZE); all-zero 64 KiB chunks are skipped."""
        if off < 0 or off + len(data) > self.size:
            raise Refused("the image writes past its disk's end: not used")
        mv = memoryview(data)
        for i in range(0, len(data), CHUNK):
            c = mv[i:i + CHUNK]
            if c != ZERO[:len(c)]:
                done = 0
                while done < len(c):
                    done += os.pwrite(self.fd, c[done:], off + i + done)
        self.since += len(data)
        if self.since >= CHECK_EVERY:
            self.since = 0
            self.check()

    def close(self):
        self.check()
        os.close(self.fd)
        self.fd = None

    def drop(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass


def sparse_map(src, stored):
    """GNU sparse 1.0: decimal lines at the data's start: N, then N offset/size pairs."""
    nums, buf, used = [], b"", 0
    while True:
        if used >= stored:
            raise Refused("bad sparse map in the image")
        buf += src.read(BLOCK)
        used += BLOCK
        lines = buf.split(b"\n")
        buf = lines.pop()
        for ln in lines:
            nums.append(number(ln.decode("ascii", "replace"), "sparse map"))
            if nums[0] > MAX_REGIONS:
                raise Refused("bad sparse map in the image")
            if len(nums) == 1 + 2 * nums[0]:
                regions = [(nums[i], nums[i + 1]) for i in range(1, len(nums), 2)]
                return regions, used
        if len(buf) > 20:
            raise Refused("bad sparse map in the image")


def extract(member, out, size, max_alloc, min_free, f):
    src = Stream(f)
    member = clean(member)
    folder = member.rsplit("/", 1)[0] if "/" in member else ""
    pax, done, w = {}, False, None
    try:
        while True:
            h = header(src.read(BLOCK))
            if h is None:
                break
            n, t = h["size"], h["type"]
            if t == b"x":
                if n > MAX_PAX:
                    raise Refused("bad pax header in the image")
                pax = pax_records(src.read(-(-n // BLOCK) * BLOCK)[:n])
                continue
            name = clean(pax.get("GNU.sparse.name") or pax.get("path") or h["name"])
            if "size" in pax:
                n = number(pax["size"], "size")
            if t == b"5" and not done and name in ("", ".", folder) and n == 0:
                pax = {}
                continue
            if name == member and not done and t not in (b"0", b"\0"):
                raise Refused("the image's %s is not a plain file: not used" % member)
            if t not in (b"0", b"\0") or name != member or done:
                raise Refused("the image holds something other than %s (%s): not used" % (member, printable(name)))
            if pax.get("GNU.sparse.major") == "1" and pax.get("GNU.sparse.minor") == "0":
                real = number(pax.get("GNU.sparse.realsize", ""), "disk size")
                regions, used = sparse_map(src, n)
            elif any(k.startswith("GNU.sparse.") for k in pax):
                raise Refused("the image's sparse format is not one OmacVM reads: not used")
            else:
                real, regions, used = n, [(0, n)], 0
            if real != size:
                raise Refused("the image's disk is %d bytes, its manifest says %d: not used" % (real, size))
            end = 0
            for off, ln in regions:
                if off < end or off + ln > size:
                    raise Refused("the image's sparse map is out of order or past the disk's end: not used")
                end = off + ln
            if sum(ln for _, ln in regions) != n - used:
                raise Refused("the image's sparse map does not match its data: not used")
            w = Writer(out, size, max_alloc, min_free)
            for off, ln in regions:
                while ln:
                    b = src.read(min(ln, READ))
                    w.write(off, b)
                    off += len(b)
                    ln -= len(b)
            src.skip(-n % BLOCK)
            w.close()
            done, pax = True, {}
        if not done:
            raise Refused("the image holds no %s: not used" % member)
    except BaseException:
        if w is not None:
            w.drop()
        raise


def copy(path, out, min_free):
    with open(path, "rb") as f:
        size = os.fstat(f.fileno()).st_size
        w = Writer(out, size, 0, min_free)
        try:
            off = 0
            while off < size:
                b = f.read(READ)
                if not b:
                    raise Refused("%s got shorter while it was copied" % path)
                w.write(off, b)
                off += len(b)
            w.close()
        except BaseException:
            w.drop()
            raise


def main(argv):
    opts = {"--max-alloc": 0, "--min-free": 0}
    args = []
    i = 0
    while i < len(argv):
        if argv[i] in opts and i + 1 < len(argv) and argv[i + 1].isdigit():
            opts[argv[i]] = int(argv[i + 1])
            i += 2
        else:
            args.append(argv[i])
            i += 1
    try:
        if len(args) == 4 and args[0] == "extract" and args[3].isdigit():
            extract(args[1], args[2], int(args[3]), opts["--max-alloc"], opts["--min-free"], sys.stdin.buffer)
        elif len(args) == 3 and args[0] == "copy" and not opts["--max-alloc"]:
            copy(args[1], args[2], opts["--min-free"])
        else:
            sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
            return 2
    except Refused as e:
        sys.stderr.write("%s\n" % e)
        return 1
    except OSError as e:
        sys.stderr.write("could not unpack the image: %s\n" % (e.strerror or e))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
