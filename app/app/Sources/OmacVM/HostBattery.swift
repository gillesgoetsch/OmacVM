// The Mac's battery for the VM: one snapshot of its power sources, as JSON.
// (The Bridge's copy went with the retired routes in 3.4.0.)
//
// From try-omarchy (github.com/omacom/try-omarchy), MIT, (c) Try Omarchy
// contributors: macos/Sources/OmarchyVMHelper/NativeBatteryBridge.swift
// (HostBatterySnapshot), HostBatteryDetails.swift, HostChargeLimit.swift.
import Foundation
import IOKit
import IOKit.ps

/// One complete snapshot of the Mac's power sources.
struct HostBatterySnapshot: Equatable {
    let present: Bool
    let percentage: Int?
    let state: String
    let acConnected: Bool
    let timeToEmptySeconds: Int?
    let timeToFullSeconds: Int?
    let chargeLimit: Int?
    let details: HostBatteryDetails

    init(descriptions: [[String: Any]], chargeLimit: Int? = nil, details: HostBatteryDetails = HostBatteryDetails()) {
        let internalBattery = descriptions.first {
            $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType && $0[kIOPSIsPresentKey] as? Bool != false
        }
        guard let battery = internalBattery else {
            present = false; percentage = nil; state = "unknown"; acConnected = true
            timeToEmptySeconds = nil; timeToFullSeconds = nil; self.chargeLimit = nil; self.details = HostBatteryDetails()
            return
        }
        present = true
        self.details = details
        self.chargeLimit = chargeLimit.flatMap { (1..<100).contains($0) ? $0 : nil }
        let current = battery[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = battery[kIOPSMaxCapacityKey] as? Int ?? 100
        percentage = maximum > 0 ? min(100, max(0, current * 100 / maximum)) : 0
        let onMains = battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        acConnected = onMains
        if battery[kIOPSIsChargingKey] as? Bool == true { state = "charging" }
        else if battery[kIOPSIsChargedKey] as? Bool == true { state = "full" }
        else if onMains { state = "not-charging" }
        else { state = "discharging" }
        func seconds(_ key: String) -> Int? {
            guard let minutes = battery[key] as? Int, minutes >= 0 else { return nil }
            return minutes * 60
        }
        timeToEmptySeconds = state == "discharging" ? seconds(kIOPSTimeToEmptyKey) : nil
        timeToFullSeconds = state == "charging" ? seconds(kIOPSTimeToFullChargeKey) : nil
    }

    /// One line for the virtio port.
    var line: Data {
        var data = (try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    var dictionary: [String: Any] {
        [
            "type": "state",
            "present": present,
            "percentage": percentage as Any? ?? NSNull(),
            "state": state,
            "acConnected": acConnected,
            "timeToEmptySeconds": timeToEmptySeconds as Any? ?? NSNull(),
            "timeToFullSeconds": timeToFullSeconds as Any? ?? NSNull(),
            "chargeLimit": chargeLimit as Any? ?? NSNull(),
            "chargeNowMicroAh": details.chargeNowMicroAh as Any? ?? NSNull(),
            "chargeFullMicroAh": details.chargeFullMicroAh as Any? ?? NSNull(),
            "chargeFullDesignMicroAh": details.chargeFullDesignMicroAh as Any? ?? NSNull(),
            "voltageMicroV": details.voltageMicroV as Any? ?? NSNull(),
            "cycleCount": details.cycleCount as Any? ?? NSNull(),
            "currentMicroA": details.currentMicroA as Any? ?? NSNull(),
            "powerMicroW": details.powerMicroW as Any? ?? NSNull(),
        ]
    }

    static func capture() -> HostBatterySnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                    let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return HostBatterySnapshot(descriptions: [])
        }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return HostBatterySnapshot(descriptions: descriptions, chargeLimit: HostChargeLimit.capture(),
                                                              details: HostBatteryDetails.capture())
    }
}

/// The battery's own readings (AppleSmartBattery), apart from the 0-100
/// capacities above: charge in µAh, voltage in µV, current in µA and power
/// in µW, as Linux wants them. Current is signed: below 0 while the battery
/// gives power (discharging), as AppleSmartBattery's "Amperage" (mA).
struct HostBatteryDetails: Equatable {
    let chargeNowMicroAh: Int?
    let chargeFullMicroAh: Int?
    let chargeFullDesignMicroAh: Int?
    let voltageMicroV: Int?
    let cycleCount: Int?
    let currentMicroA: Int?
    let powerMicroW: Int?

    init(properties: [String: Any] = [:]) {
        let data = properties["BatteryData"] as? [String: Any] ?? [:]
        func reading(_ candidates: [Any?], multiplier: Int = 1, minimum: Int = 0) -> Int? {
            for candidate in candidates {
                guard let number = candidate as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                            let value = candidate as? Int, value >= minimum, value <= Int(Int32.max) / multiplier else { continue }
                return value * multiplier
            }
            return nil
        }
        chargeNowMicroAh = reading([properties["AppleRawCurrentCapacity"], data["RemainingCapacity"]], multiplier: 1000)
        chargeFullMicroAh = reading([properties["AppleRawMaxCapacity"], data["FullChargeCapacity"]], multiplier: 1000, minimum: 1)
        chargeFullDesignMicroAh = reading([properties["DesignCapacity"], data["DesignCapacity"]], multiplier: 1000, minimum: 1)
        voltageMicroV = reading([properties["Voltage"]], multiplier: 1000, minimum: 1)
        cycleCount = reading([properties["CycleCount"]])
        // Amperage is averaged by the battery (InstantAmperage is not): steadier
        // watts and time left. Power is current x voltage of the same reading,
        // so the watts and UPower's time left (charge / current) agree.
        let milliAmps = [properties["Amperage"], properties["InstantAmperage"]].lazy
            .compactMap(HostBatteryDetails.signedMilliamps).first
        currentMicroA = milliAmps.map { $0 * 1000 }
        if let milliAmps, let millivolts = voltageMicroV.map({ $0 / 1000 }) {
            let microWatts = abs(milliAmps) * millivolts   // mA x mV = µW
            powerMicroW = microWatts <= Int(Int32.max) ? microWatts : nil
        } else {
            powerMicroW = nil
        }
    }

    /// A signed current in mA from IOKit, or nil. IOKit keeps it as a signed
    /// 32-bit number; ioreg prints it as unsigned 64-bit (-573 shows as
    /// 18446744073709551043), so a wrapped 64- or 32-bit value is read back as
    /// signed too. More than ±2147 A (beyond Int32 in µA) is not a reading.
    static func signedMilliamps(_ candidate: Any?) -> Int? {
        guard let number = candidate as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        var value = number.int64Value              // UInt64 above Int64.max: its bit pattern
        if value > Int64(Int32.max) && value <= Int64(UInt32.max) {
            value = Int64(Int32(truncatingIfNeeded: value))
        }
        let limit = Int64(Int32.max / 1000)
        guard value >= -limit && value <= limit else { return nil }
        return Int(value)
    }

    static func capture() -> HostBatteryDetails {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return HostBatteryDetails() }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                    let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                    properties["BatteryInstalled"] as? Bool != false else { return HostBatteryDetails() }
        return HostBatteryDetails(properties: properties)
    }
}

/// The charge limit set in macOS (System Settings › Battery), read from
/// powerd's file. Undocumented: missing or changed means no limit.
enum HostChargeLimit {
    static let policyURL = URL(fileURLWithPath: "/Library/Preferences/com.apple.powerd.charging.plist")

    static func capture() -> Int? {
        guard let data = try? Data(contentsOf: policyURL),
                    let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                    let archive = plist["policies"] as? Data,
                    let decoder = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return nil }
        decoder.decodingFailurePolicy = .setErrorAndReturn
        decoder.setClass(HostChargingPolicy.self, forClassName: "ChargeCtrlPolicy")
        defer { decoder.finishDecoding() }
        guard let policies = decoder.decodeObject(of: [NSArray.self, HostChargingPolicy.self, NSString.self],
                                                                                            forKey: NSKeyedArchiveRootObjectKey) as? [HostChargingPolicy],
                    decoder.error == nil else { return nil }
        return policies.filter { $0.reason == "manualChargeLimit" && !$0.terminated && (1..<100).contains($0.limit) }
            .map(\.limit).min()
    }
}

@objc(OmacVMHostChargingPolicy)
private final class HostChargingPolicy: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let reason: String?
    let limit: Int
    let terminated: Bool

    required init?(coder: NSCoder) {
        reason = coder.decodeObject(of: NSString.self, forKey: "reason") as String?
        limit = coder.decodeInteger(forKey: "soclimit")
        terminated = coder.decodeBool(forKey: "terminated")
    }

    func encode(with coder: NSCoder) { preconditionFailure("read-only") }
}
