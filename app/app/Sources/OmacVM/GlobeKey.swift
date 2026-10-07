import Darwin
import Foundation

/// macOS's globe-key shortcut (188: the globe key pressed on its own, which
/// opens Emoji & Symbols). QEMU switches it off while the VM has the keyboard
/// and gives it back itself (omacvm-cocoa-globe-key.patch); the switch is the
/// window server's for the whole login, so a QEMU that was killed or crashed
/// leaves it off. Its note in the temp folder holds that QEMU's pid: when
/// that QEMU has ended, the shortcut goes back on here.
enum GlobeKey {
    static let hotKey: Int32 = 188

    /// $TMPDIR/omacvm-globe-off, as QEMU names it (confstr, not $TMPDIR).
    static var note: URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf)).appendingPathComponent("omacvm-globe-off")
    }

    /// The pid in the note, nil without one.
    static func notePid(_ url: URL) -> pid_t? {
        guard let s = try? String(contentsOf: url, encoding: .utf8),
              let n = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 else { return nil }
        return n
    }

    /// Whether a note's QEMU has ended, so the shortcut is to be given back.
    /// `exited`: the QEMU this app just saw end.
    static func leftOff(notePid: pid_t?, exited: pid_t, alive: (pid_t) -> Bool) -> Bool {
        guard let p = notePid else { return false }
        return p == exited || !alive(p)
    }

    /// True when it gave it back.
    @discardableResult
    static func giveBack(after exited: pid_t) -> Bool {
        guard let url = note,
              leftOff(notePid: notePid(url), exited: exited,
                      alive: { kill($0, 0) == 0 || errno != ESRCH }) else { return false }
        typealias SetFn = @convention(c) (Int32, Bool) -> Int32
        let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSSetSymbolicHotKeyEnabled")
            ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetSymbolicHotKeyEnabled")
        guard let sym, unsafeBitCast(sym, to: SetFn.self)(hotKey, true) == 0 else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }
}
