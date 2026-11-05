import Foundation

/// Drag and drop of files from the Mac into the VM (feature drag-drop,
/// experimental, off by default; docs/drag-and-drop.md). Only a VM whose
/// record says drag-drop=on gets the port org.omacvm.drop, the read-only drop
/// share and QEMU's drop socket; every other VM starts exactly as before.
/// The rest (staging, the port's lines) is OmacVMDrop.
public enum DragDrop {
    public static let feature = "drag-drop"

    /// Switched in the window while the VM is stopped: PendingSwitch, as Mac input.
    public static let switchState = PendingSwitch(feature: feature, defaultOn: false)

    public static func isOn(features text: String?) -> Bool { switchState.isOn(features: text) }

    /// The settings row: the same rules as Mac input's (MacIME.row).
    public static func row(record: String?, pending text: String?, running: Bool, busy: Bool, cli: Bool) -> MacIME.Row {
        let p = switchState.pending(text)
        let on = p ?? isOn(features: record)
        if busy { return MacIME.Row(on: on, enabled: false, note: nil) }
        if !running { return MacIME.Row(on: on, enabled: true, note: nil) }
        return MacIME.Row(on: on, enabled: cli, note: p == nil ? nil : "Being set up in the VM for this start.")
    }

    /// The (i) text of the window's row.
    public static let info = "Experimental. Drop files from the Finder onto the VM's window: they go into the app under the pointer (a Files folder, a browser's upload field), or into Downloads when no app takes them. Files only, up to 256 at a time; folders are refused. The VM gets read-only copies of just the files you drop, kept until the VM stops (dropped into Downloads: removed at once). An app that opens a dropped file directly cannot save over it: use Save As. Needs a restart of the VM."
}
