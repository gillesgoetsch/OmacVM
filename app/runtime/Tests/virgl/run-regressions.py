#!/usr/bin/env python3
"""Build the format regression against the pinned renderer's compile flags."""
import json
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
run_write_guard()
run_test("test-index-range-cache", "vrend_renderer.c", oracle=True, sources=("virglrenderer.c",),
         envs=(None, {"OMACVM_VIRGL_INDEX_RANGE_CACHE": "0"}))
