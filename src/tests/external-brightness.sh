#!/bin/bash
# Offline test of external display brightness in the VM (no VM, no Mac display):
# Omarchy's DDC/CI path (omarchy-brightness-display-ddc runs ddcutil) against
# OmacVM's ddcutil (src/bridge/guest/omacvm-ddcutil) and the Bridge client,
# with a stand-in Bridge that checks the token proof and records each request.
# 1. detect lists the VM's connected outputs as buses (Virtual-2: bus 2), the
#    one on the Mac's built-in display too, in the lines Omarchy's awk reads.
# 2. getvcp/setvcp 10 on OmacVM.app: the output's box from the app's layout goes
#    to the Bridge; the answer in ddcutil's --brief form.
# 3. Elsewhere (no layout): only Hyprland's focused output may ask.
# 4. Anything odd is refused before it reaches the Bridge.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap '{ kill ${PID:-} && wait ${PID:-}; } 2>/dev/null || true; rm -rf "$T"' EXIT
fail=0
is() { if [[ $1 == "$2" ]]; then echo "ok    $3"; else echo "FAIL  $3: got '$1', want '$2'"; fail=1; fi; }

TOKEN=$(openssl rand -hex 24); echo "$TOKEN" > "$T/token"
mkdir -p "$T/drm/card0-Virtual-1" "$T/drm/card0-Virtual-2" "$T/drm/card0-Virtual-3" "$T/run/omacvm" "$T/bin"
echo connected > "$T/drm/card0-Virtual-1/status"
echo connected > "$T/drm/card0-Virtual-2/status"
echo disconnected > "$T/drm/card0-Virtual-3/status"
echo Virtual-1 > "$T/run/omacvm/builtin"
# OmacVM.app's layout (omacvm-displays): the built-in below an external display.
cat > "$T/run/omacvm/displays.json" <<'J'
{"builtin": "Virtual-1", "external": true, "fullscreen": true, "layout": [
 {"output": "Virtual-2", "x": 0, "y": 0, "width": 1920, "height": 1200, "scale": 2},
 {"output": "Virtual-1", "x": 96, "y": 1238, "width": 1728, "height": 1079, "scale": 2}]}
J
# The stand-in Bridge: /proof as the real one, the brightness at 35.
cat > "$T/bridge.py" <<'PY'
import hashlib, hmac, http.server, json, os, sys, urllib.parse
token = open(sys.argv[1]).read().strip()
log = open(sys.argv[2], "a")
level = [35]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def handle_one(self, body):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/proof":
            n = urllib.parse.parse_qs(u.query)["nonce"][0]
            return self.reply(200, {"proof": hmac.new(token.encode(), f"omacvm-bridge mac 127.0.0.1 {n}".encode(), hashlib.sha256).hexdigest()})
        if self.headers.get("Authorization") != f"Bearer {token}":
            return self.reply(401, {"error": "token"})
        log.write(f"{self.command} {self.path} {body}\n"); log.flush()
        if os.path.exists(sys.argv[3]) and "width=1728" in self.path:   # an older Bridge
            return self.reply(409, {"error": "the built-in display: its brightness stays macOS's"})
        if body:
            o = json.loads(body)
            level[0] = max(0, min(100, round(o.get("brightness", level[0] + o.get("delta", 0)))))
        self.reply(200, {"brightness": level[0], "display": "Test", "method": "ddc"})
    def do_GET(self): self.handle_one("")
    def do_POST(self): self.handle_one(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PY
python3 "$T/bridge.py" "$T/token" "$T/requests" "$T/refuse-builtin" > "$T/port" & PID=$!
for _ in $(seq 300); do [[ -s $T/port ]] && break; sleep 0.1; done
PORT=$(cat "$T/port"); [[ $PORT =~ ^[0-9]+$ ]] || { echo "FAIL  the stand-in Bridge did not start"; exit 1; }
touch "$T/requests"
# The focused output for the non-app routes (hyprctl stand-in).
printf '#!/bin/bash\necho %s\n' "'[{\"name\": \"Virtual-1\", \"focused\": false}, {\"name\": \"Virtual-2\", \"focused\": true}]'" > "$T/bin/hyprctl"
chmod +x "$T/bin/hyprctl"

ddc() {
  env PATH="$T/bin:$PATH" XDG_RUNTIME_DIR="$T/run" OMACVM_VM_TYPE="${TYPE:-app}" \
    OMACVM_BRIDGE_URL="http://127.0.0.1:$PORT" OMACVM_BRIDGE_TOKEN_FILE="$T/token" \
    OMACVM_DDCUTIL_DRM="$T/drm" OMACVM_DDCUTIL_REAL="$T/no-ddcutil" OMACVM_DDCUTIL_BRIDGE="$R/src/bridge/guest/omacvm-bridge" \
    bash "$R/src/bridge/guest/omacvm-ddcutil" "$@"
}
last() { tail -1 "$T/requests"; }

# 1. detect, read the way omarchy-brightness-display-ddc reads it.
bus_of() {
  ddc --skip-ddc-checks detect --brief | awk -v monitor="$1" '
    /I2C bus:/ { bus = $NF; sub(/^.*\/i2c-/, "", bus) }
    /DRM connector:/ { connector = $NF; sub(/^card[0-9]+-/, "", connector)
      if (connector == monitor && bus != "") { print bus; exit } bus = "" }'
}
is "$(bus_of Virtual-2)" 2 "detect: Virtual-2 is bus 2"
is "$(bus_of Virtual-1)" 1 "detect: the output on the Mac's built-in display too (the Bridge sets it through macOS)"
is "$(bus_of Virtual-3)" "" "detect: not a disconnected output"

# 2. OmacVM.app: the box goes along.
is "$(ddc --bus 2 --skip-ddc-checks getvcp 10 --brief)" "VCP 10 C 35 100" "getvcp 10: ddcutil's --brief answer"
# Why, when it fails: the client's own words.
[[ -s $T/requests ]] || env XDG_RUNTIME_DIR="$T/run" OMACVM_VM_TYPE=app OMACVM_BRIDGE_URL="http://127.0.0.1:$PORT" \
  OMACVM_BRIDGE_TOKEN_FILE="$T/token" bash -x "$R/src/bridge/guest/omacvm-bridge" external-brightness --output Virtual-2 2>&1 | tail -15
is "$(last)" "GET /display/external-brightness?x=0&y=0&width=1920&height=1200 " "getvcp: Virtual-2's box from the layout"
ddc --bus 2 --skip-ddc-checks --noverify setvcp 10 44 >/dev/null
is "$(last)" 'POST /display/external-brightness?x=0&y=0&width=1920&height=1200 {"brightness": 44}' "setvcp 10 44"
is "$(ddc --bus 2 getvcp 10 --brief)" "VCP 10 C 44 100" "read back 44"
env XDG_RUNTIME_DIR="$T/run" OMACVM_VM_TYPE=app OMACVM_BRIDGE_URL="http://127.0.0.1:$PORT" OMACVM_BRIDGE_TOKEN_FILE="$T/token" \
  bash "$R/src/bridge/guest/omacvm-bridge" external-brightness --output Virtual-2 +05 >/dev/null
is "$(last | cut -d' ' -f3-)" '{"delta": 5}' "client: +05 is a delta of 5 (valid JSON)"

# The built-in display's output: its box goes along; the Bridge answers for it (method builtin).
is "$(ddc --bus 1 getvcp 10 --brief)" "VCP 10 C 49 100" "getvcp 10 on the built-in display's output"
is "$(last)" "GET /display/external-brightness?x=96&y=1238&width=1728&height=1079 " "  Virtual-1's box from the layout"
ddc --bus 1 setvcp 10 5 >/dev/null
is "$(last)" 'POST /display/external-brightness?x=96&y=1238&width=1728&height=1079 {"brightness": 5}' "  setvcp 10 5: 5 %"
# An older Bridge refuses the built-in display (409): no level, so Omarchy shows no slider there.
touch "$T/refuse-builtin"
rc=0; out=$(ddc --bus 1 getvcp 10 --brief) || rc=$?
is "$rc:$out" "1:" "an older Bridge's 409 for the built-in display: no answer, no slider"
rm "$T/refuse-builtin"
ddc --bus 2 setvcp 10 49 >/dev/null

# 3. Another VM type: no box; only the focused output.
TYPE=other
is "$(ddc --bus 2 getvcp 10 --brief)" "VCP 10 C 49 100" "elsewhere: the focused output asks"
is "$(last)" "GET /display/external-brightness " "elsewhere: no box"
n=$(wc -l < "$T/requests")
rc=0; ddc --bus 1 getvcp 10 --brief >/dev/null || rc=$?
is "$rc:$(wc -l < "$T/requests")" "1:$n" "elsewhere: another output does not ask"
TYPE=app

# 4. Refused in the VM already.
n=$(wc -l < "$T/requests")
for bad in "--bus 2 setvcp 10 101" "--bus 2 setvcp 10 abc" "--bus x getvcp 10" "--bus 7 getvcp 10" "getvcp 10"; do
  rc=0; ddc $bad >/dev/null 2>&1 || rc=$?
  is "$rc" 1 "refused: ddcutil $bad"
done
is "$(wc -l < "$T/requests")" "$n" "none of them reached the Bridge"
rc=0; ddc --version >/dev/null 2>&1 || rc=$?
is "$rc" 1 "other commands: the real ddcutil (none here: fails)"

# 5. The popup for an external display (the Bridge's osd event, as for the
#    brightness keys): Omarchy's brightness popup with the level; the display's
#    name stays out (omarchy-osd shows an icon and a level).
printf '#!/bin/bash\necho "$*" >> "%s/osd"\n' "$T" > "$T/bin/omarchy-osd"; chmod +x "$T/bin/omarchy-osd"
( PATH="$T/bin:$PATH"; source "$R/src/bridge/guest/omacvm-bridge-osd"
  show '{"type":"osd","kind":"brightness","value":44,"muted":false,"source":"keys","device":"Pi-X9"}' )
is "$(cat "$T/osd" 2>/dev/null)" "-i brightness -p 44" "popup: Omarchy's brightness OSD with the level, no name"

exit $fail
