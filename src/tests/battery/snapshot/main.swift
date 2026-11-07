// The Mac's battery snapshot (OmacVM.app's HostBattery.swift) from ioreg-like readings, offline
// (src/tests/battery.sh). With a number: the snapshot's JSON for a made-up
// battery (that many mA; above 0 charging), for the line test. With "live": this Mac's own
// snapshot (IOKit, read only).
import Foundation
import IOKit.ps

var failed = false
func expect(_ what: String, _ ok: Bool) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { failed = true }
}

// AppleSmartBattery as IOKit hands it over: Amperage a signed number.
func smart(_ amperage: Any?, instant: Any? = nil, voltage: Any? = 12290) -> [String: Any] {
    var p: [String: Any] = ["AppleRawCurrentCapacity": 6818, "AppleRawMaxCapacity": 8594,
                            "DesignCapacity": 8579, "CycleCount": 98]
    if let voltage { p["Voltage"] = voltage }
    if let amperage { p["Amperage"] = amperage }
    if let instant { p["InstantAmperage"] = instant }
    return p
}
let onBattery: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: true,
    kIOPSCurrentCapacityKey: 84, kIOPSMaxCapacityKey: 100, kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
    kIOPSIsChargingKey: false, kIOPSTimeToEmptyKey: 911]

if CommandLine.arguments.dropFirst().first == "live" {   // this Mac's battery, read only
    let data = try! JSONSerialization.data(withJSONObject: HostBatterySnapshot.capture().dictionary, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}
if CommandLine.arguments.count == 2, let mA = Int(CommandLine.arguments[1]) {
    // Above 0: on the charger, charging.
    let charging = onBattery.merging([kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsChargingKey: true,
                                      kIOPSTimeToFullChargeKey: 40]) { $1 }
    let s = HostBatterySnapshot(descriptions: [mA > 0 ? charging : onBattery],
                                details: HostBatteryDetails(properties: smart(mA)))
    let data = try! JSONSerialization.data(withJSONObject: s.dictionary, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

var d = HostBatteryDetails(properties: smart(-573))
expect("discharging 573 mA: current -573000 µA", d.currentMicroA == -573000)
expect("power = |mA| x mV = 7042170 µW", d.powerMicroW == 7042170)
d = HostBatteryDetails(properties: smart(NSNumber(value: Int32(-573))))
expect("an SInt32 CFNumber (as IOKit keeps it)", d.currentMicroA == -573000)
d = HostBatteryDetails(properties: smart(NSNumber(value: UInt64(18446744073709551043))))
expect("unsigned 64-bit wrap (as ioreg prints it): -573 mA", d.currentMicroA == -573000)
d = HostBatteryDetails(properties: smart(NSNumber(value: UInt32(4294966723))))
expect("unsigned 32-bit wrap: -573 mA", d.currentMicroA == -573000)
d = HostBatteryDetails(properties: smart(2100, voltage: 12900))
expect("charging 2100 mA: current above 0, power 27.09 W", d.currentMicroA == 2100000 && d.powerMicroW == 27090000)
d = HostBatteryDetails(properties: smart(0))
expect("0 mA (full, on the charger): 0 and 0", d.currentMicroA == 0 && d.powerMicroW == 0)
d = HostBatteryDetails(properties: smart(nil, instant: -678))
expect("no Amperage: InstantAmperage", d.currentMicroA == -678000)
d = HostBatteryDetails(properties: smart(-298, instant: -678))
expect("both: Amperage (the battery's average)", d.currentMicroA == -298000)
d = HostBatteryDetails(properties: smart("-573" as NSString, instant: -678))
expect("Amperage not a number: InstantAmperage", d.currentMicroA == -678000)
d = HostBatteryDetails(properties: smart(true))
expect("a boolean is no current", d.currentMicroA == nil && d.powerMicroW == nil)
d = HostBatteryDetails(properties: smart(nil))
expect("no current at all: none, and no power", d.currentMicroA == nil && d.powerMicroW == nil)
d = HostBatteryDetails(properties: smart(-573, voltage: nil))
expect("no voltage: current, no power", d.currentMicroA == -573000 && d.powerMicroW == nil)
d = HostBatteryDetails(properties: smart(3_000_000))
expect("3000 A is no reading", d.currentMicroA == nil && d.powerMicroW == nil)
d = HostBatteryDetails(properties: smart(-2_147_483))
expect("-2147483 mA still fits in Int32 µA", d.currentMicroA == -2_147_483_000)
d = HostBatteryDetails(properties: smart(-200_000, voltage: 20000))
expect("power past Int32 µW: none", d.currentMicroA == -200_000_000 && d.powerMicroW == nil)

// The JSON: both keys; null when not known; none without a battery.
var s = HostBatterySnapshot(descriptions: [onBattery], details: HostBatteryDetails(properties: smart(-573)))
var j = s.dictionary
expect("JSON: currentMicroA -573000, powerMicroW 7042170",
       j["currentMicroA"] as? Int == -573000 && j["powerMicroW"] as? Int == 7042170)
expect("JSON: discharging, 911 min left", j["state"] as? String == "discharging" && j["timeToEmptySeconds"] as? Int == 54660)
s = HostBatterySnapshot(descriptions: [onBattery], details: HostBatteryDetails(properties: smart(nil)))
j = s.dictionary
expect("JSON: no current: both null", j["currentMicroA"] is NSNull && j["powerMicroW"] is NSNull)
s = HostBatterySnapshot(descriptions: [], details: HostBatteryDetails(properties: smart(-573)))
j = s.dictionary
expect("JSON: no battery: present false, both null", j["present"] as? Bool == false && j["currentMicroA"] is NSNull)
let a = HostBatterySnapshot(descriptions: [onBattery], details: HostBatteryDetails(properties: smart(-573)))
let b = HostBatterySnapshot(descriptions: [onBattery], details: HostBatteryDetails(properties: smart(-600)))
expect("a new current is a new snapshot (the app sends it)", a != b)

print(failed ? "snapshot: FAILED" : "snapshot: all passed")
exit(failed ? 1 : 0)
