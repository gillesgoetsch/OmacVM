import Foundation

/// The LAN NIC is separate from the private, localhost-forwarded management NIC.
public struct BridgedNetworkConfig: Equatable, Sendable {
    public let interface: String
    public let mac: String
    public static let fileName = "bridged-network"
    public static let managementMAC = "52:54:00:12:34:56"

    public enum ConfigurationError: LocalizedError {
        case invalid
        public var errorDescription: String? { "Invalid bridged-network settings: choose a supported interface with omacvm network." }
    }

    public init(interface: String, mac: String) throws {
        guard interface.range(of: "^en[0-9]{1,4}\\z", options: .regularExpression) != nil,
              mac.range(of: "^52:54:00(:[0-9a-f]{2}){3}\\z", options: .regularExpression) != nil,
              mac != Self.managementMAC else { throw ConfigurationError.invalid }
        self.interface = interface
        self.mac = mac
    }

    public init(text: String) throws {
        var values: [String: String] = [:]
        let record = text.hasSuffix("\n") ? text.dropLast() : text[...]
        for line in record.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, ["interface", "mac"].contains(String(parts[0])),
                  values[String(parts[0])] == nil else { throw ConfigurationError.invalid }
            values[String(parts[0])] = String(parts[1])
        }
        guard values.count == 2, let interface = values["interface"], let mac = values["mac"] else {
            throw ConfigurationError.invalid
        }
        try self.init(interface: interface, mac: mac)
    }

    public var text: String { "interface=\(interface)\nmac=\(mac)\n" }
    public var socket: String { "/var/run/org.omacvm.netd.bridge.\(interface).sock" }

    public func arguments(sshPort: Int) -> [String] {
        ["-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:\(sshPort)-:22",
         "-device", "virtio-net-pci,netdev=net0,mac=\(Self.managementMAC),romfile=",
         "-netdev", "stream,id=bridged,server=off,reconnect-ms=1000,addr.type=unix,addr.path=\(socket)",
         "-device", "virtio-net-pci,id=bridged-nic,netdev=bridged,mac=\(mac),romfile=",
         "-smbios", "type=11,value=omacvm.bridged=\(mac)"]
    }
}
