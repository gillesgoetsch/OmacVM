import Foundation

/// GitHub's release downloads fail now and then for a moment: a 504 from the
/// latest/download redirect, a reset connection. Transfer tries such a fetch
/// at most twice more, after 2 s and then 6 s (or the server's Retry-After,
/// at most 30 s). Only server errors (HTTP 500-599), 429 and timeouts or lost
/// connections are tried again; never 404, 403, a refused redirect, a size
/// problem or a bad signature (those are checked after the fetch).
/// Retries keep to a time limit: the feed and its signature (each with a
/// 30 s request timeout) get no retry that would end its wait more than
/// `budget` (45 s) after the first try, so a feed that times out gives up
/// after about 62 s, not 98 s. The zip gets no retry after a try that ran
/// longer than `longestTry` (60 s): a late failure, and so the session's
/// 30-minute resource timeout, would start the whole zip again.
public struct FetchRetry: Sendable {
    /// The wait before each retry, in seconds; its count is the most retries.
    public var waits: [Double]
    /// A longer Retry-After is cut to this.
    public var maxRetryAfter: Double
    /// data(): no retry when the time since the first try plus the wait
    /// would pass this (seconds).
    public var budget: Double
    /// file(): no retry after a try that ran longer than this (seconds).
    public var longestTry: Double
    public var sleep: @Sendable (Double) async throws -> Void
    /// Seconds on a clock that only goes forward (tests bring their own).
    public var clock: @Sendable () -> Double

    public init(waits: [Double], maxRetryAfter: Double = 30, budget: Double = 45, longestTry: Double = 60,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
                clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.waits = waits; self.maxRetryAfter = maxRetryAfter; self.budget = budget; self.longestTry = longestTry
        self.sleep = sleep; self.clock = clock
    }

    /// The updater's: two retries, 2 s and 6 s apart.
    public static let standard = FetchRetry(waits: [2, 6])
    /// One try only.
    public static let never = FetchRetry(waits: [])

    /// A status worth another try: the server's own error, or too many requests.
    public static func retries(status: Int) -> Bool { status == 429 || (500...599).contains(status) }

    /// A transport error worth another try: a timeout or a lost connection.
    public static func retries(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return e.code == .timedOut || e.code == .networkConnectionLost
    }

    /// Seconds from a Retry-After header (seconds or an HTTP date); nil when
    /// there is none or it does not read.
    public static func retryAfter(_ value: String?, now: Date = Date()) -> Double? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if let s = Double(v), s.isFinite { return max(0, s) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: v).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// The wait before retry N (0 = the first): the server's Retry-After
    /// when it sent one (at most maxRetryAfter), else waits[N].
    public func wait(_ n: Int, retryAfter: Double?) -> Double {
        if let r = retryAfter { return min(r, maxRetryAfter) }
        return waits[min(n, waits.count - 1)]
    }

    /// Why a retry after WAIT would take too long, or nil when it fits.
    /// SINCEFIRST: seconds since the first try began; THISTRY: how long the
    /// failed try ran; WHOLE: a download (file()), else a fetch (data()).
    public func tooLong(wait: Double, sinceFirst: Double, thisTry: Double, whole: Bool) -> String? {
        if whole {
            return thisTry > longestTry
                ? String(format: "that try ran %.0f s and a retry would start the whole download again", thisTry) : nil
        }
        return sinceFirst + wait > budget
            ? String(format: "%.0f s since the first try, a retry would pass %.0f s", sinceFirst, budget) : nil
    }

    /// What the window and update.log say when the last try still got a
    /// server error or 429 (WHAT: "the update feed", "the download", ...);
    /// nil for any other status (the caller's own words).
    public static func problem(status: Int, what: String, url: URL) -> String? {
        let host = url.host ?? ""
        let who = host == "github.com" || host.hasSuffix(".github.com") ? "GitHub" : (host.isEmpty ? "the server" : host)
        if (500...599).contains(status) {
            return "\(who) answered HTTP \(status) (a server error on \(who)'s side) for \(what) at \(url.absoluteString); try again in a few minutes"
        }
        if status == 429 {
            return "\(who) answered HTTP 429 (too many requests) for \(what) at \(url.absoluteString); try again in a few minutes"
        }
        return nil
    }
}
