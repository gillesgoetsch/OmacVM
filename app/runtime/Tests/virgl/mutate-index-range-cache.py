#!/usr/bin/env python3
"""Mutation check for the index range cache (manual, not part of the runtime build).

Takes out one generation bump, never-cache flag, error check or key comparison at a time
(in a copy of vrend_renderer.c next to the original) and runs test-index-range-cache
against it: every mutant must fail (a FAIL line, or gl-oracle aborting a draw outside a
buffer). A mutant that passes means the test does not cover that line.
Same arguments as run-regressions.py:
  mutate-index-range-cache.py <virgl build dir> <output dir> -- <link args>
"""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

# (what, regular expression of the code taken out; it must match exactly once)
MUTANTS = [
    ("transfer write bump",
     r"\n   vrend_resource_contents_changed\(res\);\n(?=   if \(\(is_only_bit)"),
    ("buffer copy bump", r"\n   vrend_resource_contents_changed\(dst_res\);\n(?=   glBindBuffer\(GL_COPY_READ)"),
    ("stream output flag",
     r"\n   vrend_resource_no_index_range_cache\(res\);(?=\n   pipe_reference_init\(&target)"),
    ("storage buffer flag",
     r"\n      vrend_resource_no_index_range_cache\(res\);(?=\n      vrend_resource_reference\(&ssbo)"),
    ("image flag",
     r"\n      vrend_resource_no_index_range_cache\(res\);(?=\n      vrend_resource_reference\(&iview)"),
    ("atomic counter flag",
     r"\n      vrend_resource_no_index_range_cache\(res\);(?=\n      vrend_resource_reference\(&abo)"),
    ("query result flag",
     r"\n  vrend_resource_no_index_range_cache\(res\);(?=\n\n  GLenum qtype)"),
    ("error check after the read", r" \|\|\n       !vrend_draw_state_ok\(ctx\)(?=\) \{)"),
    ("never-cache flag test", r" !ib->index_range_never &&"),
    ("storage test", r"\n          \(ib->storage_bits & ~VREND_STORAGE_GUEST_MEMORY\) == VREND_STORAGE_GL_BUFFER &&"),
    ("key: offset", r" && e->offset == offset"),
    ("key: count", r" && e->count == count"),
    ("key: index size", r"\n          e->index_size == index_size && "),
    ("key: restart", r" && e->restart == restart"),
    ("key: restart index", r" &&\n          e->restart_index == restart_index(?=\) \{)"),
    ("generation", r"e->gen == gen && "),
]


def main():
    build, output = (Path(v).resolve() for v in sys.argv[1:3])
    link_args = sys.argv[3:]
    if link_args[:1] == ["--"]:
        link_args = link_args[1:]
    output.mkdir(parents=True, exist_ok=True)
    entries = json.loads((build / "compile_commands.json").read_text())
    entry = next(e for e in entries if e["file"].endswith("/vrend_renderer.c"))
    command = entry.get("arguments") or shlex.split(entry["command"])
    directory = Path(entry["directory"])
    original = (directory / entry["file"]).resolve()
    source = original.parents[1]
    flags, i = [], 1
    while i < len(command):
        if command[i] in ("-o", "-MF", "-MQ", "-MT"):
            i += 2
            continue
        if command[i] not in ("-c", "-MD", "-MMD") and not command[i].endswith("/vrend_renderer.c"):
            flags.append(command[i])
        i += 1
    here = Path(__file__).parent
    oracle = output / "libgl-oracle.dylib"
    subprocess.run([command[0], "-dynamiclib", str(here / "gl-oracle.c"), "-framework", "OpenGL",
                    "-install_name", "@rpath/libgl-oracle.dylib", "-o", str(oracle)], check=True)
    text = original.read_text()
    mutant = original.with_name("vrend_renderer.mutant.c")
    survivors = 0
    try:
        for n, (what, pattern) in enumerate(MUTANTS):
            changed, count = re.subn(pattern, "", text)
            if count != 1:
                print("FAIL: mutant '%s' matches %d places, not 1" % (what, count))
                survivors += 1
                continue
            mutant.write_text(changed)
            binary = output / ("mutant-%d" % n)
            subprocess.run([command[0], *flags, "-I" + str(source),
                            '-DVREND_RENDERER_C="vrend/vrend_renderer.mutant.c"', "-w",
                            str(here / "test-index-range-cache.c"), str(source / "virglrenderer.c"),
                            str(build / "src/libvirgl.a"), str(build / "src/gallium/libgallium.a"),
                            str(build / "src/mesa/libmesa.a"), *link_args,
                            "-L" + str(output), "-lgl-oracle", "-Wl,-rpath," + str(output),
                            "-o", str(binary)], cwd=directory, check=True)
            run = subprocess.run([str(binary)], capture_output=True, text=True,
                                 env={**os.environ, "VIRGL_LOG_LEVEL": "silent"})
            failed = [l for l in (run.stdout + run.stderr).splitlines()
                      if l.startswith("FAIL") or l.startswith("GL ORACLE")]
            if run.returncode == 0:
                print("FAIL: mutant '%s' passes the test (not covered)" % what)
                survivors += 1
            else:
                print("ok: mutant '%s' caught: %s" % (what, failed[0] if failed else
                                                     "exit %d" % run.returncode))
    finally:
        if mutant.exists():
            mutant.unlink()
    print("index range cache mutants: %s" % ("%d not caught" % survivors if survivors else
                                             "all %d caught" % len(MUTANTS)))
    return 1 if survivors else 0


if __name__ == "__main__":
    sys.exit(main())
