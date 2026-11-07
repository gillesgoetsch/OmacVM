#!/bin/bash
# Benchmarks, the same way on the Mac and in a VM, so the routes compare.
#   bench.sh [--runs N] [--only geekbench,speedometer,jetstream,motionmark,aquarium,basemark,webgpu,scroll,gpu,glmark2] [OUT.jsonl]
# Google Chrome everywhere (in a VM: install-chrome.sh first), run as the
# desktop user in the session. Each test runs N times (default 3); every result is a
# JSON line in OUT (default ./bench-<host>-<date>.jsonl).
# Geekbench's free version uploads each result to browser.geekbench.com.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
RUNS=3; ONLY=geekbench,speedometer,jetstream,motionmark,aquarium,basemark,scroll,gpu
while [[ ${1:-} == --* ]]; do
  case $1 in
    --runs) RUNS=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
OS=$(uname -s)
OUT=${1:-$PWD/bench-$(hostname -s)-$(date +%Y%m%d-%H%M).jsonl}
want() { [[ ,$ONLY, == *,$1,* ]]; }
say() { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
rec() {   # test run value [extra json]
  printf '{"host":"%s","os":"%s","test":"%s","run":%s,"value":%s%s,"at":"%s"}\n' \
    "$(hostname -s)" "$OS" "$1" "$2" "$3" "${4:+,$4}" "$(date -u +%FT%TZ)" | tee -a "$OUT"
}

# ---- Geekbench 7 ----
if [[ $OS == Darwin ]]; then
  GB=${GEEKBENCH_MAC:-/Applications/Geekbench 7.app}/Contents/Resources/geekbench7   # GEEKBENCH_MAC: the app elsewhere
else
  GB=$HOME/.cache/omacvm-bench/Geekbench-7.0.0-LinuxARMPreview/geekbench7
  if [[ ! -x $GB ]]; then
    mkdir -p "$HOME/.cache/omacvm-bench"
    curl -fsSL https://cdn.geekbench.com/Geekbench-7.0.0-LinuxARMPreview.tar.gz | tar -xz -C "$HOME/.cache/omacvm-bench"
  fi
fi
# The free version prints only a link to the result; report.py reads the
# scores from there later, on the Mac.
GB_LOG=$(mktemp); trap 'rm -f "$GB_LOG"' EXIT
gb_run() {   # args... -> url; Geekbench's own output stays in $GB_LOG
  "$GB" "$@" >"$GB_LOG" 2>&1
  grep -o 'https://browser.geekbench.com/v7/[a-z]*/[0-9]*' "$GB_LOG" | tail -1
}
if want geekbench; then
  for ((i = 1; i <= RUNS; i++)); do
    say "Geekbench 7 CPU, run $i/$RUNS"
    url=$(gb_run --cpu)
    rec geekbench-cpu "$i" null "\"url\":\"${url:-}\""
  done
fi
# A VM's GPU device for an API, or why there is none. Only a real GPU counts:
# a CPU device (PoCL, llvmpipe, lavapipe, SwiftShader) next to it could be the
# one Geekbench picks, so that is "not available" too, with the reason.
CPU_DEV='pocl|llvmpipe|lavapipe|swiftshader|softpipe|PHYSICAL_DEVICE_TYPE_CPU| CPU$'
gpu_device() {   # OpenCL|Vulkan -> prints the device; exit 1 with the reason on stdout
  local devs   # one line per device: "name type" (OpenCL) or "type name" (Vulkan)
  if [[ $1 == OpenCL ]]; then
    command -v clinfo >/dev/null || { echo "clinfo missing (pacman -S clinfo)"; return 1; }
    devs=$(clinfo 2>/dev/null | grep -E '^ *Device (Name|Type) ' | sed 's/^ *Device [A-Za-z]* *//' | paste -d' ' - -)
  else
    command -v vulkaninfo >/dev/null || { echo "vulkaninfo missing (pacman -S vulkan-tools)"; return 1; }
    devs=$(vulkaninfo --summary 2>/dev/null | grep -E '^\s*(deviceType|deviceName) *=' | sed 's/.*= *//' | paste -d' ' - -)
  fi
  [[ -n $devs ]] || { echo "no $1 device in this VM"; return 1; }
  if grep -Eqi "$CPU_DEV" <<<"$devs"; then
    grep -Evqi "$CPU_DEV" <<<"$devs" || { echo "CPU $1 only ($(head -1 <<<"$devs")), no GPU"; return 1; }
    echo "a CPU $1 device next to the GPU ($(grep -Ei "$CPU_DEV" <<<"$devs" | head -1)): remove it so it can't be picked"; return 1
  fi
  head -1 <<<"$devs"
}
if want gpu; then
  # The Mac: Metal and OpenCL. A VM: Vulkan and OpenCL where the VM has a GPU
  # device for them (OmacVM.app with Venus and rusticl); the other VMs have none.
  # GEEKBENCH_GPU_APIS: only these (e.g. "OpenCL" when Metal is not compared).
  apis=${GEEKBENCH_GPU_APIS:-$([[ $OS == Darwin ]] && echo "Metal OpenCL" || echo "Vulkan OpenCL")}
  for api in $apis; do
    dev=
    if [[ $OS != Darwin ]]; then
      dev=$(gpu_device "$api") || { rec "geekbench-gpu-$api" 1 null "\"error\":\"not available: $dev\""; continue; }
    fi
    # No check with --gpu-list: in the VMs it listed no OpenCL device although
    # clinfo had the rusticl GPU and --gpu OpenCL ran fine. Run it; when the
    # first run gives no result, Geekbench has no such device: say why.
    for ((i = 1; i <= RUNS; i++)); do
      say "Geekbench 7 GPU ($api), run $i/$RUNS"
      url=$(gb_run --gpu "$api")
      if [[ -z $url && $i == 1 && $OS != Darwin ]]; then
        why=$(grep -v '^ *$' "$GB_LOG" | tail -1 | tr -d '"\\' | cut -c1-200)
        rec "geekbench-gpu-$api" 1 null "\"error\":\"not available: Geekbench ran no $api workload (${why:-no output})\""
        break
      fi
      rec "geekbench-gpu-$api" "$i" null "\"url\":\"${url:-}\",\"device\":\"${dev//\"/}\""
    done
  done
fi

# ---- browser: Speedometer 3.1, JetStream 2.2, MotionMark 1.3.1, WebGL Aquarium, Basemark Web 3.0, scrolling ----
browser_start() {
  PROFILE=$(mktemp -d)
  if [[ $OS == Darwin ]]; then
    # Full screen without the toolbar, as in a VM: the same page size.
    mkdir -p "$PROFILE/Default"
    echo '{"browser":{"show_fullscreen_toolbar":false}}' > "$PROFILE/Default/Preferences"
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --user-data-dir="$PROFILE" \
      --remote-debugging-port=9222 --no-first-run --no-default-browser-check --start-fullscreen --enable-gpu-benchmarking about:blank \
      >/dev/null 2>&1 &
  else
    # Google Chrome, as on the Mac (install-chrome.sh); Arch's Chromium is slower.
    [[ -x /opt/google/chrome/google-chrome ]] || { echo "Google Chrome is missing: install-chrome.sh" >&2; return 1; }
    # The flags Omarchy launches Chrome with (--ignore-gpu-blocklist
    # in /etc/chrome-flags.conf), without its extensions. The binary itself, not
    # the launcher, so the flags are not added twice.
    local flags=() f
    for f in /etc/chrome-flags.conf "$HOME/.config/chrome-flags.conf"; do
      if [[ -f $f ]]; then mapfile -t -O "${#flags[@]}" flags < <(grep -v -e '^#' -e '^$' -e '--load-extension' "$f"); fi
    done
    # WebGPU: Chrome on Linux hands pages a Vulkan adapter only with its compositor on Vulkan (Skia
    # Graphite on Dawn), which it allows only on X11 (Xwayland): OmacVM's omacvm-chrome-webgpu flags,
    # the same in every VM. MESA_VK_WSI_DEBUG=sw as there (Venus presents through the software path).
    local plat=(--ozone-platform=wayland) envs=()
    if [[ ${CHROME_WEBGPU:-0} == 1 ]]; then
      plat=(--ozone-platform=x11 --enable-skia-graphite --skia-graphite-dawn-backend=vulkan)
      envs=(MESA_VK_WSI_DEBUG=sw DISPLAY="${DISPLAY:-:0}")
    fi
    env ${envs[@]+"${envs[@]}"} /opt/google/chrome/google-chrome "${flags[@]}" "${plat[@]}" --user-data-dir="$PROFILE" --remote-debugging-port=9222 \
      --no-first-run --no-default-browser-check --start-fullscreen --enable-gpu-benchmarking about:blank >/dev/null 2>&1 &
  fi
  BROWSER=$!
  for _ in $(seq 30); do curl -fs http://127.0.0.1:9222/json/version >/dev/null && return 0; sleep 1; done
  echo "the browser did not start" >&2; return 1
}
browser_stop() { kill "$BROWSER" 2>/dev/null; wait "$BROWSER" 2>/dev/null; rm -rf "$PROFILE" "$PROFILE.err"; }
if want speedometer || want jetstream || want motionmark || want aquarium || want basemark || want webgpu || want scroll; then
  browser_start || exit 1
  version=$(curl -fs http://127.0.0.1:9222/json/version | python3 -c 'import json,sys; print(json.load(sys.stdin)["Browser"])')
  for t in speedometer jetstream motionmark aquarium basemark webgpu scroll; do
    want $t || continue
    for ((i = 1; i <= RUNS; i++)); do
      say "$t, run $i/$RUNS ($version)"
      v=$(python3 "$here/browser-bench.py" "$t" 2>"$PROFILE.err")
      extra=""
      if [[ $t == webgpu ]]; then   # the adapter (a CPU one is no GPU number), or the page's error
        extra=$(python3 "$here/webgpu-result.py" "$v" "$PROFILE.err")
        [[ $extra == *'"error"'* ]] && v=""
      fi
      [[ $v =~ ^[0-9.]+$ ]] || v=null
      # The page size Chrome gave the test (it must be the same everywhere).
      vp=$(sed -n 's/^viewport //p' "$PROFILE.err" | head -1)
      rec "$t" "$i" "$v" "\"browser\":\"$version\",\"viewport\":\"$vp\"${extra:+,$extra}"
      [[ $v == null ]] && break   # no result: the next runs would end the same way
    done
  done
  browser_stop
fi

# ---- the VM's OpenGL: renderer and glmark2 ----
if [[ $OS == Linux ]] && want glmark2; then
  renderer=$(eglinfo -B 2>/dev/null | grep -m1 -i "renderer" | sed 's/.*: //')
  [[ -n $renderer ]] || renderer=$(glxinfo -B 2>/dev/null | sed -n 's/.*OpenGL renderer string: //p')
  vk=$(vulkaninfo --summary 2>/dev/null | sed -n 's/.*deviceName *= *//p' | head -1)
  rec gpu-renderer 1 "\"${renderer:-unknown}\"" "\"vulkan\":\"${vk:-none}\""
  if command -v glmark2-es2-wayland >/dev/null; then
    for ((i = 1; i <= RUNS; i++)); do
      say "glmark2, run $i/$RUNS"
      s=$(glmark2-es2-wayland --fullscreen 2>&1 | sed -n 's/.*glmark2 Score: *\([0-9]*\).*/\1/p')
      rec glmark2 "$i" "${s:-null}"
    done
  else rec glmark2 1 null '"error":"glmark2 not installed"'; fi
fi
say "results: $OUT"
