import Darwin
import Foundation

/// Touch ID's panel for this app's VMs (docs/adr/0041-touch-id.md): what the
/// Bridge asks the panel to show, and what the panel answers.
///
/// The Bridge decides that a request may ask, then sends the words and the
/// VM's theme in an interim answer on the relay connection:
///   HTTP/1.1 103 Touch ID Panel
///   X-OmacVM-Panel: <base64 of the prompt's JSON>
/// The app has QEMU's panel (OmacVMTouchIDPanel, in the VM window's process)
/// show it, and writes the panel's answer back on the same connection as one
/// line (`bridgeLine`): "yes", "no <reason>", or "error" (the panel could not
/// show: the Bridge then shows the Mac's own dialog). The Bridge signs the
/// final answer as for every other route.
///
/// App and panel speak JSON lines on the panel's socket:
///   app -> panel  {"op":"show","prompt":{...}}   {"op":"close"}
///   panel -> app  {"result":"yes"}  {"result":"no","reason":R}  {"result":"error"}
public struct TouchIDPanelPrompt: Equatable {
    public var title: String
    public var line: String
    public var box: String?
    public var timeout: Int
    /// "#rrggbb" for the keys in `colorKeys` the Bridge sent (others dropped).
    public var colors: [String: String]

    public static let colorKeys = ["background", "foreground", "accent", "error", "success", "muted"]
    public static let maximumHeaderBytes = 4096

    public init(title: String, line: String, box: String?, timeout: Int, colors: [String: String]) {
        self.title = title; self.line = line; self.box = box; self.timeout = timeout; self.colors = colors
    }

    static func isHexColor(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return b.count == 7 && b[0] == 35 && b.dropFirst().allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Printable text, at most `max` characters (the Bridge already cleaned it).
    static func text(_ v: Any?, max: Int) -> String? {
        guard let s = v as? String, !s.isEmpty, s.count <= max,
              s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        return s
    }

    /// The prompt from its JSON object, or nil (not one).
    public static func parse(_ o: Any) -> TouchIDPanelPrompt? {
        guard let o = o as? [String: Any], let title = text(o["title"], max: 80), let line = text(o["line"], max: 120),
              let t = o["timeout"] as? Int, (5...60).contains(t) else { return nil }
        var box: String?
        if let b = o["box"] {
            guard let s = text(b, max: 1024) else { return nil }
            box = s
        }
        var colors: [String: String] = [:]
        if let c = o["theme"] as? [String: Any] {
            for k in colorKeys { if let v = c[k] as? String, isHexColor(v) { colors[k] = v } }
        }
        return TouchIDPanelPrompt(title: title, line: line, box: box, timeout: t, colors: colors)
    }

    /// The prompt from the Bridge's X-OmacVM-Panel header, or nil.
    public static func parse(header: String) -> TouchIDPanelPrompt? {
        guard header.utf8.count <= maximumHeaderBytes, let d = Data(base64Encoded: header),
              let o = try? JSONSerialization.jsonObject(with: d) else { return nil }
        return parse(o)
    }

    public var json: [String: Any] {
        var o: [String: Any] = ["title": title, "line": line, "timeout": timeout, "theme": colors]
        if let box { o["box"] = box }
        return o
    }

    /// The line the app sends the panel.
    public var showLine: Data {
        var d = (try? JSONSerialization.data(withJSONObject: ["op": "show", "prompt": json], options: [.sortedKeys])) ?? Data()
        d.append(0x0A)
        return d
    }
    public static let closeLine = Data("{\"op\":\"close\"}\n".utf8)
}

public enum TouchIDPanelResult: Equatable {
    case yes
    case no(String)
    /// The panel could not show (nothing was on screen): the Mac's own dialog instead.
    case error

    public static let reasons: Set<String> = ["cancelled", "timeout", "failed", "lockout", "no-touch-id", "not-front", "locked"]

    /// The panel's line, or nil (not one).
    public static func parse(_ line: Data) -> TouchIDPanelResult? {
        guard line.count <= 256, let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let r = o["result"] as? String else { return nil }
        switch r {
        case "yes": return .yes
        case "error": return .error
        case "no":
            guard let why = o["reason"] as? String, reasons.contains(why) else { return .no("failed") }
            return .no(why)
        default: return nil
        }
    }

    /// The panel's own line to the app.
    public var line: Data {
        let o: [String: Any]
        switch self {
        case .yes: o = ["result": "yes"]
        case .error: o = ["result": "error"]
        case .no(let why): o = ["result": "no", "reason": why]
        }
        var d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        d.append(0x0A)
        return d
    }

    /// The app's line to the Bridge.
    public var bridgeLine: Data {
        switch self {
        case .yes: return Data("yes\n".utf8)
        case .error: return Data("error\n".utf8)
        case .no(let why): return Data("no \(TouchIDPanelResult.reasons.contains(why) ? why : "failed")\n".utf8)
        }
    }
}

/// The app's side of the panel's socket: shows one prompt and waits for its
/// answer. The VM's client going away (`gone`) or no answer by the prompt's
/// timeout (plus 5 s) closes the panel.
public enum TouchIDPanelClient {
    public static func ask(fd: Int32, _ p: TouchIDPanelPrompt, gone: () -> Bool) -> TouchIDPanelResult {
        func send(_ d: Data) -> Bool { d.withUnsafeBytes { b in Darwin.write(fd, b.baseAddress, b.count) == b.count } }
        guard send(p.showLine) else { return .error }
        let deadline = Date().addingTimeInterval(TimeInterval(p.timeout) + 5)
        var data = Data(), chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            if gone() { _ = send(TouchIDPanelPrompt.closeLine); return .no("cancelled") }
            if Date() >= deadline { _ = send(TouchIDPanelPrompt.closeLine); return .no("timeout") }
            var pf = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pf, 1, 250)
            if ready < 0 { if errno == EINTR { continue }; return .error }
            if ready == 0 { continue }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            // The panel went away before it answered: it may have been on screen.
            if n <= 0 { return data.isEmpty ? .error : .no("failed") }
            data.append(contentsOf: chunk[0..<n])
            if let nl = data.firstIndex(of: 0x0A) {
                return TouchIDPanelResult.parse(data[..<nl]) ?? .no("failed")
            }
            if data.count > 1024 { return .no("failed") }
        }
    }
}
