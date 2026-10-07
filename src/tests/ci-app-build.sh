#!/bin/bash
# CI builds OmacVM.app the way a release does (build-app.sh), so an app build
# break shows on the pull request: the app job in .github/workflows/check.yml
# runs only on the Mac mini (own-repo pushes and pull requests, never forks),
# its QEMU runtime comes from a cache keyed by build-app.sh --runtime-inputs
# (.github/app-runtime-cache.sh). Offline: fake runtimes in a temp folder.
#   src/tests/ci-app-build.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: want '$2', got '$3'"; fi
}
# The cache script's answer and its exit code: a CI step fails on any but 0.
cache() {   # ARGS...
  local out rc
  out=$("$C" "$@"); rc=$?
  echo "$out"; [[ $rc == 0 ]] || echo "(exit $rc)"
}

# --- The workflow: one job per name, its lines as they are (no YAML module on
# macOS's python3).
/usr/bin/python3 - "$R/.github/workflows/check.yml" > "$T/wf" <<'EOF' || bad "check.yml does not read"
import re, sys
text = open(sys.argv[1]).read()
jobs, cur = {}, None
for line in text.split("\n")[text.split("\n").index("jobs:") + 1:]:
    m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
    if m:
        cur = m.group(1); jobs[cur] = []
    elif cur:
        jobs[cur].append(line)
def get(job, key):
    for l in jobs.get(job, []):
        m = re.match(r"^    " + key + r": (.*)$", l)
        if m: return m.group(1)
    return ""
app = jobs.get("app", [])
runs = [l.strip()[len("run: "):] if l.strip().startswith("run: ") else l.strip() for l in app]
body = "\n".join(app)
def first(pat):
    for i, l in enumerate(app):
        if re.search(pat, l): return i
    return -1
print("has_app=%d" % ("app" in jobs))
print("runs_on_same=%d" % (get("app", "runs-on") != "" and get("app", "runs-on") == get("check", "runs-on")))
print("runs_on_mini=%d" % ("omacvm-mini" in get("app", "runs-on")))
print("if=%s" % get("app", "if"))
print("timeout=%s" % get("app", "timeout-minutes"))
print("shell_bash=%d" % bool(re.search(r"^        shell: bash\s*$", body, re.M)))
b = first(r"app/scripts/build-app\.sh --name")
print("builds=%d" % (b >= 0))
print("not_release=%d" % (b >= 0 and "--release" not in app[b] and "--test-identity" not in app[b]))
print("key_before=%d" % (0 <= first(r"build-app\.sh --runtime-inputs") < first(r"app-runtime-cache\.sh restore") < b))
print("save_after=%d" % (first(r"app-runtime-cache\.sh save") > b))
c = first(r"git clean -ffdx")
print("cleanup_always=%d" % (c > 0 and any("if: always()" in l for l in app[max(0, c - 4):c])))
print("no_prt=%d" % ("pull_request_target" not in re.sub(r"#.*", "", text)))
print("checks_this=%d" % ("src/tests/ci-app-build.sh" in "\n".join(jobs.get("check", []))))
EOF
v() { sed -n "s/^$1=//p" "$T/wf"; }
expect "check.yml has an app job" 1 "$(v has_app)"
expect "the app job runs where the macOS check runs (same runs-on)" 1 "$(v runs_on_same)"
expect "... which is the mini for own-repo runs" 1 "$(v runs_on_mini)"
expect "the app job skips forks and manual runs" \
  "github.event_name == 'push' || github.event.pull_request.head.repo.full_name == github.repository" "$(v if)"
t=$(v timeout)
if [[ $t =~ ^[0-9]+$ ]] && (( t >= 10 && t <= 60 )); then ok "the app job has a time limit ($t min)"; else bad "the app job's timeout-minutes: '$t'"; fi
expect "the app job's steps run bash with pipefail (build-app.sh | tee)" 1 "$(v shell_bash)"
expect "the app job runs build-app.sh" 1 "$(v builds)"
expect "... not as a release, not the test identity" 1 "$(v not_release)"
expect "the runtime key comes from build-app.sh and the cache is read before the build" 1 "$(v key_before)"
expect "the runtime is kept after the build" 1 "$(v save_after)"
expect "the app job always cleans up (git clean)" 1 "$(v cleanup_always)"
expect "no pull_request_target in check.yml" 1 "$(v no_prt)"
expect "the check job runs this test" 1 "$(v checks_this)"

# --- build-app.sh --runtime-inputs: the hash only, nothing built, no git needed.
mkdir -p "$T/r/app" "$T/r/src"
cp -R "$R/app/scripts" "$T/r/app/"
(cd "$R" && git ls-files -z app/runtime) | (cd "$R" && xargs -0 tar -cf - 2>/dev/null) | tar -xf - -C "$T/r"
cp "$R/src/VERSION" "$T/r/src/"
B=$T/r/app/scripts/build-app.sh
k1=$("$B" --runtime-inputs 2>"$T/err"); rc=$?
expect "--runtime-inputs exits 0 (outside a git checkout)" 0 "$rc"
[[ $k1 =~ ^[0-9a-f]{64}$ ]] && ok "--runtime-inputs prints a SHA-256" || bad "--runtime-inputs printed '$k1' $(cat "$T/err")"
expect "--runtime-inputs is the same each time" "$k1" "$("$B" --runtime-inputs 2>/dev/null)"
expect "--runtime-inputs is the hash of this repo's runtime too" "$k1" "$("$R/app/scripts/build-app.sh" --runtime-inputs 2>/dev/null)"
[[ ! -e $T/r/app/runtime/.build && ! -e $T/r/app/dist && ! -e $T/r/app/app/.build ]] &&
  ok "--runtime-inputs builds nothing" || bad "--runtime-inputs built something"
p=$(cd "$T/r/app/runtime/patches" && ls | head -1)
echo "# changed" >> "$T/r/app/runtime/patches/$p"
k2=$("$B" --runtime-inputs 2>/dev/null)
[[ $k2 =~ ^[0-9a-f]{64}$ && $k2 != "$k1" ]] && ok "a changed runtime patch is another key" || bad "patch change: '$k1' -> '$k2'"
k3=$(OMACVM_FIRMWARE=qemu "$B" --runtime-inputs 2>/dev/null)
[[ $k3 =~ ^[0-9a-f]{64}$ && $k3 != "$k2" ]] && ok "QEMU's firmware is another key" || bad "OMACVM_FIRMWARE=qemu: '$k3'"
"$B" --runtime-inputs --bogus >/dev/null 2>&1; expect "an unknown option still fails" 2 "$?"

# --- The cache.
C=$R/.github/app-runtime-cache.sh
export OMACVM_CI_RUNTIME_CACHE=$T/cache
fake() {   # DIR KEY: a runtime build-app.sh would take
  mkdir -p "$1/qemu-gpu-runtime/bin" "$1/firmware" "$1/edk2/Build"
  printf '#!/bin/sh\n' > "$1/qemu-gpu-runtime/bin/qemu-system-aarch64"; chmod +x "$1/qemu-gpu-runtime/bin/qemu-system-aarch64"
  echo fw > "$1/firmware/edk2-aarch64-code.fd"; echo omacvm > "$1/firmware/firmware-source"
  echo big > "$1/edk2/Build/obj"
  echo "$2" > "$1/inputs.sha256"
}
K1=$(printf '1%.0s' {1..64}); K2=$(printf '2%.0s' {1..64}); K3=$(printf '3%.0s' {1..64}); K4=$(printf '4%.0s' {1..64})
expect "restore with an empty cache is a miss" miss "$(cache restore "$T/b0" "$K1")"
[[ ! -e $T/b0 ]] && ok "a miss leaves the build folder alone" || bad "a miss made $T/b0"
"$C" restore "$T/b0" "../x" >/dev/null 2>&1; expect "restore refuses a key that is not a hash" 2 "$?"
fake "$T/b1" "$K1"
expect "save keeps a complete runtime" saved "$(cache save "$T/b1")"
[[ ! -e $T/cache/$K1/edk2 ]] && ok "the edk2 build folder is not cached" || bad "edk2 went into the cache"
expect "save twice: have" have "$(cache save "$T/b1")"
[[ -z $(ls "$T/cache/$K1" | grep '^\.new') && $(ls -A "$T/cache" | wc -l | tr -d ' ') == 1 ]] &&
  ok "no half-saved folders left" || bad "cache has: $(ls -A "$T/cache" "$T/cache/$K1" | tr '\n' ' ')"
expect "restore of a saved key is a hit" hit "$(cache restore "$T/b2" "$K1")"
[[ -x $T/b2/qemu-gpu-runtime/bin/qemu-system-aarch64 && -f $T/b2/firmware/edk2-aarch64-code.fd ]] &&
  ok "the hit gives QEMU and the firmware" || bad "the hit is not complete"
expect "the hit's inputs.sha256 is the key" "$K1" "$(cat "$T/b2/inputs.sha256" 2>/dev/null)"
expect "restore of another key is a miss" miss "$(cache restore "$T/b3" "$K2")"
mkdir -p "$T/b4"
expect "restore never writes over a build folder that is there" "miss ($T/b4 is there already)" "$(cache restore "$T/b4" "$K1")"
fake "$T/h" "$K2"; touch "$T/h/qemu-gpu-runtime.test-hooks"
expect "a runtime with test hooks is never cached" "skip (no complete runtime in $T/h)" "$(cache save "$T/h")"
fake "$T/i" "$K2"; rm "$T/i/firmware/edk2-aarch64-code.fd"
expect "a runtime without firmware is not cached" "skip (no complete runtime in $T/i)" "$(cache save "$T/i")"
fake "$T/j" "not-a-hash"
expect "an inputs.sha256 that is not a hash is not cached" "skip ($T/j/inputs.sha256 is not a hash)" "$(cache save "$T/j")"
# A cache entry someone broke is a miss, not a half runtime.
mkdir -p "$T/cache/$K3"; echo "$K3" > "$T/cache/$K3/inputs.sha256"
expect "a broken cache entry is a miss" miss "$(cache restore "$T/b5" "$K3")"
rm -rf "${T:?}/cache/$K3"
# The newest KEEP stay (the one restored last counts as new).
fake "$T/s2" "$K2"; fake "$T/s3" "$K3"; fake "$T/s4" "$K4"
expect "save with room left" saved "$(cache save "$T/s2")"; sleep 1
expect "save of a third" saved "$(cache save "$T/s3")"; sleep 1
expect "restore marks the entry as used" hit "$(cache restore "$T/b6" "$K1")"; sleep 1
expect "save past KEEP" saved "$(OMACVM_CI_RUNTIME_KEEP=3 cache save "$T/s4")"
expect "the oldest entry goes past KEEP" "$K1 $K3 $K4" "$(ls "$T/cache" | grep -E '^[0-9a-f]{64}$' | tr '\n' ' ' | sed 's/ $//')"
unset OMACVM_CI_RUNTIME_CACHE
"$C" save "$T/s4" >/dev/null 2>&1; [[ $? != 0 ]] && ok "no cache folder set: refused" || bad "ran without OMACVM_CI_RUNTIME_CACHE"

exit $fail
