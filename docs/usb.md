# USB devices in OmacVM.app (experimental, off by default)

A VM can have a USB device of the Mac, but only one that macOS doesn't use
itself. That is a macOS rule, not an OmacVM one. This page says how it works,
which devices work and which don't, and why.

## Turn it on

In the app's VM window, switch **USB devices (experimental)** on, then start
the VM. Nothing connects by itself.

While the VM runs, plug in a device. OmacVM asks:

> **Connect “ST-Link V2” to Omarchy or keep it on the Mac?**
> [Connect to Omarchy] [Keep on Mac] ☐ Always do this for this device

- Your answer is for this plug-in only. Unplug the device, or stop the VM,
  and it asks again next time.
- Check **Always do this for this device** to keep the answer. The device
  then shows in the list, and OmacVM no longer asks about it.
- The question waits until the VM is in front. With two devices it asks
  about one, then the other. Unplug a device while it asks and the question
  goes away.
- Return answers Connect, Escape answers Keep on Mac. For half a second
  after it comes up, neither works, so a Return typed into the VM can't
  answer it.
- Devices macOS uses (keyboards, mice, security keys, disks, audio,
  cameras, serial adapters, iPhones, hubs) are never asked about.

## The list

**Devices…** next to the switch opens it.

- **Remembered**: each device you checked "Always" for, with what happens
  when it's plugged in: **Ask Each Time**, **Connect to Omarchy** or **Keep
  on Mac**. Change it there; it applies the next time the device is plugged
  in. The **−** button (or right-click › Forget Device) forgets a device: it
  is asked about again.
- **Plugged in now**: devices the VM could have that aren't remembered yet.
  Picking a choice there remembers them.
- **Kept by macOS**: the devices macOS uses, and why.

Two identical boards with serial numbers each get their own entry. A device
without a serial number has one entry for all of them.

## While the VM runs

- A device you connect belongs to the VM until you unplug it or the VM stops.
  Then the Mac has it again. A restart inside Linux keeps it connected.
- If Linux resets the device (firmware tools and DFU do), macOS sees it go and
  come back. OmacVM waits 4 seconds before it counts it as unplugged, so the
  VM keeps it.
- Up to four devices at a time.
- If a Mac app has the device open, it stays on the Mac and OmacVM says so.
  Quit the app, then unplug the device and plug it in again.

## Files and logs

- `usb-enabled` in the VM's folder is the switch (`on` or `off`). `usb.json`
  holds the remembered devices (yours only, 0600). An answer for one plug-in
  is never written down.
- From 3.0.1 to 3.0.3 a device switched on in the window went to the VM by
  itself. 3.0.4 keeps that: those devices become **Connect to Omarchy** in
  the list, the switch stays on, and the old `usb` file is renamed
  `usb.before-3.0.4`. Set them to Ask Each Time or forget them in the list.
- `logs/qemu.log` says what happened: `OmacVM: USB devices: on (asks;
  remembered: ...)` at the start, then a line per device (`OmacVM: USB:
  0483:3748 ST-Link V2 connected (asked, this time)`, `... disconnected
  (unplugged)`, `... not connected: in use on the Mac`). `omacvm check` shows
  the devices the VM has now.

In the VM, `lsusb` (`sudo pacman -S usbutils`) lists the device. Linux needs
its driver as usual (most are in Arch's kernel; some tools want a udev rule
for your user).

## What works and what does not

| Device | In the VM? | Why |
|---|---|---|
| Debug probes with only a debug part: ST-Link V2 (`0483:3748`), J-Link without its serial port, CMSIS-DAP v2 probes without a serial port | yes | No macOS driver uses them |
| Debug probes with a serial port or a drive: Black Magic Probe, Raspberry Pi Debug Probe, DAPLink, ST-Link V2-1 and V3 (Nucleo, Discovery boards) | no | macOS's serial (and storage) driver has those parts, so the whole device stays with the Mac |
| SDR sticks (RTL-SDR, HackRF, Airspy), logic analysers (Saleae, fx2lafw) | yes | No macOS driver |
| Phones in fastboot or ADB-only mode, boards in DFU mode | yes | No macOS driver. A board that switches to DFU mode often gets another product id there: OmacVM asks about it again in that mode (check "Always" for both) |
| USB Wi-Fi sticks with no Mac driver | yes | No macOS driver (Linux needs one) |
| Security keys (YubiKey, SoloKey, Titan) | no | macOS's HID driver has them |
| Keyboards, mice, game controllers | no | macOS's HID driver has them |
| USB sticks and disks | no | macOS's storage driver has them (and mounts them) |
| Serial adapters (FTDI, CP210x, CH340, PL2303, Arduino, ESP32) | no | macOS has its own drivers for them |
| Audio interfaces, webcams, iPhones | no | macOS uses them |

A device with several parts (say a board with a debug part and a serial port)
works only if macOS uses none of its parts.

### Why macOS keeps those devices

QEMU takes a device through libusb. On macOS, libusb can only use a part of
a device that no macOS driver or app has open. Taking a part away from
macOS needs Apple's `com.apple.vm.device-access` entitlement (or running
QEMU as root, which OmacVM never does). Apple gives that entitlement to a
developer team on request; UTM, VMware Fusion and Parallels have it.
OmacVM does not have it yet. With it, the list could offer security keys,
disks and serial adapters too.

Until then, other ways work for some of these:

- **Files on a USB disk:** copy them through a shared folder, or `scp` from
  the Mac.
- **Serial adapters:** use the port on the Mac (`screen /dev/cu.usbserial-*`),
  or a network bridge such as `ser2net` on the Mac.
- **Security keys:** use them in a browser on the Mac for now.

### Safety

- With the switch off, QEMU gets no USB controller and never uses USB.
- With it on, the VM gets an empty USB controller. QEMU opens a device only
  when you connect it, and only that one: by its bus and address. It never
  looks for other devices itself.
- A device you connect belongs to the VM while it has it: Linux can do
  anything with it, firmware updates included. Connect only devices you
  would plug into that Linux machine.
- The app reads macOS's device list to see what is plugged in; it opens no
  device itself.
- Only a device nothing on the Mac uses can be connected.
- If macOS or a Mac app has a device, QEMU leaves it alone: no reset (on
  macOS a reset reconnects the device, which would pull a mounted disk)
  (patch `qemu-usb-host-busy-device.patch`).
- On macOS a reset reconnects a device. QEMU resets only a device it really
  has: when Linux asks (DFU and firmware tools need that), and when the VM
  stops.

## How it was tested

- `swift run usb-tests` (in `app/app`, CI): which devices are free, taken from
  the IORegistry of a Mac mini (audio interface, iPhone, webcams, hubs,
  USB-C info device) plus security key, USB stick, serial adapter and debug
  probe examples; the remembered devices and their file, the move from the
  3.0.1-3.0.3 file; the question's words; QMP's commands; and the whole
  plug-in flow on stand-ins for the devices, the VM and the question: ask,
  connect, remember, unplug, reconnect within the grace time, VM stop, busy,
  the four-device limit, two devices at once, the VM not in front.
- `swift run usb-tests --qmp QEMU` runs the QMP part against a real QEMU
  (OmacVM's runtime, no VM disk, CPUs stopped): the start's controller, a
  device that isn't there refused at once, and add, check and remove with
  QEMU's emulated tablet in place of a Mac device (2026-10-07, 3.0.3
  runtime: all pass).
- `swift run usb-tests --list` prints this Mac's devices and what the app
  would offer. Reads the IORegistry only.
- On a Mac mini M4 (macOS 27) with the patched QEMU, 2026-10-06:
  `usb-tests --list` put all 16 devices right (10 hubs not offered; iPhone,
  two webcams, two audio devices, the display's HID controls kept by macOS).
  QEMU with a device macOS uses: one line `usb-host: 043e:9a4d (bus 32,
  addr 9) is in use on the host: not taken`, and its IORegistry id stayed the
  same (no re-enumeration).
- Not tested yet: a real free device end to end, and the question over a
  full-screen VM on a Mac (none of the test Macs has a free device plugged in).

## Known limits

- The question is the app's own alert, floating over the VM's window (also
  in full screen). While the VM runs, the list opens only from the window
  before the start; a "USB Devices…" item in the VM's menu comes with a later
  runtime.
- A device that is connected stays connected when you change its choice in
  the list: the choice is for the next plug-in.
- A device that gets another product id when it resets (DFU mode) is a new
  device: OmacVM asks again.
