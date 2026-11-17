import Foundation

/// Prefer VP9 on YouTube (feature youtube-vp9: experimental, off by default;
/// docs/video-decode.md): OmacVM's no-AV1 extension as an external extension
/// of Google Chrome and Chromium in the VM, so YouTube sends VP9, which the
/// Mac's media engine decodes, instead of AV1, which an M1 or M2 decodes
/// only on the VM's CPUs. Nothing of it runs on the Mac: the app only
/// switches it, as drag and drop (PendingSwitch while the VM is stopped,
/// `omacvm enable|disable` while it runs). Apart from the UI so it is tested
/// without a VM: `swift run features-tests`.
public enum YouTubeVP9 {
    public static let feature = "youtube-vp9"

    /// Switched in the window while the VM is stopped: PendingSwitch, as Mac input.
    public static let switchState = PendingSwitch(feature: feature, defaultOn: false)

    public static func isOn(features text: String?) -> Bool { switchState.isOn(features: text) }

    /// The row shows on a Mac whose media engine has no AV1 decoder (asked
    /// at run time, Mac.decodesAV1), and on any Mac while it is on, so a VM
    /// brought from an M1 or M2 can still switch it off.
    public static func shown(decodesAV1: Bool, record: String?, pending text: String?) -> Bool {
        !decodesAV1 || (switchState.pending(text) ?? isOn(features: record))
    }

    /// The settings row: Mac input's rules (MacIME.row).
    public static func row(record: String?, pending text: String?, running: Bool, busy: Bool, cli: Bool) -> MacIME.Row {
        let p = switchState.pending(text)
        let on = p ?? isOn(features: record)
        if busy { return MacIME.Row(on: on, enabled: false, note: nil) }
        if !running { return MacIME.Row(on: on, enabled: true, note: nil) }
        return MacIME.Row(on: on, enabled: cli, note: p != nil ? "Being set up in the VM for this start." : nil)
    }

    /// The (i) text of the window's row. The figures: docs/video-decode.md
    /// (MacBook Air M2, YouTube 1080p60 full screen, whole Mac, A/B/B/A).
    public static let info = "Experimental. This Mac's media engine has no AV1 decoder, so when YouTube sends AV1 the VM's CPUs decode it. With this on, Google Chrome and Chromium in the VM tell YouTube they cannot play AV1, and YouTube streams VP9 instead, which the Mac's media engine decodes. On a MacBook Air (M2) a 1080p60 YouTube video took about 1.2 W less for the whole Mac (5.4 W instead of 6.6 W). The trade-offs: videos that YouTube offers only in AV1, and quality steps it offers only in AV1, are not offered; and for now the media engine drops about 1 to 3 % of the frames of a 1080p60 video (a fix is being worked on). Only on youtube.com; other sites and other codecs are as before. The browsers add it at their next start; you can remove it in chrome://extensions at any time."
}
