#!/usr/bin/env python3
"""test-venus-image-limits.c, test-venus-robust.c, test-venus-commands.c and
test-venus-threads.c against the staged runtime's real Vulkan drivers (ADR 0065), and
test-venus-descriptor-walk.c on the CPU.

   run-venus-limits.py VIRGL_BUILD OUT_DIR RUNTIME_DIR -- LINK_ARGS...

Builds each test with vkr_image.c's own compile flags against the renderer's static
libraries (as run-regressions.py's run_test does), puts it in a lib/ folder laid out like
the runtime (its libvulkan.1.dylib and drivers beside it, share/vulkan/icd.d next to it),
so vkr loads the driver as in QEMU, and runs it once per driver: MoltenVK always,
KosmicKrisp too where the runtime has it and macOS is 26 or newer (a KosmicKrisp half
that falls back to MoltenVK fails the build); test-venus-commands also on MoltenVK with
MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1 (it encodes at vkEndCommandBuffer what it otherwise
encodes at the submit; nothing recorded is submitted). The cases whose harm shows only as
a write to freed or unowned heap memory (frees, submit counts, dedicated memory, pass
views, descriptor parts) run once more under libgmalloc (freed memory unmapped: such a
write ends the process). Then microseconds per vkCreateImage, per vkCreateBuffer and per
command. First, src/venus/vkr_proc_entries.h must be what
venus-missing-entries.py makes of the built tree (virgl-venus-missing-entries.patch), and
venus-command-ledger.tsv must give a verdict for every vkCmd* handler of the tree's
vkr_command_buffer.c (a new one needs a decision on its guest values)."""
import json
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import sys

build, output, runtime = (Path(v).resolve() for v in sys.argv[1:4])
link_args = sys.argv[4:]
if link_args[:1] == ["--"]:
    link_args = link_args[1:]

entries = json.loads((build / "compile_commands.json").read_text())
entry = next(item for item in entries if item["file"].endswith("/venus/vkr_image.c"))
command = entry.get("arguments") or shlex.split(entry["command"])
directory = Path(entry["directory"])
source = (directory / entry["file"]).resolve().parents[1]
flags, i = [], 1
while i < len(command):
    flag = command[i]
    if flag in ("-o", "-MF", "-MQ", "-MT"):
        i += 2
        continue
    if flag not in ("-c", "-MD", "-MMD") and not flag.endswith("/vkr_image.c"):
        flags.append(flag)
    i += 1

# the runtime's layout: lib/ (the test beside the loader and drivers), share/
lib = output / "venus-limits" / "lib"
lib.mkdir(parents=True, exist_ok=True)
for path in (runtime / "lib").glob("*.dylib"):
    link = lib / path.name
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(path)
share = output / "venus-limits" / "share"
if share.is_symlink() or share.exists():
    share.unlink()
share.symlink_to(runtime / "share")

# the stubs' list is the tables' list: made again from the tree, it must not differ
entries = source / "venus" / "vkr_proc_entries.h"
if entries.exists():
    made = subprocess.run([sys.executable, str(Path(__file__).with_name("venus-missing-entries.py")),
                           str(source / "venus")], capture_output=True, text=True)
    if made.returncode or made.stdout != entries.read_text():
        sys.exit("venus limits: FAIL: vkr_proc_entries.h is not what venus-missing-entries.py "
                 "makes of this tree " + made.stderr.strip())
    print("venus limits: vkr_proc_entries.h matches the tree's proc tables")
else:
    print("venus limits: no vkr_proc_entries.h (a tree without virgl-venus-missing-entries.patch)")

# every vkCmd* handler has a verdict on its guest values (virgl-venus-command-limits.patch)
ledger = Path(__file__).with_name("venus-command-ledger.tsv")
handlers = re.findall(r"^vkr_dispatch_(vkCmd[A-Za-z0-9]+)\(",
                      (source / "venus" / "vkr_command_buffer.c").read_text(), re.M)
rows = {line.split("\t")[0] for line in ledger.read_text().splitlines()[1:] if line.strip()}
missing, stale = sorted(set(handlers) - rows), sorted(rows - set(handlers))
if missing or stale:
    sys.exit(f"venus limits: FAIL: venus-command-ledger.tsv: no verdict for {missing}, rows "
             f"without a handler {stale}")
print(f"venus limits: venus-command-ledger.tsv has a verdict for each of the {len(handlers)} "
      "vkCmd* handlers")

tests = [("test-venus-image-limits", "vkCreateImage"), ("test-venus-robust", "vkCreateBuffer"),
         ("test-venus-commands", "vkCmd*"), ("test-venus-threads", None),
         ("test-venus-descriptor-walk", None)]
# test-venus-threads also goes through the public API (virglrenderer.c, built into the dylib only)
api_objects = [str(p) for p in sorted(build.glob("src/libvirglrenderer*.p/*.o"))]
for name, _ in tests:
    subprocess.run([command[0], *flags, "-I" + str(source), "-I" + str(source / "venus"),
                    str(Path(__file__).with_name(name + ".c")),
                    *(api_objects if name == "test-venus-threads" else []),
                    str(build / "src/libvirgl.a"), str(build / "src/gallium/libgallium.a"),
                    str(build / "src/mesa/libmesa.a"), *link_args, "-o", str(lib / name)],
                   cwd=directory, check=True)

# the descriptor walk on the CPU, at the seeds the lane ran (virgl-venus-descriptor-limits.patch)
for seed in (1, 2, 3, 77, 12345):
    walk = subprocess.run([str(lib / "test-venus-descriptor-walk"), str(seed)], capture_output=True, text=True)
    print(walk.stdout, end="")
    if walk.returncode:
        sys.exit(f"venus limits: FAIL: test-venus-descriptor-walk seed {seed}")
tests = [t for t in tests if t[0] != "test-venus-descriptor-walk"]

# under libgmalloc: the cases a heap write past or after an allocation shows in
gmalloc_cases = ("f-cmds-ok f-cmds-dup f-cmds-other-pool f-sets-ok f-sets-dup f-sets-other-pool "
                 "s-submit-ok s-submit-values-64 x-dedicated-bound-ok x-dedicated-unbound-ok "
                 "x-dedicated-buffer-unbound-ok x-dedicated-context-end-ok x-dedicated-other "
                 "x-dedicated-alias c-state-destroyed-view-begin c-state-destroyed-view-next "
                 "c-state-destroyed-view-end c-state-destroyed-view-imageless "
                 "c-state-destroyed-view-rendering c-state-destroyed-view-after-ok d-planes-ok "
                 "d-mutable-ok d-start-next-ok d-copy-start-next-ok")
gmalloc = Path("/usr/lib/libgmalloc.dylib")

icd = runtime / "share/vulkan/icd.d"
macos = int(platform.mac_ver()[0].split(".")[0] or 0)
drivers = [("moltenvk", "MoltenVK")]
if (icd / "kosmickrisp_mesa_icd.json").exists() and macos >= 26:
    drivers.insert(0, ("kosmickrisp", "KosmicKrisp"))
elif (icd / "kosmickrisp_mesa_icd.json").exists():
    print(f"venus limits: KosmicKrisp in the runtime, but macOS {macos} cannot run it: MoltenVK only")
else:
    print("venus limits: no KosmicKrisp in this runtime: MoltenVK only")

# vkr picks the driver; the loader and drivers come from beside the test, never from a
# library path. The pinned epoxy bottle names a placeholder path: it is found as a fallback
# in the -L folders, which never shadows the runtime's libraries.
env = {k: v for k, v in os.environ.items()
       if k not in ("VK_DRIVER_FILES", "VK_ICD_FILENAMES") and not k.startswith("DYLD_")}
env["DYLD_FALLBACK_LIBRARY_PATH"] = ":".join(a[2:] for a in link_args if a.startswith("-L"))
failed = []
for test, _ in tests:
    binary = lib / test
    variants = [(name, title, {}) for name, title in drivers]
    if test == "test-venus-commands":
        variants.append(("moltenvk", "MoltenVK", {"MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS": "1"}))
        if gmalloc.exists():
            variants += [(name, title, {"DYLD_INSERT_LIBRARIES": str(gmalloc),
                                        "VENUS_COMMANDS_CASES": gmalloc_cases}) for name, title in drivers]
    for name, title, extra in variants:
        variant_env = {**env, "OMACVM_VULKAN_DRIVER": name, **extra}
        label = title + (" (prefilled Metal command buffers)" if "MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS" in extra
                         else " (libgmalloc)" if extra else "")
        run = subprocess.run([str(binary)], env=variant_env, capture_output=True, text=True)
        print(run.stdout, end="")
        summary = run.stdout.strip().splitlines()[-1] if run.stdout.strip() else ""
        if run.returncode or not summary.startswith("all ok") or not summary.endswith(" on " + title):
            failed.append(f"{test} on {label} ({summary or 'no output'})")
            continue
        if test == "test-venus-threads" or "DYLD_INSERT_LIBRARIES" in extra:
            continue
        timing = subprocess.run([str(binary), "--time", "10000"], env=variant_env,
                                capture_output=True, text=True)
        lines = [line for line in timing.stdout.splitlines() if line.startswith("timing:")]
        for line in lines:
            print(f"{label} {line}")

if failed:
    sys.exit("venus limits: FAIL: " + ", ".join(failed))
print("venus limits: every case as expected in " + " and ".join(t for t, _ in tests) + " on " +
      " and ".join(t for _, t in drivers))
