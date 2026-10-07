// The VM's USB devices (OmacVMUSB), without a VM or Xcode:
//   cd app/app && swift run usb-tests          the checks; exit 0 when all pass
//   cd app/app && swift run usb-tests --list   this Mac's devices and what a VM may have
// CI runs the checks on every pull request. --list only reads the IORegistry.
import Foundation
import OmacVMUSB

if CommandLine.arguments.contains("--list") {
    for d in USBScan.devices() {
        let a: String
        switch d.availability {
        case .free: a = "free: a VM can have it"
        case .usedByMac(let why): a = why
        case .notOffered(let why): a = "not offered: \(why)"
        }
        let ifs = d.interfaces.map { "\($0.number):\(String(format: "%02x", $0.interfaceClass))\($0.users.isEmpty ? "" : "[\($0.users.joined(separator: ","))]")" }
        print("\(d.id) \(d.name) (class \(String(format: "%02x", d.deviceClass))) -> \(a)")
        print("    interfaces \(ifs.joined(separator: " "))\(d.drivers.isEmpty ? "" : "; device drivers \(d.drivers.joined(separator: ","))")")
    }
    exit(0)
}

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

typealias I = USBDevice.Interface
func dev(_ v: UInt16, _ p: UInt16, _ name: String, cls: Int = 0, drivers: [String] = [], _ ifs: [I]) -> USBDevice {
    USBDevice(id: USBDeviceID(vendor: v, product: p), name: name, deviceClass: cls, drivers: drivers, interfaces: ifs)
}

// Devices as the IORegistry showed them on the Mac mini (2026-10-06).
let scarlett = dev(0x1235, 0x8219, "Scarlett 2i2 4th Gen", cls: 0xef, [
    I(number: 0, interfaceClass: 1, users: ["AppleUSBAudioControlNub", "usbaudiod"]),
    I(number: 1, interfaceClass: 1, users: ["usbaudiod"]),
    I(number: 2, interfaceClass: 1, users: ["usbaudiod"]),
    I(number: 3, interfaceClass: 0xfe, users: []),
])
expect(scarlett.availability == .usedByMac("macOS uses it for sound"),
       "an audio interface stays with the Mac, also when one interface is free")
let iphone = dev(0x05ac, 0x12a8, "iPhone", drivers: ["AppleUSBHostiOSDevice"], [
    I(number: 0, interfaceClass: 6, users: ["ptpcamerad"]),
    I(number: 1, interfaceClass: 0xff, users: ["usbmuxd"]),
])
expect(iphone.availability == .usedByMac("macOS uses it (iPhone, iPad or photo import)"), "an iPhone stays with the Mac")
let cam = dev(0x03e7, 0xf63d, "Opal C1", cls: 0xef, [
    I(number: 0, interfaceClass: 0xff, users: []),
    I(number: 1, interfaceClass: 0x0e, users: ["UVCAssistant"]),
])
expect(cam.availability == .usedByMac("macOS uses it as a camera"), "a webcam stays with the Mac")
let hub = dev(0x05e3, 0x0610, "USB2.0 Hub", cls: 9, [I(number: 0, interfaceClass: 9, users: [])])
expect(hub.availability == .notOffered("a USB hub"), "a hub is never offered")
let billboard = dev(0x0b05, 0x1c55, "DMC Device", [
    I(number: 0, interfaceClass: 0x11, users: ["AppleUSBHostBillboardDevice"]),
    I(number: 1, interfaceClass: 0xff, users: []),
])
expect(billboard.availability == .notOffered("a USB-C adapter's info device"),
       "a USB-C billboard is never offered, also with a vendor interface next to it")
let billboardOnly = dev(0x0b05, 0x1c56, "Adapter", [I(number: 0, interfaceClass: 0x11, users: [])])
expect(billboardOnly.availability == .notOffered("a USB-C adapter's info device"), "a billboard-only device is never offered")

// What a VM can have: nothing on the Mac uses any interface.
let stlink = dev(0x0483, 0x3748, "STM32 STLink", [I(number: 0, interfaceClass: 0xff, users: [])])
expect(stlink.availability == .free, "a debug probe without a macOS driver is free")
let unconfigured = dev(0x0bda, 0x2838, "RTL2838UHIDIR", cls: 0, [])
expect(unconfigured.availability == .free, "a device macOS did not set up (no interfaces, no driver) is free")
let key = dev(0x1050, 0x0407, "YubiKey OTP+FIDO+CCID", [
    I(number: 0, interfaceClass: 3, users: ["AppleUserUSBHostHIDDevice"]),
    I(number: 1, interfaceClass: 3, users: ["AppleUserUSBHostHIDDevice"]),
    I(number: 2, interfaceClass: 0x0b, users: []),
])
expect(key.availability == .usedByMac("macOS uses it as a keyboard, mouse or security key"), "a security key stays with the Mac")
let stick = dev(0x0781, 0x5581, "Ultra", [I(number: 0, interfaceClass: 8, users: ["IOUSBMassStorageInterfaceNub"])])
expect(stick.availability == .usedByMac("macOS uses it as a disk"), "a USB stick stays with the Mac")
let ftdi = dev(0x0403, 0x6001, "FT232R USB UART", [I(number: 0, interfaceClass: 0xff, users: ["AppleUSBFTDI"])])
expect(ftdi.availability == .usedByMac("macOS uses it as a serial port"), "an FTDI serial adapter stays with the Mac")
let driverOnDevice = dev(0x1234, 0x5678, "Thing", drivers: ["SomeVendorDriver"], [I(number: 0, interfaceClass: 0xff, users: [])])
expect(driverOnDevice.availability == .usedByMac("in use on the Mac (SomeVendorDriver)"), "a driver on the device itself counts")
expect(USBDevice.ignoredDeviceChild(className: "AppleUSBHostCompositeDevice")
       && USBDevice.ignoredDeviceChild(className: "AppleUSBHostDeviceUserClient")
       && !USBDevice.ignoredDeviceChild(className: "AppleUSBHostiOSDevice"),
       "the composite driver and apps that only look (WebUSB) do not count; other device drivers do")

// The VM's file.
expect(USBDeviceID(text: "0483:3748") == USBDeviceID(vendor: 0x0483, product: 0x3748), "an id from text")
expect(USBDeviceID(text: "483:3748") == nil && USBDeviceID(text: "zzzz:3748") == nil && USBDeviceID(text: "0483") == nil,
       "a wrong id is no id")
let parsed = USBChoice.parse("# comment\n0483:3748 ST-Link V2\nnonsense\n0483:3748 again\n1d50:6089\n")
expect(parsed == [.init(id: USBDeviceID(vendor: 0x0483, product: 0x3748), name: "ST-Link V2"),
                  .init(id: USBDeviceID(vendor: 0x1d50, product: 0x6089), name: "")],
       "parse: comments and nonsense skipped, a device once")
expect(USBChoice.parse("0483:3748\tST-Link V2\n") == [.init(id: USBDeviceID(vendor: 0x0483, product: 0x3748), name: "ST-Link V2")],
       "parse: a tab parts the id from the name")
let many = (1...6).map { "00\(String(format: "%02x", $0)):0001" }.joined(separator: "\n")
expect(USBChoice.parse(many).count == USBChoice.maxDevices, "at most \(USBChoice.maxDevices) devices")
expect(USBChoice.parse(USBChoice.format(parsed)) == parsed, "format and parse agree")
expect(USBChoice.format([.init(id: USBDeviceID(vendor: 1, product: 2), name: "a\nb\u{7}c")]) == "0001:0002 abc\n",
       "a name is one printable line")

// QEMU's arguments.
expect(USBChoice.arguments([]).isEmpty, "no device: no controller, the VM is as before")
expect(USBChoice.arguments(parsed) == [
    "-device", "qemu-xhci,id=usb0",
    "-device", "usb-host,bus=usb0.0,vendorid=0x0483,productid=0x3748,id=usbhost0",
    "-device", "usb-host,bus=usb0.0,vendorid=0x1d50,productid=0x6089,id=usbhost1",
], "one xHCI controller, a usb-host per device, matched by vendor and product, guest resets allowed (DFU)")
expect(USBChoice.record([]) == "off" && USBChoice.record(parsed) == "0483:3748 ST-Link V2, 1d50:6089", "the qemu.log record")

// The file in a VM folder: no device removes it.
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("usb-tests-\(getpid())")
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
expect(USBChoice.load(folder: folder).isEmpty, "no file: off")
try? USBChoice.save(parsed, folder: folder)
expect(USBChoice.load(folder: folder) == parsed, "saved and loaded")
try? USBChoice.save([], folder: folder)
expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("usb").path), "no device: the file is gone")
// The switch: off by default; a VM from before it keeps its devices.
expect(!USBSwitch.isOn(fileText: nil, chosen: []), "no switch file, no device: off")
expect(USBSwitch.isOn(fileText: nil, chosen: parsed), "no switch file, devices chosen (an older VM): on")
expect(!USBSwitch.isOn(fileText: "off\n", chosen: parsed) && USBSwitch.isOn(fileText: "on\n", chosen: []), "the switch file decides")
expect(!USBSwitch.isOn(fileText: "yes", chosen: parsed), "anything but on: off")
try? USBChoice.save(parsed, folder: folder)
try? USBSwitch.set(false, folder: folder)
expect(USBSwitch.devices(folder: folder).isEmpty && USBChoice.load(folder: folder) == parsed, "off: no device for QEMU, the choice kept")
try? USBSwitch.set(true, folder: folder)
expect(USBSwitch.devices(folder: folder) == parsed, "on again: the same devices")
try? FileManager.default.removeItem(at: folder)

// The scan only reads the IORegistry; on any Mac it returns without opening anything.
_ = USBScan.devices()
expect(true, "the IORegistry scan runs")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
