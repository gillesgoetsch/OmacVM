#!/usr/bin/env python3
"""test-venus-image-limits.c against the staged runtime's real Vulkan drivers (ADR 0065).

   run-venus-limits.py VIRGL_BUILD OUT_DIR RUNTIME_DIR -- LINK_ARGS...

Builds the test with vkr_image.c's own compile flags against the renderer's static
libraries (as run-regressions.py's run_test does), puts it in a lib/ folder laid out like
the runtime (its libvulkan.1.dylib and drivers beside it, share/vulkan/icd.d next to it),
so vkr loads the driver as in QEMU, and runs it once per driver: MoltenVK always,
KosmicKrisp too where the runtime has it and macOS is 26 or newer (a KosmicKrisp half
that falls back to MoltenVK fails the build). Then microseconds per vkCreateImage."""
import json
import os
from pathlib import Path
import platform
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

binary = lib / "test-venus-image-limits"
subprocess.run([command[0], *flags, "-I" + str(source), "-I" + str(source / "venus"),
                str(Path(__file__).with_name("test-venus-image-limits.c")),
                str(build / "src/libvirgl.a"), str(build / "src/gallium/libgallium.a"),
                str(build / "src/mesa/libmesa.a"), *link_args, "-o", str(binary)],
               cwd=directory, check=True)

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
for name, title in drivers:
    run = subprocess.run([str(binary)], env={**env, "OMACVM_VULKAN_DRIVER": name},
                         capture_output=True, text=True)
    print(run.stdout, end="")
    summary = run.stdout.strip().splitlines()[-1] if run.stdout.strip() else ""
    if run.returncode or not summary.startswith("all ok") or not summary.endswith(" on " + title):
        failed.append(f"{title} ({summary or 'no output'})")
        continue
    timing = subprocess.run([str(binary), "--time", "10000"],
                            env={**env, "OMACVM_VULKAN_DRIVER": name}, capture_output=True, text=True)
    lines = [line for line in timing.stdout.splitlines() if line.startswith("timing:")]
    print(f"{title} {lines[-1] if lines else 'timing: did not run'}")

if failed:
    sys.exit("venus limits: FAIL on " + ", ".join(failed))
print("venus limits: every case as expected on " + " and ".join(t for _, t in drivers))
