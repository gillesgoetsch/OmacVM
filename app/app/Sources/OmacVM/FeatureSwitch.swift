import Foundation
import OmacVMFeatures

/// The two ways the window switches a VM feature (the VM folder's `features`
/// record), shared by the feature's own row and the Battery saver group, so
/// both write the same thing: while the VM is stopped the record and the
/// feature's pending file (PendingSwitch; the app sets the VM's part up at the
/// next start, FeatureStart), while it runs this app's `omacvm enable|disable`
/// for the VM, which sets it up at once.
enum FeatureSwitch {
    /// The VM is stopped: the record and the pending file, for its next
    /// start. nil, or what went wrong.
    static func writeStopped(_ sw: PendingSwitch, folder f: URL, on: Bool) -> String? {
        let recordURL = f.appendingPathComponent("features")
        let pendingURL = f.appendingPathComponent(sw.pendingFile)
        let next = sw.switchStopped(record: try? String(contentsOf: recordURL, encoding: .utf8),
                                    pending: try? String(contentsOf: pendingURL, encoding: .utf8), on: on)
        do {
            try next.record.write(to: recordURL, atomically: true, encoding: .utf8)
            if let p = next.pending { try p.write(to: pendingURL, atomically: true, encoding: .utf8) }
            else if FileManager.default.fileExists(atPath: pendingURL.path) { try FileManager.default.removeItem(at: pendingURL) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The VM runs: one `omacvm enable|disable F...` for the VM (one apply
    /// transaction for all of them); done, their pending files go. Blocks:
    /// call it off the main thread. nil, or omacvm's last line.
    nonisolated static func runCLI(_ switches: [PendingSwitch], on: Bool, config c: VMConfig) -> String? {
        guard !switches.isEmpty else { return nil }
        let err = MacIMERow.run([on ? "enable" : "disable"] + switches.map(\.feature) + ["--vm", c.name, "--vm-type", "app", "--yes"])
        if err == nil {
            for sw in switches { try? FileManager.default.removeItem(at: c.folder.appendingPathComponent(sw.pendingFile)) }
        }
        return err
    }
}
