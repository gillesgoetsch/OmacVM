#!/usr/bin/env python3
"""Hyprland's shaders with OmacVM's cm_helpers.glsl compile as with its own.

    hypr-capture-shaders.py GLSL_DIR OURS [JOBS]

GLSL_DIR: Hyprland's src/render/shaders/glsl of the release OURS is made for;
the release's src/render/ShaderLoader.cpp (two folders up) says which defines a
variant gets, in its order (getDefines), and whether the transfer functions
are compiled in (SOURCE_TF/TARGET_TF, from 0.57.0 on). Every fragment shader
that includes cm_helpers.glsl is built as Hyprland's ShaderLoader builds a
variant (defines.h replaced by the feature set's defines, includes from the
same folder) for every mix of the colour features (CM, TONEMAP, ALT_TONEMAP,
SDR_MOD, MIRROR, ICC) on two sets of the others, at sRGB to sRGB, and the
variants a capture uses also at other transfer function pairs (PQ, HLG,
ext-linear, gamma 2.2), as GLSL ES 3.00 (how Hyprland builds them) and 3.20,
once with Hyprland's cm_helpers.glsl and once with OURS, and compiled with
glslangValidator. Fails when a variant compiles with Hyprland's file and not
with ours, or one a capture uses does not compile at all. glslang is not the
VM's compiler (Mesa's, through virgl); the VM run covers that.
USE_BLUR stays out of the two sets: v0.57.0's surface.frag declares `float t`
twice with USE_MIRROR, USE_BLUR and USE_BLUR_PROPORTIONAL on ("'t' :
redefinition", with Hyprland's file as with ours; an upstream bug, not
reached with OmacVM's settings).
"""
import concurrent.futures
import itertools
import os
import re
import shutil
import subprocess
import sys
import tempfile

COLOUR = ["USE_CM", "USE_TONEMAP", "USE_ALT_TONEMAP", "USE_SDR_MOD", "USE_MIRROR", "USE_ICC"]
BASES = {"plain": set(), "window": {"USE_RGBA", "USE_DISCARD", "USE_TINT", "USE_ROUNDING"}}
VERSIONS = ["300 es", "320 es"]
# what a window's capture copy and a window share use
NEEDED = [{"USE_CM", "USE_MIRROR"}, {"USE_CM", "USE_TONEMAP"}, {"USE_CM", "USE_TONEMAP", "USE_MIRROR"},
          {"USE_CM", "USE_TONEMAP", "USE_ALT_TONEMAP", "USE_MIRROR"}, {"USE_CM", "USE_SDR_MOD", "USE_MIRROR"},
          {"USE_CM", "USE_TONEMAP", "USE_SDR_MOD", "USE_MIRROR"}]
# transfer functions (CM.glsl's numbers): every variant at sRGB -> sRGB, the capture variants also an HDR source
# into the SDR copy or onto an HDR output, and the linear and gamma 2.2 ones
SRGB = (9, 9)
TF_PAIRS = [(11, 9), (13, 9), (11, 11), (9, 11), (5, 9), (9, 5), (2, 9)]


def loader_defines(glsl):
    """The release's getDefines: the feature names in order, and whether SOURCE_TF/TARGET_TF are defined."""
    with open(os.path.join(glsl, "..", "..", "ShaderLoader.cpp"), encoding="utf-8") as f:
        src = f.read()
    body = src[src.index("::getDefines("):]
    body = body[:body.index("\n}\n")]
    names = re.findall(r'\{"(USE_[A-Z0-9_]+)",\s*SH_FEAT_[A-Z0-9_]+\}', body)
    if not names:
        raise ValueError("no defines in its getDefines")
    return names, "SOURCE_TF" in body


def includes(folder, name, seen):
    with open(os.path.join(folder, name), encoding="utf-8") as f:
        for m in re.finditer(r'^\s*#include\s+"([^"]+)"', f.read(), re.M):
            if m.group(1) not in seen:
                seen.add(m.group(1))
                includes(folder, m.group(1), seen)
    return seen


def build(job):
    work, files, frag, version, feats, tf, features, with_tf = job
    d = tempfile.mkdtemp(dir=work)
    for name, path in files.items():
        if name not in (frag, "defines.h"):
            os.symlink(path, os.path.join(d, name))
    with open(os.path.join(d, "defines.h"), "w", encoding="utf-8") as f:
        f.write("".join(f"#define {n} {1 if n in feats else 0}\n" for n in features))
        if with_tf:
            f.write(f"#define SOURCE_TF {tf[0]}\n#define TARGET_TF {tf[1]}\n")
    with open(files[frag], encoding="utf-8") as f:
        src = f.read()
    with open(os.path.join(d, frag), "w", encoding="utf-8") as f:
        f.write(re.sub(r"^#version 300 es", "#version " + version, src, count=1))
    # As Hyprland: glslang's preprocessor with the includes (looked up from the
    # working folder), "#line" lines dropped, then the GL driver compiles that.
    pre = subprocess.run(["glslangValidator", "-E", "-S", "frag", frag], cwd=d,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if pre.returncode != 0 or "main" not in pre.stdout:
        shutil.rmtree(d, ignore_errors=True)
        return False, pre.stdout
    with open(os.path.join(d, "pre.frag"), "w", encoding="utf-8") as f:
        f.write("".join(l for l in pre.stdout.splitlines(True) if not l.startswith("#line ")))
    r = subprocess.run(["glslangValidator", "-S", "frag", "pre.frag"], cwd=d,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    shutil.rmtree(d, ignore_errors=True)
    return r.returncode == 0, r.stdout


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    glsl, ours = argv[1], argv[2]
    jobs = int(argv[3]) if len(argv) > 3 else os.cpu_count() or 2
    if not shutil.which("glslangValidator"):
        print("FAIL glslangValidator not found (glslang-tools)")
        return 1
    try:
        features, with_tf = loader_defines(glsl)
    except (OSError, ValueError) as e:
        print(f"FAIL cannot read the release's ShaderLoader.cpp: {e}")
        return 1
    names = sorted(n for n in os.listdir(glsl) if n.endswith((".frag", ".glsl", ".h")))
    frags = [n for n in names if n.endswith(".frag") and "cm_helpers.glsl" in includes(glsl, n, set())]
    sets = {"Hyprland's": {n: os.path.join(glsl, n) for n in names},
            "OmacVM's": {n: os.path.join(glsl, n) for n in names}}
    sets["OmacVM's"]["cm_helpers.glsl"] = os.path.abspath(ours)
    variants = []
    for frag, version, base in itertools.product(frags, VERSIONS, BASES):
        for bits in itertools.product([0, 1], repeat=len(COLOUR)):
            variants.append((frag, version, base, frozenset(BASES[base] | {c for c, b in zip(COLOUR, bits) if b}), SRGB))
    if with_tf:
        for version, n, tf in itertools.product(VERSIONS, NEEDED, TF_PAIRS):
            variants.append(("surface.frag", version, "window", frozenset(BASES["window"] | n), tf))
    print(f"     {len(frags)} fragment shaders with cm_helpers.glsl ({', '.join(frags)}), {len(variants)} variants "
          f"each way ({len(features)} defines{', transfer functions compiled in' if with_tf else ''})")
    fail = 0
    with tempfile.TemporaryDirectory() as work, concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        results = {}
        for label, files in sets.items():
            res = pool.map(build, [(work, files, f, v, feats, tf, features, with_tf) for f, v, _, feats, tf in variants])
            results[label] = dict(zip(variants, res))
    theirs, mine = results["Hyprland's"], results["OmacVM's"]
    worse = [v for v in variants if theirs[v][0] and not mine[v][0]]
    better = [v for v in variants if mine[v][0] and not theirs[v][0]]
    ok_theirs = sum(1 for v in variants if theirs[v][0])
    print(f"     compiled: {ok_theirs} with Hyprland's file, {sum(1 for v in variants if mine[v][0])} with OmacVM's")
    for v in worse[:5]:
        print(f"FAIL {v[0]} {v[1]} {v[2]} {sorted(v[3])} tf {v[4]} compiles with Hyprland's file, not with OmacVM's:")
        print("\n".join(mine[v][1].splitlines()[:6]))
        fail = 1
    if worse:
        print(f"FAIL {len(worse)} variants in all")
    else:
        print("ok   every variant that compiles with Hyprland's cm_helpers.glsl compiles with OmacVM's")
    if better:
        print(f"FAIL {len(better)} variants compile only with OmacVM's file (another file than Hyprland's?)")
        fail = 1
    needed = [frozenset(n) for n in NEEDED]
    missing = [(v[0], v[1], sorted(v[3]), v[4]) for v in variants
               if v[0] == "surface.frag" and v[2] == "window" and v[3] - BASES["window"] in needed and not mine[v][0]]
    if missing:
        for m in missing:
            print(f"FAIL a variant captures use does not compile: {m}")
        fail = 1
    else:
        print("ok   the variants a window's capture copy and a window share use compile")
    if ok_theirs < len(variants) // 2:
        print(f"FAIL only {ok_theirs} of {len(variants)} variants compile with Hyprland's own file (a broken run?)")
        fail = 1
    return fail


if __name__ == "__main__":
    sys.exit(main(sys.argv))
