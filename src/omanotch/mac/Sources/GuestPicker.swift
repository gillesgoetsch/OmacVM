import Foundation

/// A connected guest, as far as picking the one for the strip goes.
struct GuestCandidate: Equatable {
    let id: Int
    /// The VM app it runs in ("Parallels Desktop", "UTM", "VMware Fusion",
    /// "OmacVM"); nil: not said or unknown, could be any.
    var owner: String?
}

/// Picks the guest whose VM is in the full-screen window on the built-in
/// display. Only the window's app is known (the window list says it without
/// any permission), not which of its VMs it shows.
enum GuestPicker {
    /// `guests` in connection order (first connected first); `owner` is the
    /// app of the full-screen window. A guest that said that app beats one
    /// that said nothing. Among those: the current guest, else the most
    /// recently connected one. nil when no guest can run in that app.
    static func pick(_ guests: [GuestCandidate], owner: String, current: Int?) -> Int? {
        let sure = guests.filter { $0.owner == owner }
        let set = sure.isEmpty ? guests.filter { $0.owner == nil } : sure
        if let current, set.contains(where: { $0.id == current }) { return current }
        return set.last?.id
    }

    /// The VM app for the hypervisor in a guest's "hello" (first word).
    static func owner(hello: String) -> String? {
        switch hello.split(separator: " ").first {
        case "parallels": return "Parallels Desktop"
        case "qemu": return "UTM"
        case "vmware": return "VMware Fusion"
        default: return nil
        }
    }

    /// The VM name from "vmname <base64>": UTF-8, at most 255 bytes, one line.
    static func vmName(base64: String) -> String? {
        let s = base64.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count <= 400, let data = Data(base64Encoded: s), !data.isEmpty, data.count <= 255,
              let name = String(data: data, encoding: .utf8), !name.contains(where: { $0.isNewline })
        else { return nil }
        return name
    }
}

/// Which guest is served and whether its bar is parked, as commands for the
/// guests. Only the served guest is ever parked: switching guests brings the
/// old one's bar back before the new one is parked.
struct ParkState {
    private(set) var active: Int?
    private(set) var parked = false

    /// Serve `guest` (nil: none).
    mutating func activate(_ guest: Int?) -> [(guest: Int, line: String)] {
        guard guest != active else { return [] }
        var out: [(guest: Int, line: String)] = []
        if let old = active, parked {
            // The guest hides its cursor while the pointer is over the strip.
            out = [(old, "park 0"), (old, "cursor 1")]
        }
        active = guest
        parked = false
        return out
    }

    mutating func setParked(_ on: Bool) -> [(guest: Int, line: String)] {
        guard on != parked, let a = active else { return [] }
        parked = on
        return [(a, "park \(on ? 1 : 0)")]
    }

    /// A guest that just connected, when no full-screen window will show
    /// its strip (`served` false), is told at once that the strip is hidden:
    /// a guest whose strip showed at the end of its last session starts with
    /// its bar parked (bar patch v16) and would otherwise wait for its own
    /// grace time before the bar comes back.
    func connected(_ guest: Int, served: Bool) -> [(guest: Int, line: String)] {
        served ? [] : [(guest, "park 0")]
    }

    /// The guest's session started over (it starts unparked) or ended.
    mutating func reset(_ guest: Int, gone: Bool) {
        guard guest == active else { return }
        parked = false
        if gone { active = nil }
    }
}
