# The Mac's battery

On a MacBook, Omarchy's bar shows the Mac's battery as it would on a laptop:
charge, charging or not, and its battery panel (size, cycles, the charge
limit set in macOS). Time left and Omarchy's low-battery warning should work
the same way but are not tested yet with the Mac on battery (see Tested). The
VM never suspends or powers off for a low battery, the Mac decides that.

Feature `battery`: on by default on a Mac with a battery.

From try-omarchy (github.com/omacom/try-omarchy, MIT; the module
GPL-2.0-only): the kernel module, the agent and the Mac's snapshots.

## How it works

```
Mac                                              VM
IOKit power sources ─── OmacVM.app ── virtio port org.omacvm.battery ───────────────────┐
                                                                                        ▼
                                  omacvm-battery.service (root) ── /sys/devices/platform/omacvm-battery/state
                                                                                        ▼
                                  module omacvm_battery: /sys/class/power_supply/BAT0, ADP0
                                                                                        ▼
                                  UPower ── Omarchy's bar (battery icon, panel, low-battery warning)
```

- The Mac sends a whole snapshot each time (JSON, see `app/app/Sources/OmacVM/HostBattery.swift`):
  on every change of its power sources (IOKit notifications), and every
  30 seconds from OmacVM.app. Only the VM's request for a fresh one goes the
  other way; nothing in the VM can change the Mac.
- `omacvm-battery` (Python) writes it as one line to the module's `state`
  file (root only): `present=1 status=discharging capacity=57 ac=0
  time_to_empty=8100 … current_now=-573000 power_now=7042170`, or
  `present=0 ac=1` on a Mac without a battery. A line is taken whole or not
  at all, so `current_now`/`power_now` go only to module 1.1.0 or newer
  (`/sys/module/omacvm_battery/version`); a 1.0.0 module would refuse the
  whole line. When the Mac's side goes away, the
  agent marks the battery's state unknown and systemd starts it again.
- The module (`module/`, DKMS `omacvm-battery/1.1.0`) shows BAT0 (a Li-ion
  battery, "Apple Mac Battery") and ADP0 (the charger). BAT0 appears with
  the first snapshot that has a battery.
- Watts and time left: the Mac sends the battery's current (AppleSmartBattery's
  `Amperage`, mA, below 0 while discharging) and power (current x voltage).
  The module shows them as `current_now` (µA, below 0 only while
  discharging) and `power_now` (µW). UPower takes its rate from
  `current_now` and works out time left from it. Without them (module or
  Mac side before 3.0.6) UPower guesses a rate from charge steps 15-120 s
  apart: a few watts to hundreds, or 0 with no time left.
- No charge limit in macOS: `charge_control_end_threshold` says 100.
  UPower 1.91 still shows its own default (75-80 %) as the threshold there.
- `/etc/UPower/UPower.conf.d/90-omacvm-battery.conf`: `CriticalPowerAction=Ignore`
  (UPower takes it only with `AllowRiskyCriticalPowerAction=true`).

## Kernel updates

`guest/install.sh on` installs `dkms` and the headers of the installed kernel
(`linux-aarch64-headers` of the same version; the memory-optimized kernel
brings its own) and builds the module for every kernel that has headers. A
kernel update through `omarchy update` brings new headers with it, and
pacman's DKMS hook builds the module for the new kernel before the reboot.
`omacvm check` lists every kernel and whether it has the module.

## Files in the VM

| What | Where |
|---|---|
| module source | `/usr/src/omacvm-battery-1.1.0/` (DKMS), built into `/usr/lib/modules/<kernel>/updates/dkms/` |
| loaded at boot | `/etc/modules-load.d/omacvm-battery.conf` |
| agent | `/usr/local/bin/omacvm-battery`, `omacvm-battery.service` |
| app port | `/dev/virtio-ports/org.omacvm.battery` (root only, `70-omacvm-battery.rules`) |
| build log | `/var/lib/omacvm/battery-build.log` |

```bash
upower -i /org/freedesktop/UPower/devices/battery_BAT0
cat /sys/devices/platform/omacvm-battery/state
journalctl -u omacvm-battery
```

## Tests

`src/tests/battery.sh` (offline, CI): both Mac snapshots from ioreg-like
readings (signed current, also as ioreg's unsigned wrap), the agent's line
per module version, the module on a stand-in for the kernel, and the three
in a row. `--live` also prints this Mac's snapshot.

## Tested

MacBook Pro M4 Max, macOS 15.7.4, Arch Linux ARM's kernel 7.2.8, upower
1.91.4, dkms 3.4.3: an OmacVM.app VM (and a retired UTM 5 VM through the Bridge)
(virtio port) show the Mac's battery (100 %, on the charger, full) in UPower and in
Omarchy's bar; `omacvm check` passes the battery rows; `omacvm disable
battery` removes module, agent and DKMS entry, `enable` brings them back;
reinstalling the kernel headers makes pacman's DKMS hook rebuild the module.
Not tested yet: the Mac on
battery power (discharging, time left, the low-battery warning).
