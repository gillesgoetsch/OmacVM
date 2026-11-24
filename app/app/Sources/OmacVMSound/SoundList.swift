import Foundation

/// One element of Control Center's Sound list, as Accessibility gives it.
/// `enabled` is false for an option macOS shows but does not offer now, such
/// as Spatial Audio's "Not Available".
public struct SoundElement: Equatable {
    public var depth: Int
    public var role, subrole, identifier, description, value: String
    public var enabled: Bool
    public init(depth: Int, role: String, subrole: String = "", identifier: String = "", description: String = "", value: String = "",
                enabled: Bool = true) {
        self.depth = depth; self.role = role; self.subrole = subrole
        self.identifier = identifier; self.description = description; self.value = value; self.enabled = enabled
    }
}

/// A device in the list. `selected`: sound plays there (macOS's checkmark).
/// `modes`: what macOS offers to switch on it, such as AirPods' Listening
/// Mode, in the list's order.
public struct SoundRow: Equatable {
    public var name: String
    public var selected: Bool
    public var modes: [SoundMode]
    public init(name: String, selected: Bool, modes: [SoundMode] = []) { self.name = name; self.selected = selected; self.modes = modes }
}

/// A group of a device's modes: macOS's heading and the options under it,
/// in the Mac's language (no element says more about what a mode is).
public struct SoundMode: Equatable {
    public var title: String
    public var options: [SoundOption]
    public init(title: String, options: [SoundOption]) { self.title = title; self.options = options }
}

/// `selected`: macOS's checkmark. `enabled`: macOS offers it now. The two are
/// independent: a "Not Available" that is not offered can be selected.
public struct SoundOption: Equatable {
    public var title: String
    public var selected, enabled: Bool
    public init(title: String, selected: Bool, enabled: Bool = true) { self.title = title; self.selected = selected; self.enabled = enabled }
}

/// What Control Center's Sound list says (SoundPicker reads it), without
/// Accessibility: the rules are tested on recorded lists (sound-tests).
public enum SoundList {
    /// The list's title, there only while the list shows.
    public static let title = "controlcenter-volume"
    /// A device's row: this prefix, then the device's name. Headphones that
    /// play have more elements with their identifier: a disclosure triangle
    /// before their row, and after it the headings and options of their
    /// modes (Listening Mode, Spatial Audio), while the triangle is open.
    public static let rowPrefix = "sound-device-"
    public static let rowRole = "AXCheckBox"
    static let headingRole = "AXHeading"
    static let disclosureRole = "AXDisclosureTriangle"

    /// The devices: of the checkboxes with one identifier, the first. After
    /// it, a heading of that identifier starts a group of modes and each
    /// checkbox is an option of the group; anything else (the images of
    /// Adaptive's level) is no option. A heading or an option needs its
    /// title, the only name the guest can ask for it by.
    public static func rows(_ elements: [SoundElement]) -> [SoundRow] {
        var rows: [SoundRow] = []
        var row: [String: Int] = [:]
        for e in elements where e.identifier.hasPrefix(rowPrefix) && e.identifier.count > rowPrefix.count {
            guard let i = row[e.identifier] else {
                if e.role == rowRole {
                    row[e.identifier] = rows.count
                    rows.append(SoundRow(name: String(e.identifier.dropFirst(rowPrefix.count)), selected: e.value == "1"))
                }
                continue
            }
            if e.role == headingRole, !e.description.isEmpty {
                rows[i].modes.append(SoundMode(title: e.description, options: []))
            } else if e.role == rowRole, !e.description.isEmpty, !rows[i].modes.isEmpty {
                rows[i].modes[rows[i].modes.count - 1].options.append(SoundOption(title: e.description, selected: e.value == "1", enabled: e.enabled))
            }
        }
        for i in rows.indices { rows[i].modes.removeAll { $0.options.isEmpty } }
        return rows
    }

    /// Control Center's list, not a moment of it being rebuilt: its title and
    /// a device are there.
    public static func isList(_ elements: [SoundElement]) -> Bool {
        elements.contains { $0.identifier == title } && !rows(elements).isEmpty
    }

    /// An option as the list has it now: the device's, under the heading
    /// `group`. Titles like "Off" and "On" repeat across groups.
    public static func option(_ rows: [SoundRow], device: String, group: String, option: String) -> SoundOption? {
        rows.first { $0.name == device }?.modes.first { $0.title == group }?.options.first { $0.title == option }
    }

    /// Where that option is in the list, to press it: after the device's
    /// row, never the row itself.
    public static func optionIndex(_ elements: [SoundElement], device: String, group: String, option: String) -> Int? {
        var afterRow = false, inGroup = false
        for (i, e) in elements.enumerated() where e.identifier == rowPrefix + device {
            if !afterRow { afterRow = e.role == rowRole; continue }
            if e.role == headingRole { inGroup = e.description == group } else if inGroup, e.role == rowRole, e.description == option { return i }
        }
        return nil
    }

    /// The closed disclosure triangle of a device that plays: its modes are
    /// not in the list until it is opened, and Control Center keeps it as the
    /// person left it.
    public static func closedDisclosure(_ elements: [SoundElement]) -> Int? {
        let playing = Set(rows(elements).filter(\.selected).map { rowPrefix + $0.name })
        return elements.firstIndex { $0.role == disclosureRole && $0.value == "0" && playing.contains($0.identifier) }
    }

    /// The devices with the checkmark.
    public static func playing(_ rows: [SoundRow]) -> Set<String> { Set(rows.filter(\.selected).map(\.name)) }

    /// After a press of `name`: macOS is done once the press took effect,
    /// or once the checkmarks moved (`moved`) and are as before again: the
    /// speaker did not connect and macOS went back.
    public static func pressDone(_ name: String, before: [SoundRow], now: [SoundRow], moved: Bool) -> Bool {
        switched(name, before: before, now: now) || moved && playing(now) == playing(before)
    }

    /// The press of `name` took effect: the row's checkmark differs from
    /// before. Only checkmarks count: a row that a read misses says nothing.
    public static func switched(_ name: String, before: [SoundRow], now: [SoundRow]) -> Bool {
        func selected(_ rows: [SoundRow]) -> Bool? { rows.first { $0.name == name }?.selected }
        guard let was = selected(before), let isNow = selected(now) else { return false }
        return was != isNow
    }
}
