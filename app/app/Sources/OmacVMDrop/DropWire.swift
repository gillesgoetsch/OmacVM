import Foundation

/// Drag and drop of files from the Mac into the VM (feature drag-drop;
/// docs/drag-and-drop.md, docs/adr/0069-drag-and-drop.md). Three pieces talk:
///
/// - QEMU's window (omacvm-cocoa-drop.patch) takes the drop, opens the files
///   itself (macOS gives the process the person dropped on access to them) and
///   hands this app their descriptors over OMACVM_DROP_SOCKET, never paths.
/// - This app (DropServer) clones or copies them into the VM folder's `drop`
///   folder, which the VM sees read-only over virtio-9p (tag omacvm-drop),
///   and tells the VM on the port org.omacvm.drop.
/// - The VM's omacvm-drop drops them into the app under the pointer, or puts
///   them in Downloads, and answers.
///
/// This file: the limits and the lines on both sockets, apart from the
/// sockets so `swift run drop-tests` covers them.
public enum DropWire {
    /// At most this many files per drop; QEMU refuses more before the drop
    /// (the cursor shows no drop). Keeps the descriptors in bounded messages.
    public static let maxItems = 256
    /// Descriptors per message from QEMU (macOS takes far more; small is safe).
    public static let maxPerFrame = 32
    /// One frame's JSON at most (32 names of 255 bytes, escaped).
    public static let maxFrame = 64 * 1024
    /// One line on the VM's port at most.
    public static let maxLine = 64 * 1024
    /// A guest answer's "why" is cut to this.
    public static let maxWhy = 200

    // MARK: names

    /// A dropped file's name as the VM will see it: one path component, no
    /// "/", NUL or control characters, not "." or "..", at most 255 bytes.
    public static func nameOK(_ n: String) -> Bool {
        let b = Array(n.utf8)
        guard !b.isEmpty, b.count <= 255, n != ".", n != ".." else { return false }
        return !n.unicodeScalars.contains { $0 == "/" || $0.value < 0x20 || $0.value == 0x7F }
    }

    // MARK: QEMU -> this app (one frame per sendmsg, with the descriptors)

    /// A frame: 4 bytes of length (big-endian), then JSON
    /// {"v":1,"drop":N,"at":UNIX_MS,"last":true,"names":[...],"skipped":K}.
    /// `names` are the files whose descriptors ride with this frame, in order.
    public struct Frame: Equatable {
        public var drop: Int
        public var at: Int64
        public var last: Bool
        public var names: [String]
        public var skipped: Int
        public init(drop: Int, at: Int64, last: Bool, names: [String], skipped: Int) {
            self.drop = drop; self.at = at; self.last = last; self.names = names; self.skipped = skipped
        }
    }

    public enum FrameError: Error, Equatable { case tooLong, notJSON, badField(String) }

    /// The JSON of a frame (without its length), checked: QEMU is ours, but a
    /// frame is still bounded and checked before any descriptor is used.
    public static func frame(json data: Data, fds: Int) -> Result<Frame, FrameError> {
        guard data.count <= maxFrame else { return .failure(.tooLong) }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.notJSON) }
        guard (o["v"] as? Int) == 1 else { return .failure(.badField("v")) }
        guard let d = o["drop"] as? Int, d >= 0 else { return .failure(.badField("drop")) }
        guard let at = (o["at"] as? NSNumber)?.int64Value, at >= 0 else { return .failure(.badField("at")) }
        guard let last = o["last"] as? Bool else { return .failure(.badField("last")) }
        guard let names = o["names"] as? [String], names.count <= maxPerFrame, names.count == fds else {
            return .failure(.badField("names"))
        }
        guard names.allSatisfy(nameOK) else { return .failure(.badField("name")) }
        let skipped = o["skipped"] as? Int ?? 0
        guard skipped >= 0, skipped <= maxItems else { return .failure(.badField("skipped")) }
        return .success(Frame(drop: d, at: at, last: last, names: names, skipped: skipped))
    }

    // MARK: this app -> QEMU (lines)

    /// QEMU takes drops only after "ready" (the VM's omacvm-drop said hello
    /// and the drop folder is there); "wait" otherwise. Before the first line
    /// it takes none.
    public static func readyLine(_ ready: Bool) -> String { ready ? "ready\n" : "wait\n" }

    /// Tests only (OMACVM_DROP_TEST=1 in both this app's and QEMU's
    /// environment): QEMU drops these Mac paths as if they were dropped on
    /// its window, through the same code after the pasteboard.
    public static func testDropLine(paths: [String]) -> String? {
        guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\t") && !$0.contains("\n") }) else { return nil }
        return "test-drop\t" + paths.joined(separator: "\t") + "\n"
    }

    // MARK: the VM's port org.omacvm.drop (one JSON object per line)

    /// One dropped file as the VM gets it.
    public struct Item: Equatable {
        public var name: String
        public var bytes: Int64
        public init(name: String, bytes: Int64) { self.name = name; self.bytes = bytes }
    }

    public static let hello = "{\"t\":\"hello\",\"v\":1}\n"

    /// A drop for the VM: its folder's id, the files, and how long ago (ms)
    /// the person dropped them (the VM puts a late drop into Downloads: the
    /// pointer has moved on by then).
    public static func dropLine(id: String, items: [Item], ageMS: Int64) -> String {
        let list = items.map { ["name": $0.name, "bytes": $0.bytes] as [String: Any] }
        let o: [String: Any] = ["t": "drop", "id": id, "age": max(0, ageMS), "items": list]
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: d, as: UTF8.self) + "\n"
    }

    /// What the VM said. Anything else is ignored (and counted).
    public enum FromGuest: Equatable {
        case hello(version: Int)
        case done(id: String, to: String, why: String)
        case bye
    }

    /// The VM is untrusted: a bounded line, known fields, a drop id of 16
    /// hex digits, "to" one of app, downloads, failed; "why" cut short.
    public static func parseGuest(_ line: String) -> FromGuest? {
        guard line.utf8.count <= 4096, let d = line.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let t = o["t"] as? String else { return nil }
        switch t {
        case "hello":
            guard let v = o["v"] as? Int, v >= 1 else { return nil }
            return .hello(version: v)
        case "bye":
            return .bye
        case "done":
            guard let id = o["id"] as? String, idOK(id), let to = o["to"] as? String,
                  ["app", "downloads", "failed"].contains(to) else { return nil }
            let why = (o["why"] as? String ?? "").unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
            return .done(id: id, to: to, why: String(String.UnicodeScalarView(why.prefix(maxWhy))))
        default:
            return nil
        }
    }

    public static func idOK(_ id: String) -> Bool {
        id.utf8.count == 16 && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// A new drop folder's id: 16 random hex digits.
    public static func newID() -> String {
        var b = [UInt8](repeating: 0, count: 8)
        arc4random_buf(&b, b.count)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: readiness

    /// The VM's omacvm-drop says hello every 15 s; after 45 s without one
    /// (the service stopped, the VM went to sleep) QEMU takes no drops.
    public static let lease: TimeInterval = 45

    public static func ready(lastHello: Date?, now: Date, folderOK: Bool) -> Bool {
        guard folderOK, let h = lastHello else { return false }
        return now.timeIntervalSince(h) <= lease && now >= h.addingTimeInterval(-5)
    }
}
