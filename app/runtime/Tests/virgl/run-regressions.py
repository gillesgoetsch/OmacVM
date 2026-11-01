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
def run_test(name, implementation, oracle=False, envs=(None,), sources=()):
    """Compile the test with the implementation's own flags (tests that include it), with
    more renderer sources if asked (paths under src/); run it once per environment."""
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
    extra = oracle_link_args(command[0]) if oracle else []
    subprocess.run([command[0], *flags, "-I" + str(source),
                    str(Path(__file__).with_name(name + ".c")), *[str(source / s) for s in sources],
                    str(build / "src/libvirgl.a"), str(build / "src/gallium/libgallium.a"),
                    str(build / "src/mesa/libmesa.a"), *link_args, *extra, "-o", str(binary)],
                   cwd=directory, check=True)
    for env in envs:
        subprocess.run([str(binary)], check=True, env={**os.environ, **(env or {})})


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


def interposer_link_args(compiler, name):
    """<name>.c as a dylib: a test's GL stand-in (its __interpose section replaces GL calls)."""
    lib = output / f"lib{name}.dylib"
    subprocess.run([compiler, "-dynamiclib", str(Path(__file__).with_name(name + ".c")),
                    "-framework", "OpenGL", "-Wno-deprecated-declarations",
                    "-install_name", f"@rpath/lib{name}.dylib", "-o", str(lib)], check=True)
    return ["-L" + str(output), "-l" + name, "-Wl,-rpath," + str(output)]


def run_api_test(name, frameworks=(), oracle=False, vulkan_stub=False, env=None,
                 interposer=None):
    """Link against the built libvirglrenderer and drive it through its public API.
    The tests run on Apple's software renderer (soft-gl.h), never on the GPU."""
    entry = next(item for item in entries if item["file"].endswith("/virglrenderer.c"))
    command = entry.get("arguments") or shlex.split(entry["command"])
    directory = Path(entry["directory"])
    source = (directory / entry["file"]).resolve().parent
    binary = output / name
    extra = oracle_link_args(command[0]) if oracle else []
    extra += vulkan_stub_link_args(command[0]) if vulkan_stub else []
    extra += interposer_link_args(command[0], interposer) if interposer else []
    subprocess.run([command[0], "-I" + str(source), "-I" + str(build / "src"),
                    "-I" + str(build), str(Path(__file__).with_name(name + ".c")),
                    "-L" + str(build / "src"), "-lvirglrenderer",
                    "-Wl,-rpath," + str(build / "src"), *extra,
                    "-framework", "OpenGL", *[a for f in frameworks for a in ("-framework", f)],
                    "-Wno-deprecated-declarations", "-o", str(binary)],
                   cwd=directory, check=True)
    subprocess.run([str(binary)], check=True, env={**os.environ, **(env or {})})


def run_const_ubo_random(seeds):
    """test-const-ubo's random runs (case 21, as run_api_test built it) in all three modes:
    each draw is checked by gl-oracle, and every mode must draw the same pixels."""
    hashes = {}
    for mode in ("default", "1", "0"):
        env = {**os.environ, "SEED": "1", "SEEDS": str(seeds)}
        env.pop("OMACVM_VIRGL_CONST_UBO", None)
        if mode != "default":
            env["OMACVM_VIRGL_CONST_UBO"] = mode
        run = subprocess.run([str(output / "test-const-ubo"), "21"], check=True, env=env,
                             capture_output=True, text=True)
        hashes[mode] = [line for line in run.stdout.splitlines() if line.startswith("random seed")]
        if len(hashes[mode]) != seeds:
            sys.exit(f"test-const-ubo random runs ({mode}): {len(hashes[mode])} of {seeds} seeds")
    if not hashes["default"] == hashes["1"] == hashes["0"]:
        sys.exit("test-const-ubo random runs: the modes drew different pixels")
    print(f"const ubo random runs: {seeds} seeds, same pixels in all three modes")


def run_write_guard():
    """Every GL call in the renderer that can write a buffer is on the index range cache's
    reviewed list (index-range-writes.py)."""
    entry = next(item for item in entries if item["file"].endswith("/vrend_renderer.c"))
    source = (Path(entry["directory"]) / entry["file"]).resolve().parents[2]
    subprocess.run([sys.executable, str(Path(__file__).with_name("index-range-writes.py")),
                    str(source)], check=True)


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
# Decoding beside vrend's thread (virgl-videotoolbox-decode-async.patch): polled fences, QEMU's
# sync-thread fences, and END_FRAME waiting for each picture as before (the way back).
for video_env in (None, {"OMACVM_TEST_THREAD_SYNC": "1"}, {"OMACVM_VIDEO_DECODE_SYNC": "1"}):
    run_api_test("test-video-decode-async", ("VideoToolbox", "CoreMedia", "CoreVideo", "CoreFoundation"),
                 env=video_env)
# The Mac's video service hangs at QEMU's start (virgl-videotoolbox-session-queue.patch): the
# caps wait for it once, 10 s at most; the next caps query and a decoder's create do not wait.
run_api_test("test-video-decode-async", ("VideoToolbox", "CoreMedia", "CoreVideo", "CoreFoundation"),
             env={"OMACVM_TEST_VIDEO_PROBE_HANG_MS": "300000"})
run_api_test("test-video-decode", ("VideoToolbox", "CoreMedia", "CoreVideo", "CoreFoundation"),
             env={"OMACVM_VIDEO_DECODE_SYNC": "1"})
# The rows and columns past a decoded picture (virgl-video-plane-edge.patch): both copy paths,
# and without the fill the test must see the bar; AV1 film grain into the buffer shown
# (virgl-video-av1-film-grain.patch) also when END_FRAME waits for each picture.
for video_env in (None, {"OMACVM_VIDEO_COPY": "1"}, {"OMACVM_VIDEO_EDGE_FILL": "0"},
                  {"OMACVM_VIDEO_DECODE_SYNC": "1"}):
    run_api_test("test-video-padding", ("VideoToolbox", "CoreMedia", "CoreVideo", "CoreFoundation"),
                 env=video_env)
# A texture the guest samples at its picture's size (virgl-resource-logical-size.patch); with
# OMACVM_VIDEO_LOGICAL=0 the renderer ignores the declarations and the test must see the strip.
for logical_env in (None, {"OMACVM_VIDEO_LOGICAL": "0"}):
    run_api_test("test-video-logical-size", env=logical_env)
run_test("test-transfer-row-size", "vrend_formats.c")
run_api_test("test-video-encode", ("VideoToolbox", "CoreMedia", "CoreVideo", "CoreFoundation"))
# the same with QEMU's fences: reported by the sync thread, held for encoder frames there
run_api_test("test-video-encode", ("VideoToolbox", "CoreMedia", "CoreVideo", "CoreFoundation"),
             env={"OMACVM_TEST_THREAD_SYNC": "1"})
# and with the low-latency constant QP session (encoders that refuse the QP range)
run_api_test("test-video-encode", ("VideoToolbox", "CoreMedia", "CoreVideo", "CoreFoundation"),
             env={"OMACVM_VIDEO_ENCODE_BASE_QP": "1"})
run_api_test("test-upload-pbo")
run_api_test("test-context-loss")
run_api_test("test-sysval-block", interposer="sysval-block-gl")
# Query results the GL does not answer reach the guest as done with 0, not stack bytes
# (virgl-query-result-unanswered.patch).
run_api_test("test-query-result", interposer="query-result-gl")
# Separable programs link on Apple's GL (virgl-shader-separable-pervertex.patch), and a failed
# pipeline validation is logged, not a lost context (virgl-pipeline-validate-log.patch);
# "lose" keeps upstream's context error.
run_api_test("test-separable-pervertex")
run_api_test("test-separable-pervertex", env={"OMACVM_VIRGL_SHADER_FAILURES": "lose"})
run_api_test("test-transform-feedback")
run_api_test("test-gpu-ranges", oracle=True)
run_api_test("test-resource-budget")
run_api_test("test-venus-budget-storage", vulkan_stub=True)
# A lost Venus context counts in the status file with its name, why and kind, like a GL one
# (virgl-venus-lost-context-count.patch); the teardown case is test-venus-robust.c's.
run_api_test("test-venus-lost-count", vulkan_stub=True)
run_fuzz_replay()
run_test("test-darwin-eventfd", "virgl_util.c")
run_test("test-thread-sync-fallback", "vrend_renderer.c")
run_test("test-fence-wait-busy", "vrend_renderer.c")
run_test("test-core-glsl-shaders", "vrend_shader.c")
run_test("test-blitter-shaders", "vrend_blitter.c")
# Vulkan windows without a copy (virgl-vulkan-windows-iosurface.patch): the re-stride and its layout check.
run_test("test-vulkan-window-restride", "vrend_blitter.c")
# GL work that crosses vrend's contexts is seen by the other one (virgl-darwin-context-switch-flush.patch,
# #499): the re-stride's window texture in the guest's next draw, bound each draw or once.
run_test("test-vulkan-window-handover", "vrend_blitter.c", envs=(None, {"OMACVM_TEST_BIND": "once"}))
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
run_write_guard()
run_test("test-index-range-cache", "vrend_renderer.c", oracle=True, sources=("virglrenderer.c",),
         envs=(None, {"OMACVM_VIRGL_INDEX_RANGE_CACHE": "0"}))
# Shader constants through uniform buffers (virgl-const-uniform-buffer.patch): vertex
# shaders through a window and an index, a range per draw (=1), uniforms as before (=0).
run_api_test("test-const-ubo", oracle=True)
run_api_test("test-const-ubo", oracle=True, env={"OMACVM_VIRGL_CONST_UBO": "1"})
run_api_test("test-const-ubo", oracle=True, env={"OMACVM_VIRGL_CONST_UBO": "0"})
run_const_ubo_random(seeds=24)
# Its separable case with a range per draw and a program bind per draw: all four stripes
# (Apple's software renderer sees a new range only once the pipeline is bound again).
subprocess.run([str(output / "test-const-ubo"), "15"], check=True,
               env={**os.environ, "OMACVM_VIRGL_CONST_UBO": "1", "OMACVM_VIRGL_PROGRAM_CACHE": "0"})
