import Foundation

/// The build window's progress, apart from the UI so it can be tested without
/// a VM: `swift run build-progress-tests`.
///
/// The build scripts (create-vm.sh, prebuilt-vm.sh) print progress lines:
///   {"omacvm_progress": 1, "phase": "download", "now": "hyprland", "n": 14, "of": 190, "done": 1234, "total": 5678}
/// Every field but omacvm_progress may be missing. Package lines come from the
/// VM (src/vm/progress.sh), so they are untrusted: limited sizes and counts,
/// short printable names, anything else is dropped.
public struct ProgressUpdate: Equatable, Sendable {
    public enum Phase: String, Sendable { case download, install }
    public var phase: Phase
    public var now: String
    public var n: Int
    public var of: Int
    public var done: Int64
    public var total: Int64

    static let maxBytes: Int64 = 1 << 42        // 4 TB
    static let maxCount = 100_000

    public static func parse(_ line: String) -> ProgressUpdate? {
        guard line.hasPrefix("{\"omacvm_progress\""), line.utf8.count <= 512,
              let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              (o["omacvm_progress"] as? NSNumber)?.intValue == 1,
              let phase = (o["phase"] as? String).flatMap(Phase.init(rawValue:))
        else { return nil }
        func count(_ k: String) -> Int? {
            guard let v = o[k] else { return 0 }
            guard let n = v as? NSNumber, n.doubleValue.rounded() == n.doubleValue,
                  n.int64Value >= 0, n.int64Value <= maxCount else { return nil }
            return n.intValue
        }
        func bytes(_ k: String) -> Int64? {
            guard let v = o[k] else { return 0 }
            guard let n = v as? NSNumber, n.doubleValue.rounded() == n.doubleValue,
                  n.int64Value >= 0, n.int64Value <= maxBytes else { return nil }
            return n.int64Value
        }
        guard let n = count("n"), let of = count("of"), n <= max(of, 0) || of == 0,
              let done = bytes("done"), let total = bytes("total") else { return nil }
        let now = (o["now"] as? String) ?? ""
        guard now.count <= 60, now.unicodeScalars.allSatisfy({
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " ._+@:-".unicodeScalars.contains($0))
        }) else { return nil }
        return ProgressUpdate(phase: phase, now: now, n: n, of: of,
                              done: total > 0 ? min(done, total) : done, total: total)
    }

    public init(phase: Phase, now: String, n: Int, of: Int, done: Int64, total: Int64) {
        self.phase = phase; self.now = now; self.n = n; self.of = of; self.done = done; self.total = total
    }

    /// The plain line: "Installing gum (27 of 190 packages)".
    public var text: String {
        let verb = phase == .download ? "Downloading" : "Installing"
        if now.isEmpty { return of > 0 ? "\(verb) packages (\(n) of \(of))" : verb }
        return of > 0 ? "\(verb) \(now) (\(n) of \(of) packages)" : "\(verb) \(now)"
    }

    /// 0...1 for the bar: bytes when known, else the package count.
    public var fraction: Double? {
        if total > 0 { return min(Double(done) / Double(total), 1) }
        if of > 0 { return min(Double(n) / Double(of), 1) }
        return nil
    }

    public var complete: Bool {
        if total > 0 && phase == .download { return done >= total }
        return of > 0 && n >= of
    }
}

/// Download speed, smoothed: an average over the last samples' window
/// (at most `window` seconds), so one slow second does not swing it.
public struct ByteRate: Sendable {
    public let window: TimeInterval
    private var samples: [(t: TimeInterval, bytes: Int64)] = []

    public init(window: TimeInterval = 8) { self.window = window }

    /// A new reading of how many bytes are there. A smaller value (a new file
    /// or a retry) starts over.
    public mutating func add(_ bytes: Int64, at t: TimeInterval) {
        if let last = samples.last, bytes < last.bytes || t < last.t { samples.removeAll() }
        samples.append((t, bytes))
        while let first = samples.first, samples.count > 2, t - first.t > window { samples.removeFirst() }
    }

    public mutating func reset() { samples.removeAll() }

    /// Bytes per second, once there are 2 s of readings.
    public var bytesPerSecond: Double? {
        guard let a = samples.first, let b = samples.last, b.t - a.t >= 2 else { return nil }
        return Double(b.bytes - a.bytes) / (b.t - a.t)
    }

    /// Seconds left for `total`, or nil while the speed is unknown or ~0.
    public func secondsLeft(total: Int64) -> Double? {
        guard let r = bytesPerSecond, r > 1024, let b = samples.last, total > b.bytes else { return nil }
        return Double(total - b.bytes) / r
    }
}

public enum BuildText {
    /// "412 MB", "1.4 GB" (decimal, as Finder).
    public static func bytes(_ b: Int64) -> String {
        let d = Double(b)
        if d >= 1e9 { return String(format: "%.1f GB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.0f MB", d / 1e6) }
        return String(format: "%.0f KB", d / 1e3)
    }

    /// "11.2 MB/s".
    public static func speed(_ bps: Double) -> String {
        bps >= 1e6 ? String(format: "%.1f MB/s", bps / 1e6) : String(format: "%.0f KB/s", bps / 1e3)
    }

    /// "12 s", "1 min 20 s", "14 min", "1 h 5 min".
    public static func duration(_ s: Double) -> String {
        let s = max(0, Int(s.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        if s < 3600 { return "\((s + 30) / 60) min" }
        let m = (s + 30) / 60
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// "about 3 min left", rounded so it does not jump every second.
    public static func left(_ s: Double) -> String {
        if s < 60 { return "less than a minute left" }
        if s < 600 { return "about \(Int((s / 60).rounded())) min left" }
        return "about \(Int((s / 300).rounded()) * 5) min left"
    }

    /// The heartbeat: "Working. Last output 4 s ago."
    public static func heartbeat(quietFor s: Double) -> String {
        if s < 3 { return "Working." }
        if s < 120 { return "Working. Last output \(Int(s)) s ago." }
        return "Still working. No output for \(duration(s)); this part can be quiet for a while."
    }

    /// A log line for the details view: raw lines lose their "| " mark,
    /// progress lines are left out, colour codes and other control
    /// characters go, at most 200 characters.
    public static func logLine(_ raw: String) -> String? {
        var l = raw
        if l.hasPrefix("| ") { l.removeFirst(2) }
        if l.hasPrefix("{\"omacvm_progress\"") || l.hasPrefix("OMACVM_CACHE ") { return nil }
        l = l.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        l = String(String.UnicodeScalarView(l.unicodeScalars.filter { $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) }))
        l = l.replacingOccurrences(of: "\t", with: "    ")
        if l.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return String(l.prefix(200))
    }

    /// The last `count` readable lines of a log's tail.
    public static func tail(_ data: Data, count: Int = 20) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
        if data.count >= 16384, !lines.isEmpty { lines.removeFirst() }   // cut in the middle
        return Array(lines.compactMap(logLine).suffix(count))
    }
}

/// How long each step usually takes, so a long one does not look stuck.
/// From a real build (2026-10-06, MacBook Air M2, 4 performance cores, the
/// live system cached, a fast line): 12 min in all, step 4 about 6 min, step 5
/// about 2, step 6 about 1.5, step 2 about 1. A Pro/Max chip (more than 4
/// performance cores; the base chips have 4) is quicker. Downloads depend on the line and show their own speed.
public enum StepTimes {
    public enum Route: String, Sendable { case build, prebuilt }

    /// (low, high) in seconds, or nil when there is no usual time.
    public static func usual(route: Route, step: Int, performanceCores: Int) -> (Double, Double)? {
        let fast = performanceCores > 4
        let f = fast ? 0.7 : 1.0
        let t: (Double, Double)?
        switch (route, step) {
        case (.build, 1): t = (30, 300)          // cached: unpack; else + 1.4 GB download
        case (.build, 2): t = (45, 240)          // pacstrap: ~180 packages
        case (.build, 3): t = (10, 60)
        case (.build, 4): t = (300, 1200)        // omarchy-mac: ~1100 packages
        case (.build, 5), (.prebuilt, 5): t = (60, 300)
        case (.build, 6), (.prebuilt, 6): t = (45, 240)   // Swift builds of the Mac helpers
        case (.build, 7), (.prebuilt, 7): t = (5, 60)
        case (.prebuilt, 1): t = (2, 20)
        case (.prebuilt, 2): t = nil             // the download shows its own time
        case (.prebuilt, 3): t = (60, 240)
        case (.prebuilt, 4): t = (60, 300)
        default: t = nil
        }
        return t.map { ($0.0 * f, $0.1 * f) }
    }

    /// Each step's time of the last finished build on this Mac (app settings).
    public static func remember(_ seconds: [Int: Double], route: Route, defaults: UserDefaults = .standard) {
        guard !seconds.isEmpty else { return }
        defaults.set(Dictionary(uniqueKeysWithValues: seconds.map { (String($0.key), $0.value) }),
                     forKey: "buildStepSeconds.\(route.rawValue)")
    }

    /// Not for a step with a download (build step 1, prebuilt step 2): a
    /// cached second build takes a fraction of the first one's time.
    public static func last(route: Route, step: Int, defaults: UserDefaults = .standard) -> Double? {
        if (route == .build && step == 1) || (route == .prebuilt && step == 2) { return nil }
        let d = defaults.dictionary(forKey: "buildStepSeconds.\(route.rawValue)") as? [String: Double]
        return d?[String(step)].flatMap { $0 > 0 && $0 < 86400 ? $0 : nil }
    }

    /// "usually 15-40 min on a Mac like this"
    public static func usualText(_ t: (Double, Double)) -> String {
        func m(_ s: Double) -> String { s < 60 ? "\(Int(s)) s" : "\(Int((s / 60).rounded())) min" }
        let (a, b) = (m(t.0), m(t.1))
        if a.hasSuffix(" s") && b.hasSuffix(" s") { return "usually \(a.dropLast(2))-\(b)" }
        if a.hasSuffix(" min") && b.hasSuffix(" min") { return "usually \(a.dropLast(4))-\(b)" }
        return "usually \(a) to \(b)"
    }
}
