#!/usr/bin/env python3
"""Static guard for the index range cache (virgl-index-range-cache.patch).

A cached index range is right only while nothing writes the index buffer behind the
cache's back. This lists every GL call in the patched renderer (src/) that can write a
buffer object, or bind one where the GPU writes it, and checks each against the reviewed
list below:
  bumps     - the function calls vrend_resource_contents_changed() (the cache sees it);
  flags     - a draw-time bind of a buffer whose set_* entry point (named) marks it with
              vrend_resource_no_index_range_cache() (never cached again);
  via       - a helper, callback or macro used only by the named functions, which bump
              or flag;
  read      - a mapping for reading only;
  own       - a buffer vrend owns (never a guest resource) or one being created;
  framebuffer - glClearBuffer* on the framebuffer, not on a buffer object.
A new write path (an upstream update, another patch) is not on the list and fails the
build until someone reviews it; an entry whose call is gone fails too.
Usage: index-range-writes.py <virglrenderer source dir>
"""
import re
import sys
from pathlib import Path

BUMP = "vrend_resource_contents_changed("
FLAG = "vrend_resource_no_index_range_cache("

# (file under src/, enclosing function or macro, GL call) -> (kind, argument)
REVIEWED = {
    ("vrend/vrend_renderer.c", "vrend_renderer_transfer_write_iov", "glMapBufferRange"): ("bumps", None),
    ("vrend/vrend_renderer.c", "iov_buffer_upload", "glBufferSubData"):
        ("via", ["vrend_renderer_transfer_write_iov"]),
    ("vrend/vrend_renderer.c", "vrend_resource_buffer_copy", "glBindBuffer"): ("bumps", None),
    ("vrend/vrend_renderer.c", "vrend_resource_buffer_copy", "glCopyBufferSubData"): ("bumps", None),
    ("vrend/vrend_renderer.c", "COPY_QUERY_RESULT_TO_BUFFER", "glBindBuffer"):
        ("via", ["vrend_get_query_result_qbo"]),
    ("vrend/vrend_renderer.c", "COPY_QUERY_RESULT_TO_BUFFER", "glMapBufferRange"):
        ("via", ["vrend_get_query_result_qbo"]),
    ("vrend/vrend_renderer.c", "vrend_get_query_result_qbo", "glBindBuffer"):
        ("flags", ["vrend_get_query_result_qbo"]),
    ("vrend/vrend_renderer.c", "vrend_get_query_result_qbo", "glGetQueryObjectiv"):
        ("flags", ["vrend_get_query_result_qbo"]),
    ("vrend/vrend_renderer.c", "vrend_get_query_result_qbo", "glGetQueryObjectuiv"):
        ("flags", ["vrend_get_query_result_qbo"]),
    ("vrend/vrend_renderer.c", "vrend_get_query_result_qbo", "glGetQueryObjecti64v"):
        ("flags", ["vrend_get_query_result_qbo"]),
    ("vrend/vrend_renderer.c", "vrend_get_query_result_qbo", "glGetQueryObjectui64v"):
        ("flags", ["vrend_get_query_result_qbo"]),
    ("vrend/vrend_renderer.c", "vrend_renderer_resource_map", "glMapBufferRange"):
        ("flags", ["vrend_renderer_resource_map"]),
    ("vrend/vrend_renderer.c", "vrend_draw_bind_ssbo_shader", "glBindBufferRange"):
        ("flags", ["vrend_set_single_ssbo"]),
    ("vrend/vrend_renderer.c", "vrend_draw_bind_abo_shader", "glBindBufferRange"):
        ("flags", ["vrend_set_single_abo"]),
    ("vrend/vrend_renderer.c", "vrend_draw_bind_images_shader", "glBindImageTexture"):
        ("flags", ["vrend_set_single_image_view"]),
    ("vrend/vrend_renderer.c", "vrend_hw_emit_streamout_targets", "glBindBufferBase"):
        ("flags", ["vrend_create_so_target"]),
    ("vrend/vrend_renderer.c", "vrend_hw_emit_streamout_targets", "glBindBufferRange"):
        ("flags", ["vrend_create_so_target"]),
    ("vrend/vrend_renderer.c", "vrend_create_buffer", "glBufferStorage"): ("own", "a new buffer"),
    ("vrend/vrend_renderer.c", "vrend_create_buffer", "glBufferData"): ("own", "a new buffer"),
    ("vrend/vrend_renderer.c", "vrend_create_buffer", "glBufferStorageMemEXT"):
        ("own", "a new buffer (GBM, not on macOS; never cached: memory object)"),
    ("vrend/vrend_renderer.c", "bind_virgl_block_loc", "glBufferData"):
        ("own", "vrend's system value uniform block"),
    ("vrend/vrend_renderer.c", "vrend_fill_sysval_uniform_block", "glBufferSubData"):
        ("own", "vrend's system value uniform block"),
    ("vrend/vrend_renderer.c", "vrend_draw_bind_vertex_legacy", "glMapBufferRange"): ("read", None),
    ("vrend/vrend_renderer.c", "vrend_read_gl_buffer", "glMapBufferRange"): ("read", None),
    ("vrend/vrend_renderer.c", "vrend_renderer_transfer_send_iov", "glMapBufferRange"): ("read", None),
    ("vrend/vrend_renderer.c", "vrend_clear", "glClearBufferuiv"): ("framebuffer", None),
    ("vrend/vrend_renderer.c", "vrend_clear", "glClearBufferiv"): ("framebuffer", None),
    ("vrend/vrend_renderer.c", "vrend_clear", "glClearBufferfv"): ("framebuffer", None),
    ("vrend/vrend_blitter.c", "vrend_renderer_blit_gl", "glBufferData"): ("own", "the blitter's vertices"),
    ("vrend/vrend_video.c", "vrend_video_encode_completed", "glMapBufferRange"): ("bumps", None),
}

# Calls that write a buffer's contents, map it, or bind it where the GPU writes.
WRITE_CALLS = re.compile(
    r"\b(glBufferSubData|glBufferData|glBufferStorage\w*|glCopyBufferSubData|glClearBuffer\w*|"
    r"glClearNamedBuffer\w*|glMapBuffer\w*|glMapNamedBuffer\w*|glNamedBuffer\w*|"
    r"glCopyNamedBufferSubData|glBindImageTexture\w*|glGetQueryBufferObject\w*|"
    r"glInvalidateBuffer\w*|glFlushMappedBufferRange\w*)\s*\(")
BIND_RANGE = re.compile(r"\b(glBindBuffer(?:s)?(?:Base|Range)\w*)\s*\(\s*([A-Z0-9_]+|\w+)")
BIND = re.compile(r"\b(glBindBuffer(?:ARB)?)\s*\(\s*(GL_\w+)\s*,\s*([^)]*)\)")
WRITE_TARGETS = ("GL_QUERY_BUFFER", "GL_PIXEL_PACK_BUFFER", "GL_PIXEL_PACK_BUFFER_ARB",
                 "GL_COPY_WRITE_BUFFER", "GL_TRANSFORM_FEEDBACK_BUFFER",
                 "GL_SHADER_STORAGE_BUFFER", "GL_ATOMIC_COUNTER_BUFFER")
QUERY_TO_BUFFER = re.compile(r"\b(glGetQueryObject\w+)\s*\([^;]*buffer_offset\s*\(")
FUNC_NAME = re.compile(r"^(?:[A-Za-z_][\w\s\*]*?\s\**)?([A-Za-z_]\w*)\s*\(")
MACRO_NAME = re.compile(r"^#\s*define\s+([A-Za-z_]\w*)\(")


STRIP = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//.*$')


def scopes(lines):
    """For each line: the function or function-like macro it belongs to (None at file
    scope). Functions are found by brace depth; the name is the identifier before the
    first '(' of the last declaration that started in column 0."""
    owner = [None] * len(lines)
    depth = 0
    candidate = current = None
    in_macro = None
    in_comment = False
    for i, line in enumerate(lines):
        m = MACRO_NAME.match(line)
        if m and depth == 0:
            in_macro = m.group(1)
        if in_macro:
            owner[i] = in_macro
            if not line.rstrip().endswith("\\"):
                in_macro = None
            continue
        code = line
        if in_comment:
            end = code.find("*/")
            if end < 0:
                owner[i] = current
                continue
            code = code[end + 2:]
            in_comment = False
        code = STRIP.sub("", code)
        while "/*" in code:
            a = code.index("/*")
            b = code.find("*/", a + 2)
            if b < 0:
                code = code[:a]
                in_comment = True
                break
            code = code[:a] + code[b + 2:]
        if depth == 0 and line[:1] not in ("", " ", "\t", "#", "{", "}"):
            name = FUNC_NAME.match(line)
            candidate = name.group(1) if name and not line.rstrip().endswith(";") else candidate
        for ch in code:
            if ch == "{":
                if depth == 0:
                    current = candidate
                depth += 1
            elif ch == "}":
                depth = max(depth - 1, 0)
        owner[i] = current
        if line.startswith("}"):
            depth = 0  # a function ends in column 0 (keeps #ifdef'd braces from piling up)
        if depth == 0:
            current = None
    return owner


def bodies(files):
    """function name -> list of (file, text of its body) and every line's owner."""
    out = {}
    owners = {}
    for rel, lines in files.items():
        owner = scopes(lines)
        owners[rel] = owner
        for i, name in enumerate(owner):
            if name:
                out.setdefault(name, {}).setdefault(rel, []).append(lines[i])
    return {k: {f: "\n".join(v) for f, v in d.items()} for k, d in out.items()}, owners


def main():
    src = Path(sys.argv[1]) / "src"
    files = {}
    for path in sorted(src.rglob("*")):
        if path.suffix in (".c", ".h", ".m", ".cpp") and path.is_file():
            files[str(path.relative_to(src))] = path.read_text(errors="replace").split("\n")
    body, owners = bodies(files)

    found = {}
    for rel, lines in files.items():
        if rel.startswith("venus/") or rel.startswith("drm/"):
            continue  # Vulkan and DRM paths; no GL
        text = "\n".join(lines)
        owner = owners[rel]
        starts = [0]
        for line in lines:
            starts.append(starts[-1] + len(line) + 1)

        def line_of(pos):
            lo, hi = 0, len(lines)
            while lo < hi - 1:
                mid = (lo + hi) // 2
                if starts[mid] <= pos:
                    lo = mid
                else:
                    hi = mid
            return lo

        def note(call, pos):
            n = line_of(pos)
            if re.match(r"\s*(//|/\*|\*(\s|/|$))", lines[n]):
                return  # a comment
            key = (rel, owner[n], call)
            found.setdefault(key, []).append(n + 1)

        for m in WRITE_CALLS.finditer(text):
            note(m.group(1), m.start())
        for m in BIND_RANGE.finditer(text):
            if m.group(2) != "GL_UNIFORM_BUFFER":
                note(m.group(1), m.start())
        for m in BIND.finditer(text):
            if m.group(2) in WRITE_TARGETS and m.group(3).strip() not in ("0", "old_pbo"):
                note(m.group(1), m.start())
        for m in QUERY_TO_BUFFER.finditer(text):
            note(m.group(1), m.start())

    failures = 0
    for key, where in sorted(found.items(), key=lambda kv: (kv[0][0], kv[1][0])):
        rel, func, call = key
        at = "%s:%s %s() in %s" % (rel, ",".join(map(str, where)), call, func)
        review = REVIEWED.get(key)
        if not review:
            print("FAIL: %s writes a buffer and is not reviewed for the index range cache" % at)
            failures += 1
            continue
        kind, arg = review
        ok, why = True, kind
        if kind == "bumps":
            ok = BUMP in body.get(func, {}).get(rel, "")
            why = "bumps the content generation"
        elif kind == "flags":
            for setter in arg:
                ok &= any(FLAG in b for b in body.get(setter, {}).values())
            why = "never cached once bound (set in %s)" % ", ".join(arg)
        elif kind == "via":
            users = set()
            pattern = re.compile(r"\b%s\b" % re.escape(func))
            for frel, lines in files.items():
                for n, line in enumerate(lines):
                    # (a definition or prototype in column 0 is not a use)
                    if pattern.search(line) and owners[frel][n] != func and \
                            not (owners[frel][n] is None and line[:1].isalpha()):
                        users.add(owners[frel][n])
            ok = users <= set(arg) and all(
                BUMP in b or FLAG in b for u in arg for b in body.get(u, {}).values())
            used = ", ".join(sorted(map(str, users))) or "nobody"
            why = ("used only by %s, which bump or flag" % used if ok else
                   "used by %s; only %s may use it, and each must bump or flag" %
                   (used, ", ".join(arg)))
        elif kind == "read":
            calls = [l for n, l in enumerate(files[rel]) if owners[rel][n] == func and call in l]
            ok = all("GL_MAP_READ_BIT" in l and "WRITE" not in l for l in calls)
            why = "maps for reading only"
        elif kind == "framebuffer":
            calls = [l for n, l in enumerate(files[rel]) if owners[rel][n] == func and call in l]
            ok = all(re.search(r"\(\s*GL_(COLOR|DEPTH|STENCIL|DEPTH_STENCIL)\b", l) for l in calls)
            why = "clears the framebuffer"
        elif kind == "own":
            why = arg
        print("%s: %s: %s" % ("ok" if ok else "FAIL", at, why))
        failures += not ok

    for key in sorted(set(REVIEWED) - set(found)):
        print("FAIL: reviewed %s() in %s (%s) is gone: update the list" % (key[2], key[1], key[0]))
        failures += 1

    print("index range writes: %s" % ("FAILED" if failures else
                                      "every buffer write is reviewed (%d sites)" % len(found)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
