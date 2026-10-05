#!/usr/bin/env python3
"""Edit a Parallels VM's config.pvs while the VM is stopped.

Works on Parallels Desktop Standard: only `prlctl list/register` are needed
elsewhere, everything else is this file. Usage:

  pvs.py CONFIG omacvm --cpus N --memsize MB [--description TEXT]
      the OmacVM settings: CPUs/RAM fixed, 3D + VSync, Retina (HiDPI in
      the guest, native resolution in full screen), all displays in full
      screen, smooth scrolling, no Mac volumes or iCloud in the guest
  pvs.py CONFIG resources --cpus N --memsize MB   only CPUs and memory (fixed)
  pvs.py CONFIG add-nvme NAME SIZE_MB     add an existing .hdd bundle (in the .pvm) as NVMe disk
  pvs.py CONFIG boot-from INDEX           boot from that disk only
  pvs.py CONFIG remove-hdd INDEX          detach a disk (its files stay)
  pvs.py CONFIG add-share NAME PATH ro|rw add a shared folder (seen as /mnt/psf/NAME)
  pvs.py CONFIG displays                  full screen on every Mac display (Parallels'
                                          own full screen, not macOS's)
  pvs.py CONFIG get PATH                  print one value, e.g. Hardware/Memory/RAM
"""
import re
import sys
import uuid
import xml.etree.ElementTree as ET


def load(path):
    return ET.parse(path)


def save(tree, path):
    ET.indent(tree, space="   ")
    tree.write(path, encoding="UTF-8", xml_declaration=True)


def node(root, path):
    e = root.find(path)
    if e is None:
        sys.exit(f"pvs.py: {path} not found in config.pvs")
    return e


def setv(root, path, value):
    node(root, path).text = str(value)


def bump_dyn_list(parent, tag, next_id):
    """Parallels keeps 'Tag N' counters (next free id) in the parent's dyn_lists."""
    dl = parent.get("dyn_lists", "")
    parts = dl.split()
    pairs = dict(zip(parts[::2], parts[1::2]))
    if int(pairs.get(tag, 0)) < next_id:
        pairs[tag] = str(next_id)
    parent.set("dyn_lists", " ".join(f"{k} {v}" for k, v in pairs.items()))


def child(parent, tag, text):
    e = ET.SubElement(parent, tag)
    e.text = str(text)
    return e


def resources(root, cpus, memsize):
    for path, value in {
        "Hardware/Cpu/Number": cpus, "Hardware/Cpu/AutoCountEnabled": 0,
        "Hardware/Memory/RAM": memsize, "Hardware/Memory/RamAutoSizeEnabled": 0,
    }.items():
        setv(root, path, value)


def omacvm(root, cpus, memsize, description):
    resources(root, cpus, memsize)
    s = {
        "Hardware/Video/Enable3DAcceleration": 1, "Hardware/Video/EnableVSync": 1,
        "Hardware/Video/VideoMemorySize": 0,
        "Hardware/Video/EnableHiResDrawing": 1, "Hardware/Video/UseHiResInGuest": 1,
        "Settings/Runtime/HostRetinaEnabled": 1, "Settings/Runtime/OsResolutionInFullScreen": 1,
        "Settings/Tools/SmoothScrolling/Enabled": 1,
        "Settings/Tools/SharedFolders/HostSharing/Enabled": 1,
        "Settings/Tools/SharedFolders/HostSharing/SharedCloud": 0,
        "Settings/Tools/SharedVolumes/Enabled": 0,
        "Settings/Tools/SharedProfile/Enabled": 0,
    }
    for path, value in s.items():
        setv(root, path, value)
    displays(root)
    if description is not None:
        setv(root, "Settings/General/VmDescription", description)


DISPLAYS = {
    "Settings/Runtime/FullScreen/UseAllDisplays": 1,
    "Settings/Runtime/FullScreen/UseNativeFullScreen": 0,
    "Settings/Runtime/FullScreen/OptimiseForGames": 1,
}


def displays(root):
    """True if something changed."""
    changed = False
    for path, value in DISPLAYS.items():
        if node(root, path).text != str(value):
            setv(root, path, value)
            changed = True
    return changed


def hdds(root):
    return node(root, "Hardware").findall("Hdd")


def add_nvme(root, name, size_mb):
    hw = node(root, "Hardware")
    existing = hdds(root)
    idx = max((int(h.findtext("Index")) for h in existing), default=-1) + 1
    hid = max((int(h.get("id")) for h in existing), default=-1) + 1
    h = ET.Element("Hdd", {"dyn_lists": "Partition 0", "id": str(hid)})
    for tag, val in [("Uuid", "{%s}" % uuid.uuid4()), ("Index", idx), ("Enabled", 1), ("Connected", 1),
                     ("EmulatedType", 1), ("SystemName", name), ("UserFriendlyName", name), ("Remote", 0),
                     ("InterfaceType", 3), ("StackIndex", 0), ("DiskType", 1), ("Size", size_mb),
                     ("SizeOnDisk", 0), ("Passthrough", 0), ("SubType", 0), ("Splitted", 0),
                     ("DiskVersion", 2), ("CompatLevel", "level2"), ("DeviceDescription", ""),
                     ("AutoCompressEnabled", 1), ("OnlineCompactMode", 1)]:
        child(h, tag, val)
    # keep devices grouped: insert after the last Hdd (or before Serial)
    kids = list(hw)
    pos = max((kids.index(x) for x in existing), default=None)
    if pos is None:
        pos = next((i for i, k in enumerate(kids) if k.tag in ("Serial", "NetworkAdapter")), len(kids)) - 1
    hw.insert(pos + 1, h)
    bump_dyn_list(hw, "Hdd", hid + 1)
    print(idx)


def boot_from(root, index):
    bo = node(root, "Settings/Startup/BootingOrder")
    found = False
    for d in bo.findall("BootDevice"):
        is_it = d.findtext("Type") == "6" and d.findtext("Index") == str(index)
        found |= is_it
        d.find("InUse").text = "1" if is_it else "0"
        d.find("BootingNumber").text = "0" if is_it else str(int(d.findtext("BootingNumber")) + 1)
    if not found:
        bid = max((int(d.get("id")) for d in bo.findall("BootDevice")), default=-1) + 1
        d = ET.Element("BootDevice", {"dyn_lists": "", "id": str(bid)})
        for tag, val in [("Index", index), ("Type", 6), ("BootingNumber", 0), ("InUse", 1)]:
            child(d, tag, val)
        bo.insert(0, d)
        bump_dyn_list(bo, "BootDevice", bid + 1)


def remove_hdd(root, index):
    hw = node(root, "Hardware")
    for h in hdds(root):
        if h.findtext("Index") == str(index):
            hw.remove(h)
    bo = node(root, "Settings/Startup/BootingOrder")
    for d in bo.findall("BootDevice"):
        if d.findtext("Type") == "6" and d.findtext("Index") == str(index):
            bo.remove(d)


def add_share(root, name, path, mode):
    hs = node(root, "Settings/Tools/SharedFolders/HostSharing")
    for f in hs.findall("SharedFolder"):
        if f.findtext("Name") == name:
            hs.remove(f)
    folders = hs.findall("SharedFolder")
    fid = max((int(f.get("id")) for f in folders), default=-1) + 1
    f = ET.Element("SharedFolder", {"dyn_lists": "", "id": str(fid)})
    for tag, val in [("Name", name), ("Path", path), ("FolderDescription", ""),
                     ("ReadOnly", 1 if mode == "ro" else 0), ("Enabled", 1), ("SuidEnabled", 0)]:
        child(f, tag, val)
    kids = list(hs)
    pos = max((kids.index(x) for x in folders), default=None)
    if pos is None:
        pos = next((i for i, k in enumerate(kids) if k.tag == "SharedCloud"), len(kids)) - 1
    hs.insert(pos + 1, f)
    bump_dyn_list(hs, "SharedFolder", fid + 1)
    setv(root, "Settings/Tools/SharedFolders/HostSharing/Enabled", 1)


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    path, cmd, args = argv[1], argv[2], argv[3:]
    tree = load(path)
    root = tree.getroot()
    if cmd == "get":
        print(node(root, args[0]).text or "")
        return
    if cmd == "omacvm":
        opts = dict(zip(args[::2], args[1::2]))
        omacvm(root, int(opts["--cpus"]), int(opts["--memsize"]), opts.get("--description"))
    elif cmd == "resources":
        opts = dict(zip(args[::2], args[1::2]))
        resources(root, int(opts["--cpus"]), int(opts["--memsize"]))
    elif cmd == "displays":
        if not displays(root):
            return
    elif cmd == "add-nvme":
        add_nvme(root, args[0], int(args[1]))
    elif cmd == "boot-from":
        boot_from(root, int(args[0]))
    elif cmd == "remove-hdd":
        remove_hdd(root, int(args[0]))
    elif cmd == "add-share":
        if args[2] not in ("ro", "rw"):
            sys.exit("pvs.py: mode must be ro or rw")
        add_share(root, args[0], args[1], args[2])
    else:
        sys.exit(__doc__)
    save(tree, path)


if __name__ == "__main__":
    main(sys.argv)
