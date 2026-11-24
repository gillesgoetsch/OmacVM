#!/bin/bash
# The Apple logo's light (feature logo-light): the VM's omacvm-logo against a
# made-up omacvm-bridge (its words, the JSON it sends, its exit codes), and the
# Bridge's side (src/bridge/mac/logo-model.swift, logo.swift) on a made-up
# logo. With --live, also on this Mac's lit Apple logo through the Bridge's own
# code: each mode for its seconds, then the logo is macOS's again. Stop a
# Bridge that plays a mode first: two writers fight over the logo.
#   src/tests/logo-light.sh [--live [WORDS SECONDS]...]   e.g. --live "on 50" 8 breathe 20 off 8
#   src/tests/logo-light.sh --state                      what the logo and macOS say now (reads only)
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
M=$R/src/bridge/mac
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
is() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

if [[ -z ${1:-} ]]; then
  mkdir "$T/bin"
  cat > "$T/bin/omacvm-bridge" <<'EOF'
#!/bin/bash
# omacvm-bridge logo [JSON] as the Bridge would answer: FAKE_OUT on stdout (auto when unset), FAKE_ERR on stderr, exit FAKE_RC.
[[ ${1:-} == logo ]] || exit 9
printf '%s\n' "${2:-GET}" > "$FAKE_SENT"
[[ -z ${FAKE_ERR:-} ]] || echo "$FAKE_ERR" >&2
if [[ -z ${FAKE_OUT+set} ]]; then echo '{"mode": "auto"}'; else printf '%s\n' "$FAKE_OUT"; fi
exit "${FAKE_RC:-0}"
EOF
  chmod +x "$T/bin/omacvm-bridge"
  logo() {   # ARGS...: prints "rc|stdout|what it sent|stderr's first line"
    local out err rc=0
    rm -f "$T/sent"
    out=$(PATH="$T/bin:$PATH" FAKE_SENT=$T/sent bash "$R/src/bridge/guest/omacvm-logo" "$@" 2>"$T/err") || rc=$?
    err=$(head -1 "$T/err")
    printf '%s|%s|%s|%s' "$rc" "$out" "$(cat "$T/sent" 2>/dev/null || echo -)" "$err"
  }
  is "the mode that plays, as its words" "0|on 50|GET|" "$(FAKE_OUT='{"mode": "on", "percent": 50}' logo)"
  is "breathe 15" "0|breathe 15|GET|" "$(FAKE_OUT='{"mode": "breathe", "rate": 15}' logo)"
  is "auto" "0|auto|GET|" "$(logo)"
  is "auto: sent, nothing printed" '0||{"mode": "auto"}|' "$(logo auto)"
  is "off" '0||{"mode": "off"}|' "$(logo off)"
  is "on: the Mac's default" '0||{"mode": "on"}|' "$(logo on)"
  is "on 080: a whole number" '0||{"mode": "on", "percent": 80}|' "$(logo on 080)"
  is "on 1" '0||{"mode": "on", "percent": 1}|' "$(logo on 1)"
  is "on 100" '0||{"mode": "on", "percent": 100}|' "$(logo on 100)"
  is "breathe 6" '0||{"mode": "breathe", "rate": 6}|' "$(logo breathe 6)"
  is "breathe 30" '0||{"mode": "breathe", "rate": 30}|' "$(logo breathe 30)"
  for bad in "on 0" "on 101" "on 5.5" "on -5" "on +5" "on 1000" "on x" "breathe 5" "breathe 31" "breathe 100" "breathe x" \
             "dim" "off 3" "auto auto" "on 50 x"; do
    # shellcheck disable=SC2086
    r=$(logo $bad); is "usage: omacvm-logo $bad (exit 2, nothing sent)" "2||-" "${r%|*}"
  done
  r=$(logo on ""); is "usage: on with an empty number" "2||-" "${r%|*}"
  is "the Mac has no lit logo: exit 3" "3||{\"mode\": \"off\"}|omacvm-logo: this Mac has no lit Apple logo" \
    "$(FAKE_RC=22 FAKE_OUT='{"error": "this Mac has no lit Apple logo", "code": "no-logo"}' logo off)"
  is "a macOS the Bridge cannot play it on: exit 1, its words" "1||GET|omacvm-logo: this macOS lacks a call" \
    "$(FAKE_RC=22 FAKE_OUT='{"error": "this macOS lacks a call", "code": "unsupported"}' logo)"
  is "off on the Mac: exit 1, its words" "1||GET|omacvm-logo: the logo light is off on this Mac" \
    "$(FAKE_RC=22 FAKE_OUT='{"error": "the logo light is off on this Mac", "code": "off"}' logo)"
  is "no Bridge that proves itself: exit 1, the client's words" "1||GET|omacvm-logo: omacvm-bridge: no proof" \
    "$(FAKE_RC=1 FAKE_OUT='' FAKE_ERR='omacvm-bridge: no proof' logo)"
  is "no answer at all: exit 1" "1||GET|omacvm-logo: curl: (7) Failed to connect" "$(FAKE_RC=7 FAKE_OUT='' FAKE_ERR='curl: (7) Failed to connect' logo)"
  is "an older Bridge (404): exit 1" "1||GET|omacvm-logo: the Mac's Bridge has no /logo yet: omacvm update on the Mac" "$(FAKE_RC=22 FAKE_OUT='{"error": "not found"}' FAKE_ERR='curl: (22) The requested URL returned error: 404' logo)"
fi

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -o "$T/logo-test" \
  "$M/control_policy.swift" "$M/logo-model.swift" "$M/logo.swift" "$M/tests/logo/main.swift" -framework IOKit
case ${1:-} in
  --live) shift; [[ $# -gt 0 ]] || set -- "on 50" 8 "on 80" 6 breathe 20 off 8 auto 5
          (cd "$T" && ./logo-test live "$@") ;;
  --state) "$T/logo-test" state ;;
  *) "$T/logo-test" || fail=1 ;;
esac
exit "$fail"
