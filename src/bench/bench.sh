#!/bin/bash
# Benchmarks, the same way on the Mac and in a VM, so the routes compare.
#   bench.sh [--runs N] [--only geekbench,speedometer,motionmark,aquarium,basemark,gpu,glmark2] [OUT.jsonl]
# Google Chrome everywhere (in a VM: install-chrome.sh first), run as the
# desktop user in the session. Each test runs N times (default 3); every result is a
# JSON line in OUT (default ./bench-<host>-<date>.jsonl).
# Geekbench's free version uploads each result to browser.geekbench.com.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
RUNS=3; ONLY=geekbench,speedometer,motionmark,aquarium,basemark,gpu
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
  GB="/Applications/Geekbench 7.app/Contents/Resources/geekbench7"
else
  GB=$HOME/.cache/omacvm-bench/Geekbench-7.0.0-LinuxARMPreview/geekbench7
  if [[ ! -x $GB ]]; then
    mkdir -p "$HOME/.cache/omacvm-bench"
    curl -fsSL https://cdn.geekbench.com/Geekbench-7.0.0-LinuxARMPreview.tar.gz | tar -xz -C "$HOME/.cache/omacvm-bench"
  fi
fi
# The free version prints only a link to the result; report.py reads the
# scores from there later, on the Mac.
gb_run() {   # args... -> url
  "$GB" "$@" 2>&1 | grep -o 'https://browser.geekbench.com/v7/[a-z]*/[0-9]*' | tail -1
}
if want geekbench; then
  for ((i = 1; i <= RUNS; i++)); do
    say "Geekbench 7 CPU, run $i/$RUNS"
    url=$(gb_run --cpu)
    rec geekbench-cpu "$i" null "\"url\":\"${url:-}\""
  done
fi
if want gpu; then
  # The Mac: Metal and OpenCL. A VM: Vulkan and OpenCL where Geekbench lists them
  # (its Linux ARM preview lists none and has no GPU test so far).
  apis=$([[ $OS == Darwin ]] && echo "Metal OpenCL" || echo "Vulkan OpenCL")
  for api in $apis; do
    "$GB" --gpu-list 2>&1 | grep -qi "$api" || [[ $OS == Darwin ]] || { rec "geekbench-gpu-$api" 1 null '"error":"not available in this VM"'; continue; }
    for ((i = 1; i <= RUNS; i++)); do
      say "Geekbench 7 GPU ($api), run $i/$RUNS"
      url=$(gb_run --gpu "$api")
      rec "geekbench-gpu-$api" "$i" null "\"url\":\"${url:-}\""
    done
  done
fi

# ---- browser: Speedometer 3.1, MotionMark 1.3.1, WebGL Aquarium, Basemark Web 3.0 ----
browser_start() {
  PROFILE=$(mktemp -d)
  if [[ $OS == Darwin ]]; then
    # Full screen without the toolbar, as in a VM: the same page size.
    mkdir -p "$PROFILE/Default"
    echo '{"browser":{"show_fullscreen_toolbar":false}}' > "$PROFILE/Default/Preferences"
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --user-data-dir="$PROFILE" \
      --remote-debugging-port=9222 --no-first-run --no-default-browser-check --start-fullscreen about:blank \
      >/dev/null 2>&1 &
  else
    # Google Chrome, as on the Mac (install-chrome.sh); Arch's Chromium is slower.
    [[ -x /opt/google/chrome/google-chrome ]] || { echo "Google Chrome is missing: install-chrome.sh" >&2; return 1; }
    # The flags Omarchy launches Chrome with (on Fusion: --ignore-gpu-blocklist
    # in /etc/chrome-flags.conf), without its extensions. The binary itself, not
    # the launcher, so the flags are not added twice.
    local flags=() f
    for f in /etc/chrome-flags.conf "$HOME/.config/chrome-flags.conf"; do
      if [[ -f $f ]]; then mapfile -t -O "${#flags[@]}" flags < <(grep -v -e '^#' -e '^$' -e '--load-extension' "$f"); fi
    done
    /opt/google/chrome/google-chrome "${flags[@]}" --ozone-platform=wayland --user-data-dir="$PROFILE" --remote-debugging-port=9222 \
      --no-first-run --no-default-browser-check --start-fullscreen about:blank >/dev/null 2>&1 &
  fi
  BROWSER=$!
  for _ in $(seq 30); do curl -fs http://127.0.0.1:9222/json/version >/dev/null && return 0; sleep 1; done
  echo "the browser did not start" >&2; return 1
}
browser_stop() { kill "$BROWSER" 2>/dev/null; wait "$BROWSER" 2>/dev/null; rm -rf "$PROFILE"; }
if want speedometer || want motionmark || want aquarium || want basemark; then
  browser_start || exit 1
  version=$(curl -fs http://127.0.0.1:9222/json/version | python3 -c 'import json,sys; print(json.load(sys.stdin)["Browser"])')
  for t in speedometer motionmark aquarium basemark; do
    want $t || continue
    for ((i = 1; i <= RUNS; i++)); do
      say "$t, run $i/$RUNS ($version)"
      v=$(python3 "$here/browser-bench.py" "$t")
      [[ $v =~ ^[0-9.]+$ ]] || v=null
      rec "$t" "$i" "$v" "\"browser\":\"$version\""
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
