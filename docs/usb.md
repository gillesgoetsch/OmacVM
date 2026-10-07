# USB devices in OmacVM.app (experimental, off by default)

A VM can have a USB device of the Mac, but only one that macOS does not use
itself. That is a macOS rule, not an OmacVM one. This page says which devices
work, which do not and why, and how to turn it on.

## Turn it on

In the app's VM window: switch **USB devices (experimental)** on, then
**Devices…**. Each device you can give to the VM has a switch there; the
devices macOS keeps are named below the list (point at it to see why).
Switch a device on, then start the VM.

- Per VM. Off by default: switched off, or with no device on, the VM has no
  USB controller at all, exactly as before. Switching it off keeps the
  devices for the next time.
- The device goes to the VM whenever it is plugged in while the VM runs (also
  after the start), and back to the Mac when the VM stops.
- Up to four devices per VM.
- The choice is the file `usb` in the VM's folder, one device a line
  (`0483:3748 STM32 STLink`); the switch is the file `usb-enabled` (`on` or
  `off`). A VM with devices chosen before the switch came counts as on.
- `omacvm check` on the Mac shows which devices this start passed. QEMU's log
  (`logs/qemu.log`) has the line `OmacVM: USB devices: ...`, and
  `usb-host: VVVV:PPPP ... is in use on the host: not taken` when macOS had a
  chosen device, `usb-host: VVVV:PPPP ... taken` when QEMU took it.

In the VM, `lsusb` (`sudo pacman -S usbutils`) lists the device. Linux needs
its driver as usual (most are in Arch's kernel; some tools want a udev rule
for your user).

## What works and what does not

| Device | In the VM? | Why |
|---|---|---|
| Debug probes with only a debug part: ST-Link V2 (`0483:3748`), J-Link without its serial port, CMSIS-DAP v2 probes without a serial port | yes | No macOS driver uses them |
| Debug probes with a serial port or a drive: Black Magic Probe, Raspberry Pi Debug Probe, DAPLink, ST-Link V2-1 and V3 (Nucleo, Discovery boards) | no | macOS's serial (and storage) driver has those parts, so the whole device stays with the Mac |
| SDR sticks (RTL-SDR, HackRF, Airspy), logic analysers (Saleae, fx2lafw) | yes | No macOS driver |
| Phones in fastboot or ADB-only mode, boards in DFU mode | yes | No macOS driver. A board that switches to DFU mode often gets another product id there: switch both on |
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

- With no device on, QEMU gets no USB controller and never uses USB.
- A device you switch on belongs to the VM while it runs: Linux can do
  anything with it, firmware updates included. Give a VM only devices you
  would plug into that Linux machine.
- The app lists devices by reading macOS's device list only; it opens no
  device.
- Only a device nothing on the Mac uses can be switched on.
- If macOS takes a chosen device later (a driver loads), QEMU leaves it alone:
  it does not reset it (on macOS a reset reconnects the device, which would
  pull a mounted disk) and logs `is in use on the host: not taken` once
  (patch `qemu-usb-host-busy-device.patch`).
- On macOS a reset reconnects a device. QEMU resets only a device it really
  has (the VM uses it): when Linux asks (DFU and firmware tools need that),
  and when the VM stops. A device macOS holds as a whole is never reset.

## How it was tested

- `swift run usb-tests` (in `app/app`, CI): which devices are free, taken from
  the IORegistry of a Mac mini (audio interface, iPhone, webcams, hubs,
  USB-C info device) plus security key, USB stick, serial adapter and debug
  probe examples; the VM's file; QEMU's arguments.
- `swift run usb-tests --list` prints this Mac's devices and what the app
  would offer. Reads the IORegistry only.
- On a Mac mini M4 (macOS 27) with the patched QEMU, 2026-10-06:
  `usb-tests --list` put all 16 devices right (10 hubs not offered; iPhone,
  two webcams, two audio devices, the display's HID controls kept by macOS).
  QEMU with the display's webcam chosen (macOS uses it): one line
  `usb-host: 043e:9a4d (bus 32, addr 9) is in use on the host: not taken`
  over six scans, and its IORegistry id stayed the same (no re-enumeration).
  A VM (Linux 7.2.8) with that webcam and an absent device chosen booted, its
  xHCI controller came up (USB 2 and USB 3 bus), no device attached.
- Not tested yet: a real free device end to end (none is plugged into the
  test Mac).

## Known limits

- Devices are matched by vendor and product: with two identical devices the
  VM gets the first one QEMU finds.
- A VM that is running does not get a device switched on meanwhile; that
  applies on its next start.
- A chosen device that macOS (or a Mac app) used when the VM looked for it
  stays with the Mac until it is unplugged and plugged in again (QEMU tries
  three times per plug).
