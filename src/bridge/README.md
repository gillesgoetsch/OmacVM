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
| Config | `~/Library/Application Support/omacvm-bridge/config.json`: `capture_keys`, `menu_bar_icon`, `keyboard_low_steps` |
| VM client | `guest/omacvm-bridge` (bash + curl; the token never shows in `ps`, and goes only to a Bridge that proved it knows it, see API) |
| VM popups | `guest/omacvm-bridge-osd`, user service: the Mac's volume/brightness changes as Omarchy's own OSD |
| Shared event stream | `guest/omacvm-bridge-events`, user socket `omacvm-bridge-events.socket` (`$XDG_RUNTIME_DIR/omacvm-bridge-events.sock`): one `/events` connection to the Mac per VM; `omacvm-bridge events` reads from it, so the widgets and the OSD keep their interface (see Events) |
| Night light | `guest/omarchy-toggle-nightlight` in `/usr/local/bin`, ahead of Omarchy's: Super+Ctrl+N and the menu switch the Mac's Night Shift |
| Bar widgets | `plugins/omacvm.bluetooth`, `plugins/omacvm.wifi`, `plugins/omacvm.audio` (clones of Omarchy's Bluetooth, network and audio widgets; Super+Ctrl+B opens the Bluetooth one), `plugins/omacvm.nightshift` |

Only Apple frameworks: CoreWLAN, CoreLocation, CoreAudio, IOBluetooth,
CoreBluetooth (the permission), IOKit (the battery), AVFoundation (the camera), AppKit, Security, and the private
DisplayServices and CoreBrightness (brightness, Night Shift, True Tone,
keyboard light). Bluetooth power and forgetting a device use IOBluetooth's
private `IOBluetoothPreferenceSetControllerPowerState` and
`-[IOBluetoothDevice remove]` (as `blueutil` does), looked up at run time.

## Permissions

| Permission | For | Grant / revoke |
|---|---|---|
| Location Services | macOS only shows Wi-Fi names to apps with it; no location is read | prompt on first start; System Settings › Privacy & Security › Location Services |
| Accessibility | the event tap that takes the media keys while the VM is full screen | prompt on first start; Privacy & Security › Accessibility, or `tccutil reset Accessibility org.omacvm.bridge` |
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

### Not built: Wi-Fi control

`POST /power`, `/join`, `/disconnect` answer `501`. Design: CoreWLAN
`setPower`, `associate(to:password:)` (saved networks via the keychain,
`networksetup -setairportnetwork` as fallback), `disassociate()`. The VM's
internet runs over this Wi-Fi, but the VM link is local: switching Wi-Fi
off from the VM keeps the API reachable (tested), so it can switch it back on.

## Media keys

While **Parallels, UTM or VMware Fusion is frontmost with the VM covering a whole display**, volume
up/down/mute, display brightness and keyboard-light keys are swallowed (no
macOS popup), applied on the Mac in macOS's 1/16 steps (Shift+Option: 1/64),
and shown by Omarchy's own OSD in the VM. Anything else, or any key while the
VM is not full screen, passes through untouched. Switch it off in the
menu-bar icon or with `"capture_keys": false`.

The keyboard light has three more steps below macOS's lowest (1/16): 0.01,
0.02 and 0.04. Measured on a MacBook Pro M4 Max (macOS 15.7.4): each value is
kept, and the backlight reports its own level for each
(`backlightLevelForKeyboard`: 0.25, 0.39 and 0.68 against 1.01 at 1/16), so
they are on by default. Whether the keys flicker that low has not been seen
yet (only a person can): if they do, `"keyboard_low_steps": false` in
`config.json` and a restart of the Bridge bring back macOS's steps. macOS 15 has no public way to
show its own volume popup on demand, so the VM draws it.

## Tested

macOS 15.7.4, Parallels 27.0.2: Wi-Fi off/on (the event stream stayed up,
`power:false` after 1 s, reconnected ~7 s after power on, API reachable
throughout), media keys in full screen (exact 1/16 steps, no macOS popup),
external volume/brightness changes as `external` OSD events, Night Shift and
True Tone switched from the VM.
