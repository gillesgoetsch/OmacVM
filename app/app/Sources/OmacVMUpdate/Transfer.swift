import Foundation

/// The updater's downloads: the feed and its signature into memory, the zip
/// straight into a file, each with its limit enforced while the bytes come
/// in (a server that says or sends more is cut off at once), and the zip's
/// progress for the Updates row. One session per check; redirects stay on
/// https (or http to this Mac, a test feed), as Appcast.isAllowedDownload.
/// A server error, 429, a timeout or a lost connection is tried again as
/// `retry` says (FetchRetry, within its time limits), each retry told to
/// `note`, and so is a retry left out for time.
public final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public enum Failure: LocalizedError, Equatable, CustomStringConvertible {
        /// More than the limit (said or sent).
        case tooLarge(String, Int64)
        /// The zip ended with another length than the feed names.
        case wrongLength(Int64, Int64)
        case redirect(String)
        case io(String)

        public var description: String {
            switch self {
            case .tooLarge(let name, let cap): "\(name) is larger than \(cap) bytes"
            case .wrongLength(let want, let got): "the download has the wrong size (\(got) bytes, the feed says \(want))"
            case .redirect(let to): "the download was sent on to \(to), which is not https"
            case .io(let why): why
            }
        }
        public var errorDescription: String? { description }
    }

    private final class Job {
        let name: String
        let cap: Int64
        /// The zip: exactly this many bytes.
        let exact: Int64?
        var data = Data()
        var file: FileHandle?
        var received: Int64 = 0
        var status = 0
        /// The answer's Retry-After header, if any.
        var retryAfter: String?
        var failure: Error?
        let progress: (@Sendable (Int64) -> Void)?
        var lastReport: Int64 = 0
        var continuation: CheckedContinuation<Int, Error>?

        init(name: String, cap: Int64, exact: Int64?, file: FileHandle?, progress: (@Sendable (Int64) -> Void)?) {
            self.name = name; self.cap = cap; self.exact = exact; self.file = file; self.progress = progress
        }
    }

    private var session: URLSession!
    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    /// The delegate's queue: one at a time, in order.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    private let retry: FetchRetry
    private let note: @Sendable (String) async -> Void

    public init(configuration: URLSessionConfiguration, retry: FetchRetry = .never,
                note: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.retry = retry
        self.note = note
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// Lets the running tasks end; the session lets go of this object.
    public func finish() { session.finishTasksAndInvalidate() }

    /// GET into memory, at most `cap` bytes. A status other than 200 comes
    /// back with no data (the body is not read).
    public func data(_ url: URL, cap: Int) async throws -> (Data, Int) {
        try await retrying(url, whole: false) {
            let job = Job(name: url.lastPathComponent, cap: Int64(cap), exact: nil, file: nil, progress: nil)
            let status = try await self.run(url, job)
            return ((status == 200 ? job.data : Data(), status), status, job.retryAfter)
        }
    }

    /// GET into FILE (made new), exactly `length` bytes. progress: bytes so
    /// far, about every 256 KB. The HTTP status; on a failure the file is gone.
    public func file(_ url: URL, to file: URL, length: Int64,
                     progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Int {
        try await retrying(url, whole: true) {
            let (status, after) = try await self.fileOnce(url, to: file, length: length, progress: progress)
            return (status, status, after)
        }
    }

    private func fileOnce(_ url: URL, to file: URL, length: Int64,
                          progress: (@Sendable (Int64) -> Void)?) async throws -> (Int, String?) {
        let fm = FileManager.default
        try? fm.removeItem(at: file)
        guard fm.createFile(atPath: file.path, contents: nil), let h = try? FileHandle(forWritingTo: file) else {
            throw Failure.io("cannot write \(file.path)")
        }
        let job = Job(name: url.lastPathComponent, cap: length, exact: length, file: h, progress: progress)
        do {
            let status = try await run(url, job)
            try? h.close()
            if status != 200 { try? fm.removeItem(at: file) }
            return (status, job.retryAfter)
        } catch {
            try? h.close()
            try? fm.removeItem(at: file)
            throw error
        }
    }

    /// ONCE tried again while its status (or its error) is worth it,
    /// retries are left and the retry fits the time limits (WHOLE: a
    /// download, FetchRetry.tooLong); each retry is told to `note` first.
    private func retrying<T>(_ url: URL, whole: Bool, _ once: () async throws -> (T, Int, String?)) async throws -> T {
        let first = retry.clock()
        var n = 0
        while true {
            let began = retry.clock()
            let outcome: Result<T, Error>
            var status = 0, after: String?
            do {
                let r = try await once()
                outcome = .success(r.0); status = r.1; after = r.2
            } catch {
                outcome = .failure(error)
            }
            let wait: Double, why: String
            switch outcome {
            case .success(let result):
                guard FetchRetry.retries(status: status), n < retry.waits.count else { return result }
                wait = retry.wait(n, retryAfter: FetchRetry.retryAfter(after))
                why = "HTTP \(status)"
            case .failure(let error):
                guard FetchRetry.retries(error), n < retry.waits.count else { throw error }
                wait = retry.wait(n, retryAfter: nil)
                why = error.localizedDescription
            }
            let now = retry.clock()
            if let late = retry.tooLong(wait: wait, sinceFirst: now - first, thisTry: now - began, whole: whole) {
                await note("\(url.absoluteString): \(why); not tried again: \(late)")
                return try outcome.get()
            }
            n += 1
            await note(String(format: "%@: %@; trying again in %.0f s (retry %d of %d)", url.absoluteString, why, wait, n, retry.waits.count))
            try await retry.sleep(wait)
        }
    }

    private func run(_ url: URL, _ job: Job) async throws -> Int {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
                let task = session.dataTask(with: url)
                job.continuation = c
                lock.withLock { jobs[task.taskIdentifier] = job }
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.session.getAllTasks { for t in $0 { t.cancel() } }
        }
    }

    private func job(_ task: URLSessionTask) -> Job? { lock.withLock { jobs[task.taskIdentifier] } }

    /// Ends the task with FAILURE (once); the rest of its bytes are dropped.
    private func fail(_ task: URLSessionTask, _ job: Job, _ failure: Error) {
        guard job.failure == nil else { return }
        job.failure = failure
        task.cancel()
    }

    // MARK: URLSessionDataDelegate (on `queue`)

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let to = request.url, Appcast.isAllowedDownload(to) else {
            if let j = job(task) { fail(task, j, Failure.redirect(request.url?.absoluteString ?? "?")) }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let j = job(dataTask) else { completionHandler(.cancel); return }
        j.status = (response as? HTTPURLResponse)?.statusCode ?? 0
        j.retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
        // Not 200: the caller says why; the body is not needed.
        guard j.status == 200 else { completionHandler(.cancel); return }
        let said = response.expectedContentLength
        if said > j.cap {
            fail(dataTask, j, Failure.tooLarge(j.name, j.cap))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let j = job(dataTask), j.failure == nil else { return }
        j.received += Int64(data.count)
        guard j.received <= j.cap else {
            fail(dataTask, j, Failure.tooLarge(j.name, j.cap))
            return
        }
        if let h = j.file {
            do { try h.write(contentsOf: data) } catch { fail(dataTask, j, Failure.io("cannot write the download: \(error.localizedDescription)")); return }
        } else {
            j.data.append(data)
        }
        if let p = j.progress, j.received - j.lastReport >= 256 * 1024 || j.received == j.exact {
            j.lastReport = j.received
            p(j.received)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let j = lock.withLock({ jobs.removeValue(forKey: task.taskIdentifier) }), let c = j.continuation else { return }
        j.continuation = nil
        if let f = j.failure { c.resume(throwing: f); return }
        // Cancelled by didReceive(response:) for a status other than 200.
        if j.status != 200, j.status != 0 { c.resume(returning: j.status); return }
        if let error { c.resume(throwing: error); return }
        if let want = j.exact, j.received != want { c.resume(throwing: Failure.wrongLength(want, j.received)); return }
        c.resume(returning: j.status)
    }
}
