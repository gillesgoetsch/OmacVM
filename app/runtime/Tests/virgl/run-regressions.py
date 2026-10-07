#!/usr/bin/env python3
"""Build the format regression against the pinned renderer's compile flags."""
import json
import re
import os
from pathlib import Path
import shlex
import subprocess
import sys

build, output = map(lambda value: Path(value).resolve(), sys.argv[1:3])
output.mkdir(parents=True, exist_ok=True)
entries = json.loads((build / "compile_commands.json").read_text())
def run_test(name, implementation):
    entry = next(item for item in entries if item["file"].endswith("/" + implementation))
    command = entry.get("arguments") or shlex.split(entry["command"])
    directory = Path(entry["directory"])
    source = (directory / entry["file"]).resolve().parents[1]
    flags = []
    i = 1
    while i < len(command):
        flag = command[i]
        if flag in ("-o", "-MF", "-MQ", "-MT"):
            i += 2
            continue
        if flag not in ("-c", "-MD", "-MMD") and not flag.endswith("/" + implementation):
            flags.append(flag)
        i += 1
    binary = output / name
    link_args = sys.argv[3:]
    if link_args[:1] == ["--"]:
        link_args = link_args[1:]
    subprocess.run([command[0], *flags, "-I" + str(source),
                    str(Path(__file__).with_name(name + ".c")),
                    str(build / "src/libvirgl.a"), str(build / "src/gallium/libgallium.a"),
                    str(build / "src/mesa/libmesa.a"), *link_args, "-o", str(binary)],
                   cwd=directory, check=True)
    subprocess.run([str(binary)], check=True)


def oracle_link_args(compiler):
    """gl-oracle.c as a dylib: linked in, it checks every GL draw call's buffer ranges."""
    lib = output / "libgl-oracle.dylib"
    subprocess.run([compiler, "-dynamiclib", str(Path(__file__).with_name("gl-oracle.c")),
                    "-framework", "OpenGL", "-install_name", "@rpath/libgl-oracle.dylib",
                    "-o", str(lib)], check=True)
    return ["-L" + str(output), "-lgl-oracle", "-Wl,-rpath," + str(output)]


def vulkan_stub_link_args(compiler):
    """A libvulkan.1.dylib with only vkGetInstanceProcAddr (it finds nothing): enough for a
    Venus context to start, while any real Vulkan call fails. No Vulkan driver, no GPU."""
    stub = output / "vulkan-stub"
    stub.mkdir(exist_ok=True)
    (stub / "vulkan-stub.c").write_text(
        "void *vkGetInstanceProcAddr(void *instance, const char *name)\n"
        "{ (void)instance; (void)name; return 0; }\n")
    subprocess.run([compiler, "-dynamiclib", str(stub / "vulkan-stub.c"),
                    "-install_name", "@rpath/libvulkan.1.dylib",
                    "-o", str(stub / "libvulkan.1.dylib")], check=True)
    return ["-Wl,-rpath," + str(stub)]


def run_api_test(name, frameworks=(), oracle=False, vulkan_stub=False, env=None):
    """Link against the built libvirglrenderer and drive it through its public API.
    The tests run on Apple's software renderer (soft-gl.h), never on the GPU."""
    entry = next(item for item in entries if item["file"].endswith("/virglrenderer.c"))
    command = entry.get("arguments") or shlex.split(entry["command"])
    directory = Path(entry["directory"])
    source = (directory / entry["file"]).resolve().parent
    binary = output / name
    extra = oracle_link_args(command[0]) if oracle else []
    extra += vulkan_stub_link_args(command[0]) if vulkan_stub else []
    subprocess.run([command[0], "-I" + str(source), "-I" + str(build / "src"),
                    "-I" + str(build), str(Path(__file__).with_name(name + ".c")),
                    "-L" + str(build / "src"), "-lvirglrenderer",
                    "-Wl,-rpath," + str(build / "src"), *extra,
                    "-framework", "OpenGL", *[a for f in frameworks for a in ("-framework", f)],
                    "-Wno-deprecated-declarations", "-o", str(binary)],
                   cwd=directory, check=True)
    subprocess.run([str(binary)], check=True, env={**os.environ, **(env or {})})


def run_fuzz_replay():
    """Every input the fuzzer once crashed on, through the same harness, without libFuzzer."""
    entry = next(item for item in entries if item["file"].endswith("/virglrenderer.c"))
    command = entry.get("arguments") or shlex.split(entry["command"])
    directory = Path(entry["directory"])
    source = (directory / entry["file"]).resolve().parent
    here = Path(__file__).parent
    binary = output / "fuzz-replay"
    subprocess.run([command[0], "-I" + str(source), "-I" + str(build / "src"),
                    str(here / "fuzz-cmd-stream.c"), str(here / "fuzz-replay-main.c"),
                    "-L" + str(build / "src"), "-lvirglrenderer",
                    "-Wl,-rpath," + str(build / "src"), *oracle_link_args(command[0]),
                    "-framework", "OpenGL", "-Wno-deprecated-declarations", "-o", str(binary)],
                   cwd=directory, check=True)
    inputs = sorted(str(p) for p in (here / "fuzz-regressions").iterdir())
    subprocess.run([str(binary), *inputs], check=True,
                   env={**os.environ, "VIRGL_LOG_LEVEL": "silent"})


# Every GL call that changes VAO state (vertex attributes, the element buffer) or frees a
# buffer name, in vrend_renderer.c and vrend_video.c, must be in a function that tells the
# vertex cache (virgl-legacy-vertex-cache.patch): vrend_vertex_state_changed() or
# vrend_buffer_target_bound(), or be one of these reviewed places. A new upstream or
# OmacVM path that touches the VAO behind the cache fails the build until it is reviewed.
VERTEX_STATE_REVIEWED = {
    # function: (why it needs not tell the cache, the calls this covers; None = all of them)
    "vrend_draw_bind_vertex_legacy": ("the cached setup itself", None),
    "vrend_bind_element_buffer": ("the cached element buffer binding itself", None),
    "vrend_draw_bind_vertex_binding": ("GL 4.3 path: a VAO per vertex elements object, "
                                       "no cache there", None),
    "vrend_bind_vertex_elements_state": ("GL 4.3 path only: the elements' own VAO",
                                         r"glBindVertexArray\(v->id\)|glVertexAttribI?Format|"
                                         r"glVertexAttribBinding|glEnableVertexAttribArray"),
    "vrend_draw_vbo": ("GL 4.3 path only (no vertex elements bound)",
                       r"glBindVertexArray\(sub_ctx->vaoid\)"),
    "vrend_renderer_create_sub_ctx": ("a new VAO; the zeroed sub context has no record",
                                      r"glBindVertexArray\(sub->vaoid\)"),
    "vrend_destroy_sub_context": ("the VAO and its records go away "
                                  "(vrend_forget_vertex_setup)", None),
    "vrend_destroy_program": ("the sysval uniform buffer is never on a VAO; the program "
                              "generation it bumps also drops every recorded setup",
                              r"glDeleteBuffers\(1, &ent->ubo_sysval_buffer_id\)"),
    "vrend_video_encode_completed": ("reached only from video commands, and "
                                     "vrend_context_get_video_ctx() bumps the generation",
                                     r"glBindBufferARB\(cdc->dest_res->target"),
}
VAO_CALL = re.compile(
    r"\bgl(?:BindBuffer(?:ARB)?\s*\(\s*(?!GL_(?!ELEMENT_ARRAY_BUFFER)\w+\s*,)"
    r"|DeleteBuffers|VertexAttribI?Pointer|VertexAttribDivisor\w*|"
    r"(?:Enable|Disable)VertexAttribArray|BindVertexArray|DeleteVertexArrays|"
    r"VertexAttribI?Format|VertexAttribBinding|BindVertexBuffers?)\b")
FUNC_START = re.compile(r"^(?:static\s+)?(?:inline\s+)?[A-Za-z_][\w\s\*]*?\b(\w+)\s*\([^;]*$")


def functions(text):
    """(name, body) of each top-level function: from its first line to the next '}' at column 0."""
    lines = text.splitlines()
    out, i = [], 0
    while i < len(lines):
        m = FUNC_START.match(lines[i])
        if m and not lines[i].startswith(("typedef", "#")):
            j = i
            while j < len(lines) and lines[j] != "{" and not lines[j].rstrip().endswith("{"):
                if lines[j].rstrip().endswith(";"):
                    break
                j += 1
            if j < len(lines) and (lines[j] == "{" or lines[j].rstrip().endswith("{")):
                k = j + 1
                while k < len(lines) and lines[k] != "}":
                    k += 1
                out.append((m.group(1), "\n".join(lines[i:k + 1])))
                i = k + 1
                continue
        i += 1
    return out


def check_vertex_state_calls(src):
    problems, seen = [], set()
    tells = ("vrend_vertex_state_changed()", "vrend_buffer_target_bound(")
    for name in ("vrend_renderer.c", "vrend_video.c"):
        for func, body in functions((src / "vrend" / name).read_text()):
            if not VAO_CALL.search(body):
                continue
            seen.add(func)
            if any(t in body for t in tells):
                continue
            covered = VERTEX_STATE_REVIEWED.get(func, (None, r"(?!)"))[1]
            for line in body.splitlines():
                if VAO_CALL.search(line) and not (covered is None or re.search(covered, line)):
                    problems.append(f"{name}: {func}: {line.strip()}")
    video = dict(functions((src / "vrend" / "vrend_renderer.c").read_text()))
    if "vrend_vertex_state_changed()" not in video.get("vrend_context_get_video_ctx", ""):
        problems.append("vrend_context_get_video_ctx() no longer bumps vrend_vertex_state_gen")
    stale = sorted(set(VERTEX_STATE_REVIEWED) - seen)
    if stale:
        problems.append("reviewed functions without such calls any more: " + ", ".join(stale))
    if problems:
        raise SystemExit("vertex state calls the vertex cache does not hear about "
                         "(virgl-legacy-vertex-cache.patch):\n  " + "\n  ".join(problems))
    print(f"vertex state calls: {len(seen)} functions, all tell the vertex cache or are reviewed")


def renderer_source():
    entry = next(item for item in entries if item["file"].endswith("/virglrenderer.c"))
    return (Path(entry["directory"]) / entry["file"]).resolve().parent


run_test("test-multisample-formats", "vrend_formats.c")
run_test("test-native-shader-inputs", "vrend_renderer.c")
run_test("test-integer-sampler-shader", "vrend_shader.c")
run_api_test("test-video-decode", ("VideoToolbox", "CoreMedia", "CoreVideo", "CoreFoundation"))
run_test("test-transfer-row-size", "vrend_formats.c")
run_api_test("test-video-encode", ("VideoToolbox", "CoreMedia", "CoreVideo", "CoreFoundation"))
run_api_test("test-context-loss")
run_api_test("test-transform-feedback")
run_api_test("test-gpu-ranges", oracle=True)
run_api_test("test-resource-budget")
run_api_test("test-venus-budget-storage", vulkan_stub=True)
run_fuzz_replay()
run_test("test-darwin-eventfd", "virgl_util.c")
run_test("test-thread-sync-fallback", "vrend_renderer.c")
run_test("test-fence-wait-busy", "vrend_renderer.c")
run_test("test-core-glsl-shaders", "vrend_shader.c")
run_test("test-blitter-shaders", "vrend_blitter.c")
run_api_test("test-empty-framebuffer")
run_api_test("test-sampler-limit")
run_api_test("test-set-type-no-egl")
run_api_test("test-program-binds")
run_api_test("test-program-binds", env={"OMACVM_VIRGL_PROGRAM_CACHE": "0"})
check_vertex_state_calls(renderer_source())
run_test("test-view-key", "vrend_renderer.c")
run_api_test("test-vertex-binds", oracle=True)
run_api_test("test-vertex-binds", oracle=True, env={"OMACVM_VIRGL_SELECT_CACHE": "0"})
run_api_test("test-vertex-binds", oracle=True, env={"OMACVM_VIRGL_VERTEX_CACHE": "0"})
