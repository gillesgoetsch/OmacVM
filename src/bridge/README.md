# OmacVM Bridge

The Mac's Wi-Fi, Bluetooth, audio, media keys, display, battery and camera, inside the Omarchy
VM. The VM only has a virtual Ethernet card and a virtual sound card; the bridge is a
small Mac menu-bar app that serves the real thing as JSON over the private
VM network (Parallels, UTM or VMware Fusion) and pushes every change as Server-Sent Events.

| Part | Where |
|---|---|
| Mac app | `mac/*.swift` → `~/Applications/OmacVMBridge.app` (agent app, keyboard icon in the menu bar), LaunchAgent `org.omacvm.bridge`, log `~/Library/Logs/omacvm-bridge.log` |
| Listens on | port 47831 of the Mac's address on each VM network: `10.211.55.2` (Parallels' shared network), `192.168.64.1` (UTM's) and the `.1` of VMware Fusion's NAT network (`VNET_8_HOSTONLY_SUBNET` in `/Library/Preferences/VMware Fusion/networking`), and for OmacVM.app `127.0.0.1` and `192.168.77.1` (its fast network), never `0.0.0.0`. Waits for an address while its VM app is not running and re-binds after wake |
| Token | Mac `~/Library/Application Support/omacvm-bridge/token` (0600, made on first start); VM `~/.config/omacvm-bridge/token` (copied by `omacvm apply`) |
| Config | `~/Library/Application Support/omacvm-bridge/config.json`: `capture_keys`, `menu_bar_icon`, `keyboard_low_steps`, `external_brightness`, `brightness_steps` (read again within 2 s of a change; `omacvm apply` sets it from the feature) |
| VM client | `guest/omacvm-bridge` (bash + curl; the token never shows in `ps`, and goes only to a Bridge that proved it knows it, see API) |
| VM popups | `guest/omacvm-bridge-osd`, user service: the Mac's volume/brightness changes as Omarchy's own OSD |
| Shared event stream | `guest/omacvm-bridge-events`, user socket `omacvm-bridge-events.socket` (`$XDG_RUNTIME_DIR/omacvm-bridge-events.sock`): one `/events` connection to the Mac per VM; `omacvm-bridge events` reads from it, so the widgets and the OSD keep their interface (see Events) |
| Night light | `guest/omarchy-toggle-nightlight` in `/usr/local/bin`, ahead of Omarchy's: Super+Ctrl+N and the menu switch the Mac's Night Shift |
| Bar widgets | `plugins/omacvm.bluetooth`, `plugins/omacvm.wifi`, `plugins/omacvm.audio` (clones of Omarchy's Bluetooth, network and audio widgets; Super+Ctrl+B opens the Bluetooth one), `plugins/omacvm.nightshift` |

Only Apple frameworks: CoreWLAN, CoreLocation, CoreAudio, IOBluetooth,
CoreBluetooth (the permission), IOKit (the battery), AVFoundation (the camera), AppKit, Security, and the private
DisplayServices and CoreBrightness (brightness, Night Shift, True Tone,
keyboard light), and IOKit's private IOAVService (DDC/CI to external
displays, `external-brightness.swift`). Bluetooth power and forgetting a device use IOBluetooth's
private `IOBluetoothPreferenceSetControllerPowerState` and
`-[IOBluetoothDevice remove]` (as `blueutil` does), looked up at run time.

## Permissions

| Permission | For | Grant / revoke |
|---|---|---|
| Location Services | macOS only shows Wi-Fi names to apps with it; no location is read | prompt on first start; System Settings › Privacy & Security › Location Services |
| Accessibility | the event tap that takes the media keys while a VM is in front (logged as `permissions: ...`, shown by `omacvm check`) | prompt on first start; Privacy & Security › Accessibility, or `tccutil reset Accessibility org.omacvm.bridge` |
| Input Monitoring | the brightness keys read from the keyboard while an OmacVM.app VM is in front (`mac/hid-keys.swift`; on macOS 27 they reach no event tap) | Privacy & Security › Input Monitoring |
| Bluetooth | connecting, disconnecting, forgetting and switching from the VM (without it the devices are listed read-only, from macOS's system report) | prompt on first start; Privacy & Security › Bluetooth |
| Camera | the Mac's camera for UTM and VMware Fusion VMs (`GET /camera`) | prompt the first time a Linux app in such a VM uses the camera; Privacy & Security › Camera |

A UTM or Fusion VM with the camera on gets the Bridge also with the Bridge
feature off. Then only the camera needs a permission: the other prompts can
be answered with no.
| Keychain (per request) | the Wi-Fi password for QR sharing | macOS asks for an administrator's approval every time |

The menu-bar icon shows both grants and links to the settings. Permissions
survive rebuilds (see `../lib/sign.sh`).

## API

Every request needs `Authorization: Bearer <token>`; JSON in and out, errors
are `{"error": "…"}`. Only `GET /proof?nonce=N` (N: 32 hex digits) needs no
token: it answers `{"proof": HMAC-SHA256(token, "omacvm-bridge mac <addr> N")}`,
`<addr>` the Mac address the request came in on, and the client checks that
(with its own Mac address: 127.0.0.1 for OmacVM.app) before every request, so
a program listening in the Bridge's place (on 127.0.0.1 any Mac program could)
never gets the token, not even by passing on a proof from the Bridge on
10.211.55.2. The client wraps all of it:

```bash
omacvm-bridge state | scan [--cached] | audio | display | bluetooth | battery | events
omacvm-bridge volume +5 | mute | mic-volume 60 | output <uid>
omacvm-bridge brightness -5 | night-shift toggle | night-shift strength 70 | true-tone off
omacvm-bridge external | external-brightness [--output Virtual-N] [+5 | -5 | 40]
omacvm-bridge password [ssid]
omacvm-bridge bluetooth power toggle | connect AA:BB:CC:DD:EE:FF | disconnect … | forget … | settings
```

```bash
T=$(cat ~/.config/omacvm-bridge/token); B=http://10.211.55.2:47831   # UTM: http://192.168.64.1:47831
curl -H "Authorization: Bearer $T" $B/state
```

### Wi-Fi (read-only)

`GET /state`:

```json
{"interface":"en0","power":true,"connected":true,"location_authorized":true,
 "ssid":"Home","bssid":"aa:bb:cc:dd:ee:ff","rssi":-50,"noise":-93,"snr":43,"quality":66,
 "channel":{"number":36,"band":"5GHz","width_mhz":80},"security":"wpa2-personal","secure":true,
 "can_share":true,"tx_rate_mbps":866,"phy_mode":"802.11ac","country_code":"CH","seq":3,"updated_at":"…"}
```

`seq` counts the events that went out. Small Wi-Fi changes (signal, noise,
rate) wait up to 30 s, so `/state` can show newer values under the same `seq`.

- Disconnected or Wi-Fi off: the link fields are `null`. `connected: true`
  with `ssid: null` = Location Services missing.
- `quality` 0–100 from RSSI (−90 dBm = 0, −30 dBm = 100).
- `security`: `open`, `wep`, `wpa-personal`, `wpa2-personal`,
  `wpa2-wpa3-personal`, `wpa3-personal`, `owe`, `owe-transition`,
  `*-enterprise`, `unknown`. `can_share`: a QR code can carry it (not 802.1X).

`GET /scan` (active scan, 2–4 s; reuses one younger than 10 s) and
`GET /scan?cached=1` (macOS's scan cache, instant): one entry per SSID, the
current network first, then by RSSI; `known` = saved on the Mac.

`GET /wifi/password[?ssid=]` (default: the current network) →
`{ssid, security, password, hidden, qr}`; `qr` is a ready
`WIFI:T:WPA;S:…;P:…;;` string. Read from the System keychain only on request,
never cached or logged; macOS asks first. `403 denied` when the prompt is
cancelled, `408` without an answer in 60 s, `409` for enterprise networks,
`404` when nothing is saved; open networks return `password: ""`.

### Audio

`GET /audio`: default `output` and `input` (`uid`, `name`, `transport`
built-in/usb/bluetooth/hdmi/…, `volume` 0–1, `muted`, `has_volume`,
`volume_settable`, `has_mute`) and all `devices`. A device without volume
control (HDMI) reports `has_volume: false`, `volume: null`.

```bash
H=(-H "Authorization: Bearer $T" -H 'Content-Type: application/json')
curl "${H[@]}" -d '{"volume": 0.4}'            $B/audio/volume   # or {"delta": 0.05}; raising unmutes
curl "${H[@]}" -d '{"volume": 0.6, "scope": "input"}' $B/audio/volume
curl "${H[@]}" -d '{"muted": "toggle"}'        $B/audio/mute     # true | false | "toggle"
curl "${H[@]}" -d '{"uid": "BuiltInSpeakerDevice"}' $B/audio/output   # /audio/input likewise
```

### Display

`GET /display`:

```json
{"brightness":0.438,
 "night_shift":{"available":true,"enabled":false,"strength":0.883,
                "schedule":{"mode":"sunset-to-sunrise","from":"22:00","to":"07:00"}},
 "true_tone":{"supported":true,"available":true,"enabled":true}}
```

```bash
curl "${H[@]}" -d '{"delta": -0.0625}'         $B/display/brightness   # or {"brightness": 0.5}
curl "${H[@]}" -d '{"enabled": "toggle", "strength": 0.7}' $B/display/night-shift
curl "${H[@]}" -d '{"enabled": false}'         $B/display/true-tone
```

`enabled` is Night Shift's manual switch (tinting now); the schedule stays as
set in macOS.

### External displays

The brightness of the external display a VM is on (feature
`external-brightness`, `external-brightness.swift`): DDC/CI (VCP 0x10) over
IOAVService on Apple Silicon, or DisplayServices for the displays macOS dims
itself (Studio Display, Pro Display XDR, LG UltraFine; this wins over DDC/CI).
Which one works is found per display
when the Bridge starts, after every display change and, for a display where
nothing worked, again a minute later when it is asked (keys, the VM, `omacvm
check`); the built-in display is never set here. With `external_brightness:
false` the Bridge sends no DDC/CI at all, not even reads.

`GET /display/external`: every external display and how its brightness is
set (`ddc`, `apple`, or `none` with the reason), for `omacvm check`:

```json
{"enabled": true, "displays": [{"id": 4, "name": "Pi-X9", "method": "ddc", "brightness": 35},
  {"id": 7, "name": "LG HDR 4K", "method": "none", "brightness": null,
   "reason": "no DDC/CI on this connection (some Macs' HDMI ports have none: try USB-C/DisplayPort)"}]}
```

`GET /display/external-brightness` → `{"brightness": 35, "display": "Pi-X9", "method": "ddc"}`
(0-100, read fresh), and `POST` with `{"brightness": 0-100}` or
`{"delta": -100..100}` sets it. Which display: with `?x=&y=&width=&height=`
(an OmacVM.app output's box from its layout, in points with the layout's
corner at 0,0) the one among the displays showing an OmacVM.app window whose
place matches; without, the display of the VM window in front (under the
pointer when it covers several). Only an external display with a VM window
on it: `404` when there is none, `409` for the built-in display, a display
without DDC/CI or `external_brightness: false`, `503` when it does not answer.
The VM only names its output and a level; it never reaches the I2C bus, and
its writes go out at most every 250 ms (the latest level). A request shows
no popup from here (Omarchy's command shows its own). Off, `GET
/display/external` answers `{"enabled": false, "displays": []}` without
asking any display.

In the VM, `/usr/local/bin/ddcutil` (`guest/omacvm-ddcutil`) answers the three
calls Omarchy's `omarchy-brightness-display-ddc` makes (`detect`, `getvcp 10`,
`setvcp 10 N`; output Virtual-N is "bus" N, maximum 100) through this API, so
Omarchy's brightness keys, `omarchy brightness display` and its monitor panel
work on the output's Mac display. Outside OmacVM.app only the focused output
asks (the Mac goes by the window in front). Everything else goes to the real
`/usr/bin/ddcutil`.

### Bluetooth

`GET /bluetooth`:

```json
{"available":true,"power":true,"permission":"granted","power_settable":true,"forget_supported":true,
 "devices":[{"address":"30:7A:D2:32:1E:AE","name":"AirPods Pro","kind":"headphones","paired":true,
             "connected":true,"battery":{"left":85,"right":90,"case":40}}]}
```

- `kind`: `headphones`, `headset`, `speaker`, `keyboard`, `mouse`,
  `trackpad`, `gamepad`, `phone` or `other` (macOS's own classification).
- `battery` for connected devices that report one: `left`/`right`/`case`
  (AirPods, Beats) or `main`; otherwise `null`.
- `permission`: `granted`, `not-determined` or `denied`. Without it the list
  comes from macOS's system report and the actions answer `403`.

```bash
curl "${H[@]}" -d '{"enabled": "toggle"}'                 $B/bluetooth/power      # true | false | "toggle"
curl "${H[@]}" -d '{"address": "30:7A:D2:32:1E:AE"}'      $B/bluetooth/connect    # also /disconnect, /forget
curl "${H[@]}" -d '{}'                                    $B/bluetooth/settings   # the Mac's Bluetooth settings
```

`connect` waits until the device is connected (`409` when it does not answer,
after about 15 s). Pairing a new device needs macOS's own dialog, so the
panel's "Pair a new device…" opens the Mac's Bluetooth settings.

### Battery

`GET /battery`: the Mac's battery, for UTM and VMware Fusion VMs (their
`omacvm-battery` agent shows it in Omarchy's bar, see `../battery/README.md`;
OmacVM.app passes the same on its own port, Parallels gives the VM its own):

```json
{"type":"state","present":true,"percentage":57,"state":"discharging","acConnected":false,
 "timeToEmptySeconds":8100,"timeToFullSeconds":null,"chargeLimit":80,
 "chargeNowMicroAh":2832900,"chargeFullMicroAh":4970000,"chargeFullDesignMicroAh":6075000,
 "voltageMicroV":12537000,"cycleCount":213}
```

`state`: `charging`, `discharging`, `full`, `not-charging` (on the charger,
held at the limit) or `unknown`. `chargeLimit`: the limit set in macOS
(read from powerd's settings), else `null`. A Mac without a battery:
`present: false`, `percentage: null`, `acConnected: true`. Read-only.

### Events

`GET /events` (Server-Sent Events): on connect the current `wifi`, `audio`,
`display`, `bluetooth` and `battery`; then

| event | when |
|---|---|
| `wifi` | power, SSID, BSSID, link, mode changes (CoreWLAN events, ~0.3 s); RSSI re-read every 5 s while a client is connected, sent at once when the bar's signal level changes, else at most every 30 s |
| `audio` | default device, volume, mute, devices added/removed (CoreAudio listeners) |
| `display` | Night Shift (its own notification), True Tone, brightness |
| `bluetooth` | power, devices connecting and disconnecting (IOBluetooth notifications), anything else within 5 s; battery re-read every minute while something is connected |
| `scan` | an active scan finished, or macOS refreshed its scan cache (≤ every 10 s) |
| `battery` | charge, charging, the charger (IOKit notifications); time left, voltage and charge in µAh alone at most every 30 s |
| `osd` | `{"type":"osd","kind":"volume"\|"mute"\|"brightness"\|"keyboard","value":0-100,"muted":bool,"source":"keys"\|"api"\|"external","device":"…"}` |

`source`: `keys` = a media key caught while the VM was full screen, `api` = a
request from the VM, `external` = anything else (macOS slider, AirPods, keys
outside the VM). Volume and mute changes come as `external` always; brightness
changes made on the Mac only to clients that asked with `GET /events?osd=external`
(the Bridge then reads the brightness every 0.5 s). `: ping` every 15 s; `retry: 3000`.

In the VM, the bar widgets and the OSD follower share one stream:
`omacvm-bridge events` connects to `omacvm-bridge-events` (a user service
started by its socket), which keeps a single `omacvm-bridge events --direct`
to the Mac (the proof and the token as for every request). A new reader
first gets the latest event of each kind, as from the Mac. The Mac stream is
opened with `?osd=external` while a reader asks for it (reopened when that
changes), closed 30 s after
the last reader left, and when it ends or stays silent for 20 s every reader
is closed, so each one sees what it saw before (the stream ends, it reconnects
after 3 s). Without the socket (an older install, the service failing)
`omacvm-bridge events` goes straight to the Mac. Log: `journalctl --user -u
omacvm-bridge-events`.

### Camera

UTM and VMware Fusion VMs get the Mac's camera from the Bridge
(`camera.swift`; OmacVM.app uses the same code over a virtio port). The VM's
`omacvm-camera` (`../camera/guest/`) opens a connection only while a Linux
app reads `/dev/video42`:

1. `GET /camera` with the token, after `/proof`. The Bridge answers `200` and
   the connection is the camera's from then on (`503` with 8 VMs connected).
2. The VM sends one JSON object per line: `{"type":"start"}`, `{"type":"stop"}`.
3. The Bridge sends messages: a 16-byte header (`TOCM`, version 1, kind 1
   status or 2 frame, two zero bytes, payload length and sequence as
   little-endian UInt32) and the payload. Status is JSON:
   `{"status":"idle"}`, `{"status":"streaming","name":"MacBook Pro Camera","width":1280,"height":720,"fps":30,"pixelFormat":"NV12"}`
   or `{"status":"unavailable","reason":"permission"|"no-camera"|"capture"}`.
   A frame is 1280×720 NV12, 1,382,400 bytes.

The camera runs while at least one VM said start and has neither said stop
nor closed the connection. Every VM gets the same frames; one that has not
taken the last frame yet skips the next, so a slow VM holds up nobody. A VM
that stops reading for 2 seconds is dropped. The first `start` ever makes
macOS ask for the camera; until it is answered the VM shows black.
When the camera fails while VMs still want it (another Mac app takes it, the
permission is missing), they get `unavailable` and show black, and the Bridge
tries again after 2 seconds, then up to every 30, until it works (they get
`streaming` again) or no VM wants it.

Both are only for VMs: from 127.0.0.1 or from one of the Mac's own
addresses they answer `403`. The token is a plain file, so otherwise any
program of yours on the Mac could read it and use the camera under the
Bridge's permission, without macOS asking for it. OmacVM.app's VMs use their
virtio port.

`GET /camera/status`: `{"permission": "granted"|"not-determined"|"denied"|"restricted", "camera": "MacBook Pro Camera", "on": false, "readers": 0, "connections": 0}`.

`OMACVM_CAMERA=test` in the Bridge's environment sends a moving test picture
instead of the camera (no permission needed), to check the way into the VM.

### Wallpaper

`POST /wallpaper` with an image body (PNG or JPEG, up to 48 MB, read only after
the token checked out; optional header `X-Omarchy-Theme`): the Mac's wallpaper
on every display and every Space, which macOS also shows behind its own lock
screen. The guest sends it from `omacvm-wallpaper` whenever Omarchy's theme or
background changes (`omacvm-bridge wallpaper <image> [theme]`).

macOS keeps a wallpaper per Space, and its API only sets the Space each screen
shows right now, which is the VM's own Space when the theme changes in full
screen. So the Bridge also writes the picture into every Space in macOS's
wallpaper store (`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`,
macOS 14 and later) and restarts `WallpaperAgent` to apply it, so the desktop
may redraw once.

### The control centre (`/omacvm/`)

For `omacvm` in Omarchy (docs/adr/0031). A fixed list; anything else is 404,
and nothing the VM sends reaches a command line except feature names that are
in the Mac's own `features.tsv`. The VM is never named by the request: the
Bridge finds the one running VM that OmacVM set up at the request's address
(none or two: 409), and every request but `hello` is signed with that VM's
own key, which never leaves the VM (`omacvm apply` makes it):
`X-OmacVM-Auth: 1 <unix time> <nonce, 32 hex> <HMAC-SHA256(key, "omacvm-control-request 1\n" method "\n" path "\n" time "\n" nonce "\n" X-OmacVM-Proto "\n" hex SHA-256 of the body)>`,
good for 5 minutes either way and once per nonce (403 `vm-key`, `clock` with
the Mac's `mac_time`, `replay`; `no-vm-key` when the Mac has none). Nonces
are kept per VM and in `nonces` beside the token (a restart does not forget
them); each VM gets a burst of 60 requests, then 4 a second (429 `rate`, for
that VM only). Answers to
a signed request carry `X-OmacVM-Answer: <HMAC-SHA256(key, "omacvm-control-answer 1\n" nonce "\n" status "\n" hex SHA-256 of the body)>`;
the VM uses no answer without it. Requests carry `X-OmacVM-Proto: 1`; bodies
are strict JSON up to 4 KB, unknown keys refused.

| Request | What it does |
|---|---|
| `GET /omacvm/hello` | `{"proto", "proto_min", "omacvm", "requests", "features", "macos", "chip"}` |
| `GET /omacvm/status` | the Mac's view of this VM: per feature on/available/reason, the Mac-side checks (`omacvm features --json` and `omacvm check --json --mac-only`, cached 30 s) |
| `GET /omacvm/gpu-memory` | an OmacVM.app VM's graphics memory on the Mac, from `logs/gpu-memory` in its folder (QEMU writes it; OmacVM.app sends it with the relayed request as `X-OmacVM-GPU-Memory`, base64 or `-` for none, so the Bridge never reads an external drive; from an older app, the folder from `omacvm vms --json`): `{"measured", "in_use_mb", "peak_mb", "budget_mb", "pressure": "normal"\|"warn"\|"critical"\|"unknown", "refused", "lost"}`, numbers only (no app names, no paths); `measured` false before QEMU's first numbers; 409 `not-app` for other VMs. The control centre asks at most every 2 s while it is open; 200 answers are not logged, and it never starts a new `omacvm vms` run for a VM the list already has |
| `GET /omacvm/updates` | the last update check: `checks_enabled`, `checked_at`, `ok`, `offline`, `error`, the verified manifest |
| `POST /omacvm/updates/check` | fetch and verify the manifest now (once a minute) |
| `POST /omacvm/settings/update-checks` `{"enabled": bool}` | the one switch for update checks and notices |
| `POST /omacvm/jobs` `{"action": "enable"\|"disable"\|"reinstall", "features": [...]}` or `{"action": "update"}` | runs `omacvm enable/disable F... --vm VM --vm-type T --yes --transaction`, `omacvm apply --vm VM --vm-type T --transaction --yes --reinstall F...` or `omacvm update --vm VM --vm-type T --transaction --yes --commit C` (C from the verified manifest); 202 with the job. One per VM at a time, 20 an hour; enable only when the Mac and the VM run the same OmacVM (else 409 `update-first`), disable and reinstall also when the Mac is newer (after an update that went back in the VM), nothing when the VM is newer (409 `mac-older`); update only forward (409 `not-newer`) and, with update checks off, only after a check in the last hour (else 409 `stale-update`) |
| `GET /omacvm/jobs/<id>` | `{"state": "running"\|"done"\|"failed"\|"rolled-back", "step", "of", "text", "failed_part", "failed_side", "mac_omacvm", "lines"}`, this VM's jobs only. The state comes from the exit code (4 = rolled back); step n of m from the CLI's progress lines; `text` of a failed job says what failed (apply's `omacvm_failed` line), `failed_part` the feature, `failed_side` "mac" when a Mac helper did not build |

From 127.0.0.1 (OmacVM.app's guests, or any Mac program) everything but
`hello` is refused, except OmacVM.app relaying a request from a VM's control
port (`org.omacvm.control`): `X-OmacVM-Relay` with the key in
`relay-key` beside the token (no VM gets it) and `X-OmacVM-App-VM` (the VM's
name, base64). The app sends these on the relay socket,
`omacvm-bridge/relay.sock` (mode 0600 in the 0700 folder; the Bridge checks
the peer's user on every connection and serves only `/omacvm/...` there), so
its guests, which share 127.0.0.1, cannot use up the relay's places. When the
app cannot connect to the socket (an older Bridge, the Bridge not running, the
folder not 0700) it relays on 127.0.0.1 instead; once connected, a request is
never sent a second time. A path too long for a Unix socket (over 103 bytes: a
very long home folder) leaves the socket out and says so in the log; the app
then uses 127.0.0.1. A second Bridge on the same Mac (a test Bridge) must set
`OMACVM_BRIDGE_RELAY_SOCKET` to a socket of its own: two Bridges on one path
remove each other's socket every few seconds. Every request goes to the log
with the VM and the answer; refusals (and 401s) once a minute per address, VM
and reason, with the count left out.

Which VM asked comes from `omacvm vms --json`, cached: a request never waits
for it. OmacVM.app's VMs come from a second run, `omacvm vms --json
--app-only`, through the app's own executable (`OmacVM --control-run`, when
the CLI is the app's copy and its Info.plist has `OmacVMControlRun`); so do
the status runs and jobs for an app VM. The Bridge spawns omacvm with its
responsibility disclaimed (Local Network privacy), and macOS refuses such a
program a VMs folder on an external drive without asking (Removable
Volumes): through the app, the run is the app's, with the access the person
gave the app. The app runs only the Bridge's commands, only for OmacVM Bridge
of its own identity and signer (app/app/Sources/OmacVM/ControlRun.swift). It is read again in the background, one run at a time, when the list
is a minute old, after a job, and for an address the list does not have (a
VM that just started) at most once a minute, since any guest can add
addresses. Also when a request does not prove with the key of the VM the
list has at its address (that VM stopped and another took the address): at
most once a minute, when the list is 5 s old or more; the 403 then says
"looking" (`"looking": true`) and the VM asks again instead of telling the
person to run `omacvm apply`.

Connections being handled: every VM the list knows, 127.0.0.1 (this Mac:
its programs and OmacVM.app's guests) and the relay socket each have 4
places of their own; past them it
shares 48 places with the rest, at most 12 in all. Unknown addresses take at
most 16 of the 48 together and 8 each. So a guest that holds all it can (its
own 12 and the 16 unknown places) leaves the other VMs and the relay all
theirs. Long requests (`POST /wallpaper` with its 120 s body,
`GET /wifi/password` waiting on the dialog) at most two at once per VM (429).

### Touch ID (`/omacvm/touchid`, feature `touch-id`)

The VM's sudo and polkit ask the Mac's Touch ID first (ADR 0041; off by
default, `omacvm enable touch-id`). The VM's PAM client
(`guest/omacvm-touchid`, root) posts `{"kind", "user", "detail", "tty", "action"}`
signed with the VM's Touch ID key (`vm-keys/<vm>.touchid` on the Mac,
`/etc/omacvm/touchid-key` in the VM) under the label
`omacvm-touchid-request 1`; the answer, signed back
(`omacvm-touchid-answer 1`), is `{"result": "yes"}` or `{"result": "no",
"reason": ...}`. No key on the Mac: 403 `off`, no dialog. The Bridge asks
macOS with a fresh `LAContext` each time, biometrics only;
`"touch_id_password_fallback": true` in `config.json` also offers the Mac's
password (macOS then also takes an Apple Watch's approval). It says no
without a dialog when the Mac is locked, the VM's app is not in front or
the Mac has no Touch ID; one dialog at a time, per VM one request every
2 s and 10 a minute; after 3 misses (cancelled, failed, not answered) no
for 60 s, then 5 min, then 30 min, until a yes. The log has the VM, the
kind and the result, never the command. In the VM the client asks only
for the person at the VM's screen (logind's display session; sudo from a
terminal of theirs, not over SSH) and only for a sudo command it can show
whole. OmacVM.app's VMs ask through the virtio port `org.omacvm.auth` (only
with `touch-id=on` at the VM's start); the app passes the request on to
the relay socket with the relay key and the VM's name, the guest's
signature along, and the signed answer back unchanged (`AuthRelay`).

For OmacVM.app's VMs the Mac asks in a panel in the VM's Omarchy theme
(from 3.0.2), shown by QEMU, the VM window's own process: macOS reads the
finger only for the app in front. The Bridge decides as always, then sends
the panel's words and the VM's theme to the app in an interim
`103 Touch ID Panel` answer on the relay connection and gets the panel's end
back as one line (`touchIDAskAppPanel`); it signs the final answer.
macOS's dialog stays for Parallels, UTM and Fusion, the password fallback,
`"touch_id_panel": false` in `config.json`, and whenever the panel could not
show. The VM sends its theme with `POST /omacvm/theme` (control key; only
with Touch ID on; `#rrggbb` colours checked for contrast:
`touchid_theme.swift`), kept per VM in `touchid-theme/`. Tests:
`tests/run.sh`; the panel itself: `swift run touchid-panel-tests` in app/app.

### Not built: Wi-Fi control

`POST /power`, `/join`, `/disconnect` answer `501`. Design: CoreWLAN
`setPower`, `associate(to:password:)` (saved networks via the keychain,
`networksetup -setairportnetwork` as fallback), `disassociate()`. The VM's
internet runs over this Wi-Fi, but the VM link is local: switching Wi-Fi
off from the VM keeps the API reachable (tested), so it can switch it back on.

## Media keys

While **a VM is in front** (an OmacVM.app VM, full screen or in a window;
Parallels, UTM or VMware Fusion with the VM covering a whole display), volume
up/down/mute, display brightness and keyboard-light keys are swallowed (no
macOS popup), applied on the Mac in macOS's 1/16 steps (Shift+Option: 1/64),
display brightness in 1/32 steps (see Brightness steps), and shown by Omarchy's
own OSD in the VM. Which key goes where is one tested
rule, `MediaRoute` in `mac/keys-model.swift` (`mac/test-models.sh`):

- volume and mute on an output without a software volume (an audio interface
  such as a Scarlett 2i2: `outputVolumeSettable` false) go into an OmacVM.app
  VM as its own keys (XF86AudioRaiseVolume & co.: the VM's volume with
  Omarchy's popup), never to macOS's greyed-out panel;
- play/pause, next and previous (also an Apple keyboard's track keys) go into
  an OmacVM.app VM (XF86AudioPlay & co.: Omarchy's playerctl), not to macOS's
  Now Playing;
- keys go into the VM through QEMU's control socket (QMP `input-send-event`,
  `mac/vm-keys.swift`): the socket on the VM's QEMU command line, this user's
  own. A busy socket (OmacVM.app holds it while the Mac sleeps), a paused VM or
  a refusal hands the key back to macOS. `mac/test-vm-keys.sh` types every key
  into a real, headless QEMU;
- a key the Bridge cannot use goes to macOS, and the log says once why
  (`media key ...: to macOS: ...`).

The tap sits at the HID level (`.cghidEventTap`): on macOS 27 the volume keys
reach no session-level tap. The brightness keys reach no tap at all there,
so the Bridge also reads them from the keyboard (`mac/hid-keys.swift`,
IOHIDManager, never seized: macOS still gets every key; Input Monitoring).
Apple keyboards send F1/F2; the keyboard's own `FnFunctionUsageMap`
(IORegistry) and macOS's "standard function keys" setting say when they
are brightness; an Apple keyboard without that map (a Bluetooth Magic
Keyboard: vendor 0x004C; USB: 0x05AC) gets Apple's usual F1 down, F2 up.
Other keyboards' consumer-page brightness keys count too.
They act only while an OmacVM.app VM is in front, by the same rule; a press
that also came through the tap acts once, and a display macOS already
changed itself is not stepped again (unless the Bridge stepped it itself
meanwhile: quick presses each step). HID sends no key repeat, so a held key
repeats at macOS's key repeat speed until it is released. Tests: `mac/test-models.sh`,
`mac/test-hid.sh` (made-up keyboards, and this Mac's own maps read only).

Anything else, or any key while no VM is in front, passes through untouched.
Switch it off in the menu-bar icon or with `"capture_keys": false`.

With the VM in front on an external display, the display brightness keys
set that display instead (see External displays): OmacVM.app's VMs also in a
window, Parallels, UTM and Fusion in full screen; 32 steps (Option: 64, see
Brightness steps), read from the display first, writes at most every 50 ms
(the latest level; a jump of more than two steps ramps there), never waiting
in the key path; Omarchy's popup shows the level (not the
display's name). A Mac mini
whose only display macOS dims itself (LG UltraFine, Studio Display) has it set
also while the display is not looked at yet (the Bridge's own DisplayServices
call). A display without DDC/CI keeps the keys as before (the Mac's built-in
display, in full screen), and the log says once why. `"external_brightness": false` in `config.json` switches it off.

### Brightness steps

The display brightness keys step 1/32 by default, half of macOS's 1/16:
the built-in display, Apple displays (DisplayServices) and DDC/CI monitors
alike, while a VM is in front. Option (or Shift+Option) steps 1/64, macOS's
quarter step. One setting: `"brightness_steps": 32` in `config.json` (8 to
100; Option then gives twice that, at least 64, at most 100), read again
within 2 s, no restart. `BrightnessStep` in `mac/external-model.swift`.
On a DDC/CI monitor every press moves its raw value (a monitor with a
coarse range steps on until it does), and a jump of more than two steps
(presses that piled up while the monitor was busy, a held key) goes out as
a ramp: one write per 50 ms gap, at most two steps each, the latest level
winning (`Ramp`). Writes the VM asks for are not ramped (one per 250 ms).
Omarchy's popup shows each level (3-4 points apart). Volume and the keyboard
light keep macOS's 1/16. Omarchy's own `+5%` inside the VM is unchanged: the
Mac's keys never reach the VM.

The keyboard light has four more steps below macOS's lowest (1/16): 0.001,
0.01, 0.02 and 0.04 (`KeyboardSteps` in `mac/keylight.swift`). Measured on a
MacBook Pro M4 Max (macOS 15.7.4): each value is kept, and the backlight
reports its own level for each (`backlightLevelForKeyboard`: 0.115, 0.25,
0.39 and 0.68 against 1.01 at 1/16). Any value above 0 gives at least 0.10,
so 0.001 is about as dim as the keys go while lit. A step the backlight
reports as dark (another Mac's keyboard may not go that low) is skipped, so
a key press never ends on "on but dark". Whether the keys flicker that low
has not been seen yet (only a person can): if they do,
`"keyboard_low_steps": false` in `config.json` and a restart of the Bridge
bring back macOS's steps. `src/tests/keyboard-light.sh` tests the steps
(`--live`: on this Mac's keyboard, then back to the level from before).

macOS 15 has no public way to show its own volume popup on demand, so the VM
draws it.

## Tested

macOS 15.7.4, Parallels 27.0.2: Wi-Fi off/on (the event stream stayed up,
`power:false` after 1 s, reconnected ~7 s after power on, API reachable
throughout), media keys in full screen (exact 1/16 steps, no macOS popup),
external volume/brightness changes as `external` OSD events, Night Shift and
True Tone switched from the VM.
