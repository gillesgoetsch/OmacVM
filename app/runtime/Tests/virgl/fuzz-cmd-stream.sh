#!/bin/bash
# fuzz-cmd-stream.sh VIRGL_SOURCE DEPS_DIR [SECONDS]: build virglrenderer with ASan and
# libFuzzer coverage from a patched source tree (a kept runtime build:
# .build/tmp/omarchy-qemu-source-build.*/source/virglrenderer-1.3.0 and .../dependencies),
# replay fuzz-regressions/, then fuzz guest command streams (fuzz-cmd-stream.c) for SECONDS
# (default 600).
# Needs Homebrew llvm@22. Crashes land in ./fuzz-out/crash-*.
# Runs on Apple's software renderer only (soft-gl.h; the harness exits otherwise): random
# streams on the GPU made it fault and macOS panic (2026-10-04). gl-oracle.c aborts on any
# draw that would read or write outside a buffer, so such inputs are found here too.
set -euo pipefail
src=$(cd "$1" && pwd); deps=$(cd "$2" && pwd); secs=${3:-600}
here=$(cd "$(dirname "$0")" && pwd)
llvm=$(brew --prefix llvm@22)
out=$PWD/fuzz-out; mkdir -p "$out/corpus"
build=$out/virgl-asan
pc=$(ls -d "$deps"/{virglrenderer,libepoxy,angle,glib,pixman}/*/lib/pkgconfig 2>/dev/null | tr '\n' ':')
libs=$(ls -d "$deps"/{libepoxy,angle,glib,pixman,gettext,pcre2}/*/lib 2>/dev/null | tr '\n' ':')
angle_inc=$(ls -d "$deps"/angle/*/include)
meson=$(ls "$src"/../../tools/meson-*/meson.py)
ninja_dir=$(dirname "$(ls "$src"/../../tools/ninja-*.data/scripts/ninja)")
pyyaml=$(ls -d "$src"/../../tools/pyyaml-*)/lib
if [[ ! -f $build/build.ninja ]]; then
  env PATH="$ninja_dir:$PATH" PYTHONPATH="$pyyaml" PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$pc" CC="$llvm/bin/clang" OBJC="$llvm/bin/clang" \
    CFLAGS="-I$angle_inc -fsanitize=fuzzer-no-link -fsanitize=address -g" \
    OBJCFLAGS="-fsanitize=fuzzer-no-link -fsanitize=address -g" LDFLAGS="-fsanitize=address" \
    python3 "$meson" setup "$build" "$src" --buildtype=debugoptimized -Db_ndebug=false \
      --wrap-mode=nodownload -Ddrm-renderers=[] -Dvenus=false -Dtests=false -Dvideo=false \
      -Dtracing=none >/dev/null
fi
env PATH="$ninja_dir:$PATH" PYTHONPATH="$pyyaml" ninja -C "$build" >/dev/null
# The GL oracle (gl-oracle.c) checks every draw's buffer ranges; linking it is what
# makes its interposers active.
"$llvm/bin/clang" -g -dynamiclib "$here/gl-oracle.c" -framework OpenGL \
  -install_name @rpath/libgl-oracle.dylib -o "$out/libgl-oracle.dylib"
"$llvm/bin/clang" -g -fsanitize=fuzzer,address -I"$src/src" -I"$build/src" \
  "$here/fuzz-cmd-stream.c" -L"$build/src" -lvirglrenderer -Wl,-rpath,"$build/src" \
  -L"$out" -lgl-oracle -Wl,-rpath,"$out" \
  -framework OpenGL -Wno-deprecated-declarations -o "$out/fuzz-cmd-stream"
cd "$out"
# Known inputs first (each crashed or asked for 4 GiB before its fix), then fuzz.
env DYLD_LIBRARY_PATH="$libs" ASAN_OPTIONS=detect_leaks=0 VIRGL_LOG_LEVEL=silent ./fuzz-cmd-stream \
  -rss_limit_mb=4096 "$here"/fuzz-regressions/*
cp -n "$here"/fuzz-regressions/* corpus/ 2>/dev/null || true
# Huge but valid draws (billions of vertices) run for minutes on the software renderer:
# 20 s per input; a timeout (timeout-*) or the process outgrowing 4 GiB (oom-*, slow
# leaks add up over millions of contexts) is kept and fuzzing goes on in a fresh process.
# A crash or an oracle abort (crash-*) stops it, and so does any other failure that leaves
# no new timeout-* or oom-* file. (Fork mode would lose DYLD_LIBRARY_PATH: SIP.)
kept() { find . -maxdepth 1 \( -name 'timeout-*' -o -name 'oom-*' \) | wc -l; }
end=$((SECONDS + secs))
while ((SECONDS < end)); do
  rc=0 before=$(kept)
  env DYLD_LIBRARY_PATH="$libs" ASAN_OPTIONS=detect_leaks=0 VIRGL_LOG_LEVEL=silent ./fuzz-cmd-stream \
    -max_total_time=$((end - SECONDS)) -max_len=4096 -rss_limit_mb=4096 -timeout=20 corpus || rc=$?
  ls crash-* >/dev/null 2>&1 && exit 1
  [ $rc = 0 ] && break
  if (($(kept) == before)); then
    echo "fuzz-cmd-stream.sh: the fuzzer failed (exit $rc) without a crash, timeout or oom" >&2
    exit 1
  fi
done
