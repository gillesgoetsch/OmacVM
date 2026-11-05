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
write ends the process), and so do test-venus-image-limits' plane binds (DISJOINT planes
and one-plane DISJOINT|ALIAS images on them, dEQP's ycbcr.plane_view.memory_alias, #624).
Then microseconds per vkCreateImage, per vkCreateBuffer and per command. First,
src/venus/vkr_proc_entries.h must be what venus-missing-entries.py makes of the built tree
(virgl-venus-missing-entries.patch), and venus-command-ledger.tsv must give a verdict for
every vkCmd* handler of the tree's vkr_command_buffer.c (a new one needs a decision on its
guest values)."""
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

# under libgmalloc: the cases a heap write past or after an allocation shows in
gmalloc_cases = ("f-cmds-ok f-cmds-dup f-cmds-other-pool f-sets-ok f-sets-dup f-sets-other-pool "
                 "s-submit-ok s-submit-values-64 s-submit-chain-twice x-dedicated-chain-twice "
                 "x-dedicated-chain-null x-dedicated-bound-ok x-dedicated-unbound-ok "
                 "x-dedicated-buffer-unbound-ok x-dedicated-context-end-ok x-dedicated-other "
                 "x-dedicated-alias c-state-destroyed-view-begin c-state-destroyed-view-next "
                 # a swapchain's memory freed before the image bound to it
                 # (virgl-venus-alias-memory.patch)
                 "x-dedicated-alias-b-first-ok x-dedicated-alias-free-a-b x-dedicated-alias-context-end "
                 "x-dedicated-alias-held x-dedicated-alias-own-dedicated x-dedicated-alias-bind2 "
                 "x-dedicated-alias-twice x-dedicated-alias-bind2-twice "
                 "c-state-destroyed-view-end c-state-destroyed-view-imageless "
                 "c-state-destroyed-view-rendering c-state-destroyed-view-after-ok d-planes-ok "
                 "d-mutable-ok d-start-next-ok d-copy-start-next-ok "
                 # views destroyed and secondaries freed under a command buffer, two threads
                 # on one context (virgl-venus-command-holds.patch,
                 # virgl-venus-secondary-holds.patch, virgl-venus-ring-lock.patch)
                 "c-state-destroyed-view-held-rendering-barrier c-state-destroyed-view-held-pass-barrier "
                 "c-state-destroyed-view-held-submit c-state-destroyed-view-held-reset-ok "
                 "c-state-destroyed-view-held-begin-ok c-state-destroyed-view-held-free-ok "
                 "c-state-destroyed-view-held-image-memory-ok c-state-destroyed-view-held-teardown-ok "
                 "c-state-destroyed-view-held-control-ok c-state-secondary-held-free-submit "
                 "c-state-secondary-held-pool-submit c-state-secondary-held-reset-ok "
                 "c-state-secondary-held-free-primary-ok c-state-secondary-held-same-pool-ok "
                 "c-state-secondary-held-teardown-ok c-state-secondary-held-control-ok "
                 # secondaries recorded again, what is submitted (virgl-venus-submit-state.patch)
                 "c-state-secondary-held-resubmit-ok c-state-secondary-held-rerecord-ok "
                 "c-state-secondary-held-rerecord-submit c-state-secondary-held-reset-submit "
                 "c-state-secondary-held-pool-reset-submit c-state-secondary-held-free-pool-reset-submit "
                 "c-state-secondary-held-rerecord-end s-submit-secondary s-submit-recording s-submit-initial "
                 "h-release-secondary-ok "
                 # a driver end that failed, ended from the guest's call (the same patch)
                 "c-state-end-failed-submit-ok c-state-end-failed-resubmit-ok c-state-end-failed-secondary-ok "
                 "c-state-end-failed-reset-submit c-state-end-failed-rebegin-submit c-state-end-hook-submit "
                 "c-state-end-hook-secondary c-state-end-hook-reset-ok "
                 "t-pipeline-destroy-layout t-pipeline-destroy-module "
                 "t-cache-data-destroy t-same-id t-command-free-buffer t-same-command-buffer "
                 "t-export-free-memory t-wait-ring-nested-ok t-teardown-paused-ok "
                 # a structure type twice in a chain (virgl-venus-chain-repeats.patch)
                 "r-repeat-multiview-short r-repeat-attachment-begin r-repeat-begin-two-types-ok "
                 # a view without a driver view, blend states the drivers read past
                 # (virgl-venus-ignored-values.patch)
                 "d-texel-empty-nd d-texel-empty-teardown p-gfx-vstride-dynamic p-gfx-blend-null-dyn "
                 "p-gfx-blend-more-dyn "
                 # draws with a set or index buffer never bound, the NULL index buffer vkr
                 # binds (virgl-venus-unset-state.patch)
                 "u-set-unset u-set-second-unset u-set-unset-dispatch u-set-second-unset-dispatch "
                 "u-set-secondary u-ib-unset u-ib-null-m6-ok u-ib-unset-m6-ok u-ib-unset-m6-indirect-ok "
                 "u-set-interface-only-ok u-set-execute-kept "
                 # recording charges moved to a pool, a teardown with zombies, secondaries
                 # (virgl-venus-host-memory.patch, virgl-venus-encoder-cap.patch)
                 "h-rec-spare-ok h-release-end h-pass-secondary-ok")
# test-venus-image-limits under libgmalloc: plane binds, where a driver reads a plane's memory
# slot by the guest's plane aspect
image_gmalloc_cases = ("bind-plane-info bind-disjoint-no-plane bind-disjoint-planes-ok "
                       "bind-alias-plane0-ok bind-alias-plane1-ok bind-alias-no-plane bind-alias-v1 "
                       "bind-alias-plane1-aspect repeat-bind-plane repeat-reqs-plane")
gmalloc_runs = {"test-venus-commands": ("VENUS_COMMANDS_CASES", gmalloc_cases),
                "test-venus-image-limits": ("VENUS_IMAGE_CASES", image_gmalloc_cases)}
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

# the descriptor walk on the CPU, at the seeds the lane ran (virgl-venus-descriptor-limits.patch);
# it links the renderer's libraries too, so it needs the same library path
for seed in (1, 2, 3, 77, 12345):
    walk = subprocess.run([str(lib / "test-venus-descriptor-walk"), str(seed)], env=env, capture_output=True,
                          text=True)
    print(walk.stdout, end="")
    if walk.returncode:
        print(walk.stderr[-2000:], end="")
        sys.exit(f"venus limits: FAIL: test-venus-descriptor-walk seed {seed} (exit {walk.returncode})")
tests = [t for t in tests if t[0] != "test-venus-descriptor-walk"]

failed = []
for test, _ in tests:
    binary = lib / test
    variants = [(name, title, {}) for name, title in drivers]
    if test == "test-venus-commands":
        variants.append(("moltenvk", "MoltenVK", {"MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS": "1"}))
    if test in gmalloc_runs and gmalloc.exists():
        variable, cases = gmalloc_runs[test]
        variants += [(name, title, {"DYLD_INSERT_LIBRARIES": str(gmalloc), variable: cases})
                     for name, title in drivers]
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
        if test == "test-venus-commands":
            # through a real ring and the context's stream (virgl-venus-ring-lock.patch)
            ring_timing = subprocess.run([str(binary), "--ring-time", "10000"], env=variant_env,
                                         capture_output=True, text=True)
            lines += [line for line in ring_timing.stdout.splitlines() if line.startswith("ring-time:")]
        for line in lines:
            print(f"{label} {line}")

if failed:
    sys.exit("venus limits: FAIL: " + ", ".join(failed))
print("venus limits: every case as expected in " + " and ".join(t for t, _ in tests) + " on " +
      " and ".join(t for _, t in drivers))
