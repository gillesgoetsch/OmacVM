#!/bin/bash
# The prebuilt images for Parallels, UTM and VMware Fusion are untrusted until
# checked: only the route's own files come out of the archive, as plain files,
# and settings or disks that point at other files on the Mac are refused.
# Small made-up images (fixtures), no network, no VM.
#   src/tests/prebuilt-routes.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/ui.sh"
source "$R/src/lib/mac.sh"
source "$R/src/prebuilt/lib.sh"
source "$R/src/prebuilt/vm.sh"
command -v zstd >/dev/null || { echo "zstd is missing (brew install zstd)"; exit 1; }
fail=0
T=$(mktemp -d)
T=$(cd "$T" && pwd -P)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
export OMACVM_PREBUILT_SOURCE=$T/src
source "$R/src/tests/release-test-keys.sh"
VERSION=$(cat "$R/src/VERSION")
mkdir -p "$T/outside"
echo secret > "$T/outside/secret"

expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# The fixtures: a tar of a small bundle for ROUTE, changed as VARIANT says.
cat > "$T/fixture.py" <<'PY'
import io, plistlib, struct, sys, tarfile
route, variant, out, outside = sys.argv[1:5]
HDS = "omarchy.hdd.0.{5fbaabe3-6958-40ff-92a7-860e329aab41}.hds"
QC = "581A7F81-C6CA-4D34-BAE8-8F83DC42758D.qcow2"
files = {}   # path -> bytes; extra entries in `extra`
extra = []


def pvs(hdd="omarchy.hdd", tools=""):
    return ("<ParallelsVirtualMachine><Identification><VmName>Omarchy</VmName></Identification><Settings><Tools>"
            "<SyncSshIds>0</SyncSshIds><SharedFolders><HostSharing><Enabled>1</Enabled><ShareAllMacDisks>0</ShareAllMacDisks>"
            "<ShareUserHomeDir>0</ShareUserHomeDir><SharedCloud>0</SharedCloud></HostSharing></SharedFolders>"
            "<SharedProfile><Enabled>0</Enabled></SharedProfile><SharedVolumes><Enabled>0</Enabled></SharedVolumes>%s"
            "</Tools></Settings><Hardware><CdRom><SystemName></SystemName></CdRom><Hdd><SystemName>%s</SystemName></Hdd>"
            "<Serial><SystemName>/dev/cu.debug-console</SystemName></Serial></Hardware></ParallelsVirtualMachine>" % (tools, hdd)).encode()


def desc(f=HDS, t="Plain"):
    return ("<Parallels_disk_image><StorageData><Storage><Image><Type>%s</Type><File>%s</File></Image></Storage>"
            "</StorageData></Parallels_disk_image>" % (t, f)).encode()


def qcow2(backing=0, incompat=0):
    h = b"QFI\xfb" + struct.pack(">IQI", 3, backing, 0) + struct.pack(">IQ", 16, 64 << 30)
    h += struct.pack(">IIQQIIQ", 0, 1, 0x30000, 0x10000, 1, 0, 0) + struct.pack(">QQQII", incompat, 0, 0, 4, 104)
    return h.ljust(4096, b"\0")


def vmdk(extent='RW 134217728 SPARSE "omarchy.vmdk"', more="", magic=b"KDMV"):
    h = magic + struct.pack("<IIQQQQ", 1, 3, 134217728, 128, 1, 20)
    d = ('# Disk DescriptorFile\nversion=1\nencoding="UTF-8"\nCID=8ca14383\nparentCID=ffffffff\ncreateType="monolithicSparse"\n'
         '%s\n%s# The Disk Data Base\n#DDB\n\nddb.uuid = "60 00 C2 96"\n' % (extent, more)).encode()
    return h.ljust(512, b"\0") + d.ljust(20 * 512, b"\0")


VMX = ['.encoding = "UTF-8"', 'displayName = "Omarchy"', 'nvme0.present = "TRUE"', 'nvme0:0.present = "TRUE"',
       'nvme0:0.fileName = "omarchy.vmdk"', 'sound.fileName = "-1"', 'nvram = "Omarchy.nvram"']

if route == "parallels":
    B = "Omarchy.pvm"
    files = {B + "/config.pvs": pvs(), B + "/NVRAM.dat": b"nvram", B + "/omarchy.hdd/DiskDescriptor.xml": desc(),
             B + "/omarchy.hdd/omarchy.hdd": b"", B + "/omarchy.hdd/" + HDS: b"\0" * 8192}
    v = variant
    if v == "hdd-path": files[B + "/config.pvs"] = pvs(hdd="/Users/someone/disk.hdd")
    if v == "hdd-dotdot": files[B + "/config.pvs"] = pvs(hdd="../../outside")
    if v == "share": files[B + "/config.pvs"] = pvs(tools="").replace(b"</HostSharing>", b"<SharedFolder><Name>x</Name><Path>Users</Path></SharedFolder></HostSharing>")
    if v == "share-path": files[B + "/config.pvs"] = pvs(tools="").replace(b"</HostSharing>", b"<SharedFolder><Name>x</Name><Path>/Users</Path></SharedFolder></HostSharing>")
    if v == "ssh-ids": files[B + "/config.pvs"] = pvs().replace(b"<SyncSshIds>0", b"<SyncSshIds>1")
    if v == "home": files[B + "/config.pvs"] = pvs().replace(b"<ShareUserHomeDir>0", b"<ShareUserHomeDir>1")
    if v == "profile": files[B + "/config.pvs"] = pvs().replace(b"<SharedProfile><Enabled>0", b"<SharedProfile><Enabled>1")
    if v == "serial-file": files[B + "/config.pvs"] = pvs().replace(b"/dev/cu.debug-console", b"/Users/someone/.zshrc")
    if v == "desc-dotdot": files[B + "/omarchy.hdd/DiskDescriptor.xml"] = desc(f="../../outside/secret")
    if v == "desc-other": files[B + "/omarchy.hdd/DiskDescriptor.xml"] = desc(f="omarchy.hdd.0.{11111111-6958-40ff-92a7-860e329aab41}.hds")
    if v == "desc-type": files[B + "/omarchy.hdd/DiskDescriptor.xml"] = desc(t="Compressed")
    if v == "no-desc": del files[B + "/omarchy.hdd/DiskDescriptor.xml"]
    if v == "no-config": del files[B + "/config.pvs"]
    if v == "extra": files[B + "/evil.sh"] = b"#!/bin/sh\n"
    if v == "nested": files[B + "/omarchy.hdd/sub/" + HDS] = b"x"
    if v == "beside": files["evil-beside"] = b"x"
    if v == "symlink": del files[B + "/config.pvs"]; extra.append(("sym", B + "/config.pvs", outside + "/secret"))
    if v == "symlink-dir": extra.append(("sym", B + "/omarchy.hdd", outside)); files = {k: x for k, x in files.items() if "/omarchy.hdd/" not in k}; files[B + "/omarchy.hdd/DiskDescriptor.xml"] = desc()
    if v == "hardlink": del files[B + "/NVRAM.dat"]; extra.append(("hard", B + "/NVRAM.dat", B + "/config.pvs"))
    if v == "hardlink-abs": del files[B + "/NVRAM.dat"]; extra.append(("hard", B + "/NVRAM.dat", outside + "/secret"))
    if v == "hardlink-dotdot": del files[B + "/NVRAM.dat"]; extra.append(("hard", B + "/NVRAM.dat", "../outside/secret"))
    if v == "dotdot": files[B + "/../../outside/evil"] = b"x"
    if v == "absolute": files[outside + "/evil-abs"] = b"x"
    if v == "fifo": extra.append(("fifo", B + "/NVRAM.dat", None)); del files[B + "/NVRAM.dat"]
elif route == "utm":
    B = "Omarchy.utm"
    cfg = {"Backend": "QEMU", "Information": {"Name": "Omarchy", "Icon": "omacvm.png", "IconCustom": True},
           "QEMU": {"AdditionalArguments": [], "UEFIBoot": True},
           "Drive": [{"ImageName": QC, "ImageType": "Disk", "Interface": "NVMe", "Identifier": QC[:-6]}],
           "Network": [{"Mode": "Shared", "PortForward": []}], "System": {"CPUCount": 8, "MemorySize": 12288},
           "Serial": [{"Mode": "Ptty", "Target": "Auto"}],
           "Sharing": {"DirectoryShareMode": "WebDAV"}}
    v = variant
    if v == "qemu-args": cfg["QEMU"]["AdditionalArguments"] = ["-drive", "file=secret"]
    if v == "image-dotdot": cfg["Drive"][0]["ImageName"] = "../../../outside/secret"
    if v == "image-missing": cfg["Drive"][0]["ImageName"] = "00000000-0000-0000-0000-000000000000.qcow2"
    if v == "abs-path": cfg["Information"]["Icon"] = "/Users/someone/.ssh/id_ed25519"
    if v == "bookmark": cfg["Sharing"]["SharedDirectories"] = [{"Bookmark": b"book\0mark"}]
    if v == "port-forward": cfg["Network"][0]["PortForward"] = [{"GuestPort": 22, "HostPort": 2222}]
    if v == "serial-tcp": cfg["Serial"] = [{"Mode": "TcpServer", "Target": "Auto", "TcpPort": 1234}]
    if v == "serial-monitor": cfg["Serial"] = [{"Mode": "Ptty", "Target": "Monitor"}]
    files = {B + "/config.plist": plistlib.dumps(cfg), B + "/Data/" + QC: qcow2(), B + "/Data/efi_vars.fd": b"efi",
             B + "/Data/omacvm.png": b"png"}
    if v == "backing": files[B + "/Data/" + QC] = qcow2(backing=104)
    if v == "data-file": files[B + "/Data/" + QC] = qcow2(incompat=0x4)
    if v == "not-qcow2": files[B + "/Data/" + QC] = b"\0" * 4096
    if v == "extra": files[B + "/Data/run.sh"] = b"x"
    if v == "symlink": del files[B + "/Data/" + QC]; extra.append(("sym", B + "/Data/" + QC, outside + "/secret"))
else:
    B = "Omarchy.vmwarevm"
    v = variant
    vmx = list(VMX)
    if v == "shared-folder": vmx += ['sharedFolder0.present = "TRUE"', 'sharedFolder0.hostPath = "Users"']
    if v == "serial-file": vmx += ['serial0.present = "TRUE"', 'serial0.fileName = "evil.log"']
    if v == "disk-path": vmx[4] = 'nvme0:0.fileName = "/Users/someone/disk.vmdk"'
    if v == "disk-other": vmx[4] = 'nvme0:0.fileName = "other.vmdk"'
    if v == "debug-stub": vmx += ['debugStub.listen.guest64 = "TRUE"']
    if v == "working-dir": vmx += ['workingDir = "."']
    if v == "escape-path": vmx += ['sched.swap.dir = "|2FUsers|2Fsomeone"']
    if v == "escape-disk": vmx[4] = 'nvme0:0.fileName = "|2E|2E|2Fother.vmdk"'
    if v == "vnc": vmx += ['RemoteDisplay.vnc.enabled = "TRUE"', 'RemoteDisplay.vnc.port = "5901"']
    if v == "usb-auto": vmx += ['usb.autoConnect.device0 = "0x05ac:0x8600"']
    files = {B + "/Omarchy.vmx": ("\n".join(vmx) + "\n").encode(), B + "/omarchy.vmdk": vmdk(), B + "/Omarchy.nvram": b"nv"}
    if v == "extent-other": files[B + "/omarchy.vmdk"] = vmdk(extent='RW 134217728 FLAT "/Users/someone/.zshrc" 0')
    if v == "extent-two": files[B + "/omarchy.vmdk"] = vmdk(extent='RW 1 SPARSE "omarchy.vmdk"\nRW 1 SPARSE "omarchy.vmdk"')
    if v == "parent": files[B + "/omarchy.vmdk"] = vmdk(more='parentFileNameHint="/Users/someone/base.vmdk"\n')
    if v == "parent-case": files[B + "/omarchy.vmdk"] = vmdk(more='parentfilenamehint="/Users/someone/base.vmdk"\n')
    if v == "type-case": files[B + "/omarchy.vmdk"] = vmdk(more='createtype="twoGbMaxExtentFlat"\n')
    if v == "extent-case": files[B + "/omarchy.vmdk"] = vmdk(extent='rw 134217728 flat "/Users/someone/.zshrc" 0')
    if v == "change-track": files[B + "/omarchy.vmdk"] = vmdk(more='changeTrackPath="omarchy-ctk.vmdk"\n')
    if v == "text-vmdk": files[B + "/omarchy.vmdk"] = vmdk(magic=b"# Di")
    if v == "no-vmx": del files[B + "/Omarchy.vmx"]
    if v == "extra": files[B + "/Omarchy.vmx.lck"] = b"x"

# The bundle itself a link to a VM already on the Mac, relative as from the
# work folder to the user's own VM (no user name needed).
if variant == "symlink-root":
    files = {}; extra = [("sym", B, "../victim/" + B)]

with tarfile.open(out, "w", format=tarfile.PAX_FORMAT) as t:
    dirs = sorted({p.rsplit("/", i)[0] for p in files if not p.startswith("/") and ".." not in p for i in (1, 2) if "/" in p})
    for d in dirs:
        if any(e[1] == d for e in extra):
            continue
        ti = tarfile.TarInfo(d); ti.type = tarfile.DIRTYPE; ti.mode = 0o755; t.addfile(ti)
    for kind, name, target in extra:
        ti = tarfile.TarInfo(name)
        if kind == "sym": ti.type = tarfile.SYMTYPE; ti.linkname = target
        elif kind == "hard": ti.type = tarfile.LNKTYPE; ti.linkname = target
        else: ti.type = tarfile.FIFOTYPE
        if kind == "hard" and target in files:
            ti2 = tarfile.TarInfo(target); ti2.size = len(files[target]); t.addfile(ti2, io.BytesIO(files.pop(target)))
        t.addfile(ti)
    for name, data in files.items():
        ti = tarfile.TarInfo(name); ti.size = len(data); ti.mode = 0o644; t.addfile(ti, io.BytesIO(data))
PY

# image ROUTE VARIANT [BUNDLE]: the fixture as an image in the source folder.
image() {
  local route=$1 base=omacvm-prebuilt-$VERSION-$1
  rm -rf "$OMACVM_PREBUILT_SOURCE" "$T/cache" "$T/work" "$T/outside"/evil*
  mkdir -p "$OMACVM_PREBUILT_SOURCE"
  python3 "$T/fixture.py" "$route" "$2" "$T/img.tar" "$T/outside" || { echo "FAIL fixture $route $2"; fail=1; return; }
  zstd -q -3 --long=27 -c "$T/img.tar" > "$OMACVM_PREBUILT_SOURCE/$base.tar.zst.part-aa"
  python3 "$R/src/prebuilt/manifest.py" write "$OMACVM_PREBUILT_SOURCE/$base.json" --route "$route" --omacvm "$VERSION" \
    --omarchy "4.0.3 (test)" --bundle "${3:-Omarchy$(case $route in (parallels) echo .pvm ;; (utm) echo .utm ;; (*) echo .vmwarevm ;; esac)}" \
    --unpacked 100 --disk-gb 64 --teams '["722686Y34B"]' "$OMACVM_PREBUILT_SOURCE/$base.tar.zst.part-aa" > /dev/null
  sign_doc "$OMACVM_PREBUILT_SOURCE/$base.json"
}

# try_install ROUTE: lookup, download, unpack and check, as vm.sh does: ok or refused.
try_install() {
  ( PREBUILT_CACHE=$T/cache
    prebuilt_lookup "$1" >/dev/null 2>&1 || { echo "no image"; exit 0; }
    prebuilt_download >/dev/null 2>&1
    prebuilt_unpack_bundle "$T/work" "$1" > "$T/why" 2>&1
    echo ok ) || { [[ -e $T/work ]] && echo "refused, work left" || echo refused; }
}

untouched() {   # the file outside, and nothing written next to it
  [[ $(cat "$T/outside/secret") == secret && $(stat -f %l "$T/outside/secret") == 1 && ! -e $T/outside/evil && ! -e $T/outside/evil-abs ]] &&
    echo yes || echo no
}

for route in parallels utm fusion; do
  image "$route" good
  r=$(try_install "$route")
  expect "$route: a good image" ok "$r"
  # It flaked on CI runners now and then (fusion): say why when it happens.
  [[ $r == ok ]] || sed "s/^/       /" "$T/why"
done
image parallels good
try_install parallels > /dev/null
expect "parallels: the bundle is all that comes out" "Omarchy.pvm" "$(ls "$T/work")"

while read -r route variant; do
  [[ -n $route ]] || continue
  image "$route" "$variant"
  expect "$route $variant: refused" refused "$(try_install "$route")"
  [[ -n ${VERBOSE:-} ]] && sed "s/^/       /" "$T/why"
  expect "$route $variant: nothing outside touched" yes "$(untouched)"
done <<'EOF'
parallels symlink
parallels symlink-dir
parallels hardlink
parallels hardlink-abs
parallels hardlink-dotdot
parallels dotdot
parallels fifo
parallels extra
parallels nested
parallels no-config
parallels no-desc
parallels hdd-path
parallels hdd-dotdot
parallels share
parallels share-path
parallels ssh-ids
parallels home
parallels profile
parallels serial-file
parallels desc-dotdot
parallels desc-other
parallels desc-type
utm qemu-args
utm image-dotdot
utm image-missing
utm abs-path
utm bookmark
utm port-forward
utm backing
utm data-file
utm not-qcow2
utm extra
utm symlink
utm serial-tcp
utm serial-monitor
fusion shared-folder
fusion serial-file
fusion disk-path
fusion disk-other
fusion debug-stub
fusion working-dir
fusion extent-other
fusion extent-two
fusion parent
fusion parent-case
fusion type-case
fusion extent-case
fusion change-track
fusion escape-path
fusion escape-disk
fusion vnc
fusion usb-auto
fusion text-vmdk
fusion no-vmx
fusion extra
EOF

# The bundle itself as a link to a good VM on the Mac: refused, that VM left as
# it was and nothing in the work folder.
tree_sum() { (cd "$T/victim" && ls -lRT . && find . -type f -exec shasum {} +) 2>&1 | shasum; }
for route in parallels utm fusion; do
  image "$route" good
  rm -rf "$T/victim"; mkdir -p "$T/victim"; tar -xf "$T/img.tar" -C "$T/victim"
  before=$(tree_sum)
  image "$route" symlink-root
  expect "$route symlink-root: refused" refused "$(try_install "$route")"
  [[ -n ${VERBOSE:-} ]] && sed "s/^/       /" "$T/why"
  expect "$route symlink-root: the VM it points at untouched" "$before" "$(tree_sum)"
  expect "$route symlink-root: no work folder left" no "$([[ -e $T/work || -L $T/work ]] && echo yes || echo no)"
done

# Entries next to the bundle or at an absolute path are not taken at all.
image parallels beside
expect "parallels: a file beside the bundle stays in the archive" "ok Omarchy.pvm" "$(try_install parallels) $(ls "$T/work")"
image parallels absolute
expect "parallels: an absolute path stays in the archive" ok "$(try_install parallels)"
expect "parallels: an absolute path: nothing outside touched" yes "$(untouched)"

# The bundle's name is pinned: another one in the manifest is not unpacked.
image parallels good Other.pvm
expect "parallels: another bundle name: refused" refused "$(try_install parallels)"
image utm good Omarchy.pvm
expect "utm: a Parallels bundle: refused" refused "$(try_install utm)"

# The reason is printable even when the file name in the archive is not.
python3 - "$T/fixture.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('if v == "extra": files[B + "/evil.sh"]', 'if v == "escape": files[B + "/\\x1b]52;c;aGk=\\x07x"] = b"x"\n    if v == "extra": files[B + "/evil.sh"]')
open(p, "w").write(s)
PY
image parallels escape
try_install parallels > /dev/null
expect "a strange file name: no escape sequence in the reason" no "$(LC_ALL=C grep -q $'\x1b]' "$T/why" && echo yes || echo no)"
expect "a strange file name: refused with a reason" yes "$(grep -q 'not used: unexpected' "$T/why" && echo yes || echo no)"

# Free space: an image bigger than the disk is refused before the download.
(
  PREBUILT_CACHE=$T/cache PB_SIZE=1000 PB_UNPACKED_KB=$(( 1 << 33 ))
  mkdir -p "$T/dest"
  msg=$(prebuilt_space_ok "$T/dest" 2>&1) && echo "FAIL free space: 8 TB fit" && exit 1
  [[ $msg == "not enough free space"* ]] || { echo "FAIL free space: '$msg'"; exit 1; }
  PB_UNPACKED_KB=100 prebuilt_space_ok "$T/dest" || { echo "FAIL free space: 100 KB did not fit"; exit 1; }
) && expect "free space is checked" ok ok || fail=1
# The message names the whole mount point, spaces and all.
(
  PREBUILT_CACHE=$T/cache PB_SIZE=1000 PB_UNPACKED_KB=1000000
  df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk9s1 2000000 1990000 10000 99%% /Volumes/My Disk\n'; }
  prebuilt_space_ok "$T/dest" 2>&1 || true
) | grep -q '^not enough free space on /Volumes/My Disk: ' && expect "free space: a mount point with spaces" ok ok || expect "free space: a mount point with spaces" ok no

# printable: colour codes out, other escape sequences and controls too.
got=$(printf '\033[1;32m==>\033[0m done\033]52;c;aGk=\007 x\r\033]0;title\007\n' | printable)
expect "printable" "==> done]52;c;aGk= x]0;title" "$got"
expect "printable: long lines cut at 240" 240 "$(head -c 400 /dev/zero | tr '\0' a | printable | tr -d '\n' | wc -c | tr -d ' ')"

# The exit cleanup: the seed and an unpacked image go, whatever happened.
(
  TYPE=parallels VM=x PB_SEED=$T/seed.iso PB_WORK=$T/work2
  touch "$PB_SEED"; mkdir -p "$PB_WORK/Omarchy.pvm"
  prebuilt_exit
  [[ ! -e $PB_SEED && ! -e $PB_WORK ]]
) && expect "prebuilt_exit removes the seed and the unpacked image" ok ok || { expect "prebuilt_exit" ok no; }

# Ctrl-C while the image unpacks: ui_spin runs it as a background job, which
# ignores Ctrl-C in a script. The exit cleanup must stop it before the work
# folder goes, or it writes the folder again. (A pipeline that keeps making
# folders and files, like zstd | tar; Ctrl-C = SIGINT to the process group.)
cat > "$T/ctrlc.sh" <<'EOF'
R=$1 PB_WORK=$2 FANCY=$3
source "$R/src/lib/ui.sh"; source "$R/src/prebuilt/lib.sh"; source "$R/src/prebuilt/vm.sh"
UI_FANCY=$FANCY TTY=/dev/null TYPE=fusion VM=x
trap 'prebuilt_exit' EXIT
writer() {
  while :; do echo x; sleep 0.05; done |
    while read -r _; do mkdir -p "$PB_WORK/Omarchy.vmwarevm"; : > "$PB_WORK/Omarchy.vmwarevm/f$RANDOM"; done
}
ui_spin "Unpacking and checking" writer
EOF
for fancy in 0 1; do
  got=$(python3 - "$T/ctrlc.sh" "$R" "$T/ctrlc-work" "$fancy" <<'PY2'
import os, shutil, signal, subprocess, sys, time
script, r, w, fancy = sys.argv[1:5]
p = subprocess.Popen(["/bin/bash", script, r, w, fancy], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(200):
    if os.path.isdir(w + "/Omarchy.vmwarevm"): break
    time.sleep(0.05)
os.killpg(p.pid, signal.SIGINT)
p.wait(timeout=30)
time.sleep(1)
left = os.path.exists(w)
alive = subprocess.run(["pgrep", "-g", str(p.pid)], capture_output=True, text=True).stdout.split()
try: os.killpg(p.pid, signal.SIGKILL)
except ProcessLookupError: pass
shutil.rmtree(w, ignore_errors=True)
print("rc %d, folder %s, %s" % (p.returncode, "left" if left else "gone", "still running" if alive else "stopped"))
PY2
)
  expect "Ctrl-C during the unpack (spinner $fancy): stopped, folder gone" "rc 130, folder gone, stopped" "$got"
done

# The first-boot wait: 255 (no SSH yet) asks again, 0 waits, 1 is done.
(
  n=0
  gssh() {
    [[ $2 == test* ]] || return 1   # systemctl is-failed: not failed
    n=$((n + 1)); case $n in 1) return 255 ;; 2) return 0 ;; *) return 1 ;; esac
  }
  sleep() { :; }
  prebuilt_firstboot_wait 10.0.0.1 && (( n == 3 ))
) && expect "first-boot wait: done after the marker goes" ok ok || expect "first-boot wait" ok no
(
  gssh() { [[ $2 == test* ]] && return 0; [[ $2 == systemctl* ]] && return 0; printf 'boom\033]52;c;aGk=\007\n'; }
  sleep() { :; }
  msg=$(prebuilt_firstboot_wait 10.0.0.1 2>&1) && exit 1
  [[ $msg == "the first boot failed: boom"* && $msg != *$'\033'* ]]
) && expect "first-boot wait: a failed first boot says so, printable" ok ok || expect "first-boot wait: failed" ok no

exit $fail
