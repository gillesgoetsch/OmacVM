import AppKit
import OmacVMUpdate

/// OmacVM.app updates itself (docs/adr/0033).
///
/// Once a week (unless update checks are off, the setting shared with the
/// control centre) it fetches OmacVM-appcast.json and its Ed25519 signature
/// from the latest GitHub release. A newer version is downloaded, checked
/// (size and SHA-256 from the signed feed, then the unpacked app: same bundle
/// id, same version as the feed, a Developer ID of a team the feed names
/// ("devid_teams") for the app and its QEMU) and kept ready. The feed is
/// valid when signed by either release key (ReleaseKeys: the main one, the
/// spare, or a spare a signed feed named since). The window then offers it; nothing is
/// replaced while a VM runs from this app or one is being built.
///
/// Installing hands over to update-swap.sh (copied out of the bundle first):
/// it waits for this app to quit, keeps it as the previous version, puts the
/// new one in its place and starts it with --update-check. The new app checks
/// that its QEMU starts and writes a marker; without one within 90 s the
/// script puts the previous version back and the version is skipped. The
/// previous version stays for one step back (menu: Go Back to ...).
///
/// Its files, per copy of the app (UpdateFolders: two copies with one
/// bundle id keep their own): ~/Library/Application Support/OmacVM/Updates/
/// <bundle id>/<app name>-<hash of its path>/ (staged/, previous/,
/// update.log, the state files below). An app on another volume keeps
/// previous/ and incoming/ next to itself (.omacvm-updates/), so the swap
/// stays renames on one volume. Tests: OMACVM_APPCAST_URL,
/// OMACVM_APPCAST_KEY (test keys, space-separated), OMACVM_SETTINGS_DIR;
/// only test builds (another bundle id) read them (TestHooks).
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Staged: Equatable {
        let version: String
        let app: URL
        let notes: URL?
        /// From the signed feed kept next to it.
        let teams: [String]
    }

    @Published private(set) var staged: Staged?
    @Published private(set) var checking = false
    @Published var notice: String?
    @Published private(set) var enabled: Bool

    /// Why the app cannot be replaced right now (a VM runs, a VM is being
    /// built), from the app delegate.
    var busyReason: () -> String? = { nil }

    let settings = SharedSettings.standard
    let bundle = Bundle.main.bundleURL.standardizedFileURL
    let bundleID = Bundle.main.bundleIdentifier ?? "org.omacvm.app"
    let home: URL
    /// previous/ and incoming/: on the app's volume (UpdateFolders.work).
    let work: URL
    private var timer: Timer?

    /// Per bundle id (a test build keeps its own) and per copy.
    nonisolated static var homeFolder: URL {
        Paths.appSupport.appendingPathComponent("Updates/\(Bundle.main.bundleIdentifier ?? "org.omacvm.app")")
            .appendingPathComponent(UpdateFolders.key(for: Bundle.main.bundleURL))
    }

    static let defaultFeed = "https://github.com/gillesgoetsch/omacvm/releases/latest/download/OmacVM-appcast.json"

    private init() {
        home = Self.homeFolder
        work = UpdateFolders.work(for: bundle, home: home)
        enabled = SharedSettings.standard.updateChecks
    }

    // MARK: - what this copy can do

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var feedURL: URL {
        let hook = TestHooks.value("OMACVM_APPCAST_URL", bundleID: bundleID).flatMap(URL.init(string:))
        return hook ?? URL(string: Self.defaultFeed)!
    }

    /// The release keys' public halves: src/lib/release-key.pub and
    /// release-key-spare.pub in the app (inside the signed bundle), or
    /// OMACVM_APPCAST_KEY in a test build. Plus the spares signed feeds named,
    /// kept next to the shared settings.
    var keys: ReleaseKeys {
        let shipped: [String]
        if let k = TestHooks.value("OMACVM_APPCAST_KEY", bundleID: bundleID) {
            shipped = k.split(separator: " ").map(String.init)
        } else {
            shipped = ["release-key.pub", "release-key-spare.pub"].compactMap { name in
                let url = Paths.resources.appendingPathComponent(Mac.omacvmSrc + "/lib/" + name)
                return (try? String(contentsOf: url, encoding: .utf8)).flatMap { ReleaseKeys.key($0) != nil ? $0 : nil }
            }
        }
        return ReleaseKeys(shipped: shipped, store: settings.releaseKeysFolder)
    }

    /// nil when this copy can update itself, else why not.
    var unavailableReason: String? {
        if keys.shipped.isEmpty { return "This build has no release key yet: updates start with a release that has one." }
        if Version(currentVersion) == nil { return "This build (\(currentVersion)) is not a release version." }
        if ProcessInfo.processInfo.environment["OMACVM_RESOURCES"] != nil { return "Updates are off when run from the source tree." }
        if bundle.path.contains("/AppTranslocation/") {
            return "macOS runs this copy from a temporary place. Move \(Product.name) to Applications first."
        }
        if let p = writeProblem { return p }
        return nil
    }

    /// The bundle or its folder belongs to someone else (installed by root or
    /// another admin): this copy cannot replace itself.
    var writeProblem: String? {
        UpdatePolicy.writeProblem(bundle: bundle).map {
            "\(Product.name) cannot update itself here: \($0) (installed by another user or an administrator). Reinstall it as you to get updates."
        }
    }

    /// Said once (window and log), not as a failed swap every week; again
    /// only if the problem changes or comes back after it was fixed.
    private func tellWriteProblemOnce() {
        guard let why = writeProblem else { writeProblemSaid = nil; return }
        guard enabled, writeProblemSaid != why else { return }
        writeProblemSaid = why
        notice = why
        log(why)
    }

    // MARK: - state, one small file each in this copy's folder

    private func state(_ name: String) -> String? {
        let v = (try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v?.isEmpty == false ? v : nil
    }

    private func setState(_ name: String, _ value: String?) {
        let f = home.appendingPathComponent(name)
        guard let value else { try? FileManager.default.removeItem(at: f); return }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? Data((value + "\n").utf8).write(to: f, options: .atomic)
    }

    /// last-check: when the feed last answered (ISO 8601).
    private var lastCheck: Date? {
        get { state("last-check").flatMap { ISO8601DateFormatter().date(from: $0) } }
        set { setState("last-check", newValue.map { ISO8601DateFormatter().string(from: $0) }) }
    }

    /// skip: the version skipped by hand, or that did not start here.
    private var skipped: String? {
        get { state("skip") }
        set { setState("skip", newValue) }
    }

    private var writeProblemSaid: String? {
        get { state("write-problem-said") }
        set { setState("write-problem-said", newValue) }
    }

    /// app: where this copy is. Folders of copies that are gone (moved or
    /// deleted) for 30 days go, with what they kept.
    private func noteCopy() {
        setState("app", Running.realPath(bundle))
        let fm = FileManager.default
        let root = home.deletingLastPathComponent()
        let month = Date().addingTimeInterval(-30 * 24 * 3600)
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where dir.lastPathComponent != home.lastPathComponent {
            let f = dir.appendingPathComponent("app")
            guard let path = (try? String(contentsOf: f, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  path.hasPrefix("/"),
                  let seen = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date, seen < month else { continue }
            let app = URL(fileURLWithPath: path)
            let elsewhere = app.deletingLastPathComponent().appendingPathComponent(".omacvm-updates/\(dir.lastPathComponent)")
            // Still there, or in the middle of a swap (moved aside for a moment).
            guard BundleInfo.read(app)?.identifier != bundleID,
                  ![dir, elsewhere].contains(where: { fm.fileExists(atPath: $0.appendingPathComponent("incoming").path) }) else { continue }
            try? fm.removeItem(at: elsewhere)
            try? fm.removeItem(at: dir)
            log("removed the update folder of \(path) (gone for 30 days)")
        }
    }

    var previousApp: URL? {
        let p = work.appendingPathComponent("previous/\(bundle.lastPathComponent)")
        return BundleInfo.read(p) == nil ? nil : p
    }

    /// The kept previous version, when it is older than this one (after a
    /// step back the newer one is kept instead: not offered as "back").
    var previousVersion: String? {
        if let shownPrevious { return shownPrevious }
        guard let p = previousApp, let v = BundleInfo.read(p)?.version,
              let pv = Version(v), let cv = Version(currentVersion), pv < cv else { return nil }
        return v
    }

    // MARK: - start

    /// An install asked for in an earlier run that had to wait (a VM ran):
    /// at launch it goes in now, waits until nothing runs from the app (the
    /// launch starts a VM), or is left to --update-now.
    enum Pending { case installNow, waitUntilIdle, leave }

    /// At launch, after the one-launcher-at-a-time check.
    func start(pending: Pending) {
        trimLog()
        noteCopy()
        readSwapResult()
        if !keys.shipped.isEmpty, notice == nil { tellWriteProblemOnce() }
        Task {
            await loadStaged()
            resumePending(pending)
        }
        // Not right away: a VM start or the first window comes first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    func setEnabled(_ on: Bool) {
        do {
            try settings.setUpdateChecks(on)
            enabled = on
            log("update checks \(on ? "on" : "off")")
        } catch {
            notice = "Could not save the setting: \(error.localizedDescription)"
        }
    }

    private func checkIfDue() {
        enabled = settings.updateChecks
        guard enabled, unavailableReason == nil, !checking,
              UpdatePolicy.isDue(lastCheck: lastCheck, now: Date()) else { return }
        Task { _ = await check(manual: false) }
    }

    // MARK: - check, download, verify

    enum Outcome: Equatable {
        case ready(String), upToDate, skipped(String), needsMacOS(String, String), failed(String)
    }

    /// Fetches and verifies the feed; a newer version is downloaded and
    /// checked. Automatic checks stay off metered and Low Data networks.
    /// keepSkip: a skipped version stays skipped also when asked by hand
    /// (the VM's control centre: a version that did not start here must not
    /// shut its VM down again and again).
    func check(manual: Bool, keepSkip: Bool = false) async -> Outcome {
        if let why = unavailableReason { return .failed(why) }
        guard !checking, let current = Version(currentVersion) else { return .failed("A check is running.") }
        let keys = keys
        checking = true
        defer { checking = false }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30 * 60
        config.allowsExpensiveNetworkAccess = manual
        config.allowsConstrainedNetworkAccess = manual
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let feed: Appcast, feedData: Data, feedSig: Data
        do {
            let (raw, code) = try await fetch(feedURL, cap: Appcast.maxFeedBytes, session: session)
            // The server answered: the week starts again even without a feed
            // (no release has one yet), so nobody asks every hour.
            lastCheck = Date()
            guard code == 200 else { return failed("no update feed (HTTP \(code)) at \(feedURL.absoluteString)") }
            let (sig, scode) = try await fetch(feedURL.appendingPathExtension("sig"), cap: Appcast.maxSignatureBytes, session: session)
            guard scode == 200 else { return failed("the update feed has no signature (HTTP \(scode))") }
            switch Appcast.verified(feed: raw, signature: sig, keys: keys) {
            case .success(let f): feed = f; feedData = raw; feedSig = sig
            case .failure(let p): return failed(p.description)
            }
        } catch {
            return failed("no connection to the update feed (\(error.localizedDescription))")
        }

        // A new spare named by the feed: trusted from now on; a key it revokes: not any more.
        if let r = keys.remember(feedData, signature: feedSig) {
            for k in r.named { log("the update feed names a new spare release key: \(k)") }
            for k in r.revoked { log("the update feed revokes the release key \(k)") }
        }

        let os = Version(ProcessInfo.processInfo.operatingSystemVersion)
        // Asked for by hand: a skipped version is offered again.
        switch UpdatePolicy.offer(feed, current: current, skipped: manual && !keepSkip ? nil : skipped, os: os) {
        case .upToDate:
            log("checked: \(currentVersion) is current (feed \(feed.version))")
            return .upToDate
        case .skipped:
            log("checked: \(feed.version) is skipped")
            return .skipped(feed.version.description)
        case .needsMacOS(let m):
            log("checked: \(feed.version) needs macOS \(m)")
            return .needsMacOS(feed.version.description, m)
        case .newer:
            break
        }
        if let s = staged, s.version == feed.version.description { return .ready(s.version) }
        log("downloading \(feed.version) from \(feed.url.absoluteString)")
        do {
            let s = try await stage(feed, data: feedData, signature: feedSig, session: session)
            staged = s
            log("ready: \(s.version) at \(s.app.path)")
            return .ready(s.version)
        } catch {
            return failed("\(feed.version) was not installed: \(error.localizedDescription)")
        }
    }

    private func failed(_ why: String) -> Outcome {
        log("check: \(why)")
        return .failed(why)
    }

    private func fetch(_ url: URL, cap: Int, session: URLSession) async throws -> (Data, Int) {
        let (bytes, response) = try await session.bytes(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { return (Data(), code) }
        var data = Data()
        for try await b in bytes {
            data.append(b)
            if data.count > cap { throw HelperError.io("\(url.lastPathComponent) is larger than \(cap) bytes") }
        }
        return (data, code)
    }

    private var stagedRoot: URL { home.appendingPathComponent("staged") }

    /// Downloads to staged/VERSION, checks size and digest, unpacks, checks
    /// the app. Anything that fails leaves nothing behind. The signed feed is
    /// kept there too: a later launch checks it again for the teams.
    private func stage(_ feed: Appcast, data: Data, signature: Data, session: URLSession) async throws -> Staged {
        let fm = FileManager.default
        try? fm.removeItem(at: stagedRoot)
        let dir = stagedRoot.appendingPathComponent(feed.version.description)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let (tmp, response) = try await session.download(from: feed.url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let zip = dir.appendingPathComponent("update.zip")
            try fm.moveItem(at: tmp, to: zip)
            guard code == 200 else { throw HelperError.io("the download failed (HTTP \(code))") }
            let id = bundleID
            let app = try await Task.detached { () throws -> URL in
                guard Files.size(zip) == feed.length else { throw HelperError.io("the download has the wrong size") }
                guard try Files.sha256(zip) == feed.sha256 else { throw HelperError.io("the download does not match its checksum") }
                let x = dir.appendingPathComponent("x")
                guard Updater.run("/usr/bin/ditto", ["-x", "-k", zip.path, x.path]) == 0 else {
                    throw HelperError.io("the download does not unpack")
                }
                try? FileManager.default.removeItem(at: zip)
                guard let app = Files.singleApp(in: x) else { throw HelperError.io("the download holds no single app") }
                try Updater.verifyApp(app, id: id, version: feed.version, teams: feed.teams)
                return app
            }.value
            try data.write(to: dir.appendingPathComponent("feed.json"))
            try signature.write(to: dir.appendingPathComponent("feed.json.sig"))
            if let n = feed.notesURL { try? Data(n.absoluteString.utf8).write(to: dir.appendingPathComponent("notes")) }
            return Staged(version: feed.version.description, app: app, notes: feed.notesURL, teams: feed.teams)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// The checks before an app may replace this one: our bundle id, the
    /// version the signed feed named, a Developer ID of a team it named on
    /// the app and on its QEMU (the part with the Hypervisor entitlement).
    nonisolated static func verifyApp(_ app: URL, id: String, version: Version, teams: [String]) throws {
        guard let info = BundleInfo.read(app) else { throw HelperError.io("the new app has no Info.plist") }
        guard info.identifier == id else { throw HelperError.io("the new app is \(info.identifier), not \(id)") }
        guard Version(info.version) == version else {
            throw HelperError.io("the new app says \(info.version), the feed \(version)")
        }
        guard CodeCheck.teams(teams) != nil else { throw HelperError.io("the update feed names no Developer ID team") }
        let req = CodeCheck.developerID(teams: teams)
        if let p = CodeCheck.problem(app, requirement: req) { throw HelperError.io(p) }
        let qemu = app.appendingPathComponent("Contents/Resources/runtime/bin/OmacVM")
        if let p = CodeCheck.problem(qemu, requirement: req) { throw HelperError.io(p) }
    }

    /// A staged update from an earlier check, checked again.
    private func loadStaged() async {
        guard let current = Version(currentVersion),
              let dirs = try? FileManager.default.contentsOfDirectory(at: stagedRoot, includingPropertiesForKeys: nil) else { return }
        let id = bundleID, skip = skipped.flatMap(Version.init), keys = keys
        for dir in dirs {
            // The feed it came with, checked again: the teams come from it.
            let feed = (try? Data(contentsOf: dir.appendingPathComponent("feed.json"))).flatMap { d in
                (try? Data(contentsOf: dir.appendingPathComponent("feed.json.sig"))).flatMap { s in
                    try? Appcast.verified(feed: d, signature: s, keys: keys).get()
                }
            }
            guard let v = Version(dir.lastPathComponent), current < v, skip.map({ $0 < v }) ?? true,
                  let feed, feed.version == v,
                  let app = Files.singleApp(in: dir.appendingPathComponent("x")),
                  (try? await Task.detached { try Updater.verifyApp(app, id: id, version: v, teams: feed.teams) }.value) != nil else {
                try? FileManager.default.removeItem(at: dir)
                continue
            }
            let notes = (try? String(contentsOf: dir.appendingPathComponent("notes"), encoding: .utf8))
                .flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            staged = Staged(version: v.description, app: app, notes: notes, teams: feed.teams)
        }
    }

    func skip() {
        guard let s = staged else { return }
        stopWaiting()
        skipped = s.version
        try? FileManager.default.removeItem(at: stagedRoot)
        staged = nil
        log("skipped \(s.version)")
    }

    // MARK: - install and go back

    /// Asked to install while a VM runs: done once nothing runs from the app.
    /// Checked when this launcher's VM ends (any exit status), every 30 s
    /// while the app is open (a VM started by the CLI, or by a launcher that
    /// crashed, has no runner here) and at the next launch (the request is
    /// kept in the file install-pending).
    @Published private(set) var installWhenIdle = false
    private var idleTimer: Timer?
    private var swapping = false

    private var pendingInstall: String? {
        get { state("install-pending") }
        set { setState("install-pending", newValue) }
    }

    private func waitUntilIdle(_ version: String) {
        installWhenIdle = true
        pendingInstall = version
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.installWhenIdle, self.busyNow == nil else { return }
                self.log("nothing runs from the app any more")
                self.install()
            }
        }
    }

    private func stopWaiting() {
        installWhenIdle = false
        pendingInstall = nil
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func resumePending(_ mode: Pending) {
        guard mode != .leave, let v = pendingInstall else { return }
        guard let s = staged, s.version == v else {
            log("the install of \(v) asked for earlier: no longer ready, dropped")
            pendingInstall = nil
            return
        }
        log("the install of \(v) asked for earlier: \(mode == .installNow ? "now" : "once nothing runs from the app")")
        if mode == .installNow { install() } else { waitUntilIdle(v) }
    }

    /// A VM that runs from this app (or is being built): not now.
    var busyNow: String? {
        if let b = busyReason() { return b }
        if !Running.pids(inside: bundle).isEmpty { return "A VM runs from \(Product.name)" }
        return nil
    }

    /// Installs the staged update, or once the VM has shut down when one
    /// runs. quit false: the caller quits by itself. quiet: the user just
    /// quit or shut the VM down, so the new version only checks that it
    /// starts and opens no window (the next launch says it updated).
    func install(quit: Bool = true, quiet: Bool = false) {
        guard !swapping else { return }
        guard let s = staged else { stopWaiting(); return }
        if let why = busyNow {
            waitUntilIdle(s.version)
            notice = Self.waitingNotice(why, version: s.version)
            log("install \(s.version) deferred: \(why)")
            return
        }
        stopWaiting()
        if let why = unavailableReason { notice = why; return }
        guard let v = Version(s.version) else { return }
        // A copy on the app's volume (a clone on APFS; a real copy when the
        // app lies on another disk), checked there: what gets renamed into
        // place is what was verified. The staged one stays for another try.
        let incoming = work.appendingPathComponent("incoming/\(bundle.lastPathComponent)")
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: incoming.deletingLastPathComponent())
            try fm.createDirectory(at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: s.app, to: incoming)
        } catch {
            try? fm.removeItem(at: incoming.deletingLastPathComponent())
            notice = "Could not prepare the update: \(error.localizedDescription)"
            log("install: \(error.localizedDescription)")
            return
        }
        do {
            try Updater.verifyApp(incoming, id: bundleID, version: v, teams: s.teams)
        } catch {
            try? fm.removeItem(at: incoming.deletingLastPathComponent())
            try? fm.removeItem(at: stagedRoot)
            staged = nil
            notice = "The downloaded update no longer checks out: it was removed. The next check downloads it again."
            log("install: the copy at \(incoming.path) does not check out (\(error.localizedDescription))")
            return
        }
        log("install \(s.version): copied to \(incoming.path) and checked")
        // Into the name of this copy (users pick the app's name at install):
        // a renamed copy is signed again ad hoc, as the installer does.
        do {
            if let mine = BundleInfo.read(bundle)?.name, BundleInfo.read(incoming)?.name != mine {
                try rename(incoming, to: mine)
            }
        } catch {
            try? fm.removeItem(at: incoming.deletingLastPathComponent())
            notice = "Could not prepare the update: \(error.localizedDescription)"
            log("install: \(error.localizedDescription)")
            return
        }
        swap(mode: "install", new: incoming, quit: quit, quiet: quiet)
    }

    /// --update-now (scripts, tests): check as if asked by hand and install
    /// what is found: now, or once the VM has shut down. Shows nothing;
    /// update.log says what happened. A hidden launcher started just for
    /// this does not stay to wait: the request is kept for the next launch.
    func runScripted(quitWhenDone: Bool) async {
        let outcome = await check(manual: true)
        log("--update-now: \(outcome)")
        if case .ready = outcome { install() }
        guard quitWhenDone else { return }
        if installWhenIdle {
            log("--update-now: not waiting hidden; the install goes in at the next launch once nothing runs from the app")
        }
        NSApp.terminate(nil)
    }

    private func rename(_ app: URL, to name: String) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any] else {
            throw HelperError.io("Info.plist is unreadable")
        }
        info["CFBundleName"] = name
        info["CFBundleDisplayName"] = name
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        guard Updater.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", bundleID,
                                                "-r=designated => identifier \"\(bundleID)\"", app.path]) == 0 else {
            throw HelperError.io("could not sign the renamed app")
        }
    }

    func goBack() {
        guard previousVersion != nil else { return }
        if let why = busyNow ?? unavailableReason { notice = why; return }
        swap(mode: "rollback", new: nil, quit: true, quiet: false)
    }

    /// Starts update-swap.sh from a copy outside the bundle (bash reads a
    /// script as it runs: the one in the bundle is about to move) and quits.
    private func swap(mode: String, new: URL?, quit: Bool, quiet: Bool) {
        let script = home.appendingPathComponent("update-swap.sh")
        let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        do {
            try? FileManager.default.removeItem(at: script)
            try FileManager.default.copyItem(at: Paths.scripts.appendingPathComponent("update-swap.sh"), to: script)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, mode, bundle.path, new?.path ?? "-", home.path,
                           String(ProcessInfo.processInfo.processIdentifier), token, "--work", work.path]
                + (quiet ? ["--quiet"] : [])
            guard let log = appendHandle() else { throw HelperError.io("cannot write \(logFile.path)") }
            p.standardOutput = log
            p.standardError = log
            p.standardInput = FileHandle.nullDevice
            try p.run()
        } catch {
            notice = "Could not start the update: \(error.localizedDescription)"
            self.log("swap: \(error.localizedDescription)")
            return
        }
        swapping = true
        log("\(mode): handing over to update-swap.sh\(quiet ? " (quiet: no window after)" : ""), quitting")
        if quit { NSApp.terminate(nil) }
    }

    // MARK: - after a swap

    /// --update-check TOKEN: started by update-swap.sh after a swap. QEMU
    /// must start (it loads all its libraries); the marker tells the script.
    /// Without "ok" the script puts the previous version back.
    static func launchCheck(token: String) {
        guard token.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { exit(2) }
        try? FileManager.default.createDirectory(at: homeFolder, withIntermediateDirectories: true)
        let marker = homeFolder.appendingPathComponent("launch-\(token)")
        let status = run(Paths.qemu.path, ["--version"], timeout: 20)
        let ok = status == 0
        try? Data((ok ? "ok\n" : "fail: QEMU does not start (status \(status))\n").utf8).write(to: marker)
        if !ok { exit(1) }
    }

    /// update-swap.sh leaves `result` with "installed OLD NEW" or
    /// "rolled-back NEW REASON...". The version that did not start is
    /// skipped from then on.
    private func readSwapResult() {
        let file = home.appendingPathComponent("result")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        let f = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
        guard f.count >= 2 else { return }
        if f[0] == "rolled-back" || f[0] == "went-back", Version(f[1]) != nil { skipped = f[1] }
        notice = Self.resultNotice(f, current: currentVersion, previous: previousVersion) ?? notice
    }

    /// What the window says about the swap's result line (split in three).
    static func resultNotice(_ f: [String], current: String, previous: String?) -> String? {
        guard f.count >= 2 else { return nil }
        switch f[0] {
        case "installed":
            let back = previous.map { " If something is wrong: \(Product.name) › Go Back to \(Product.name) \($0)…" } ?? ""
            return "Updated to \(current).\(back)"
        case "rolled-back":
            return "\(f[1]) did not start: \(f.count > 2 ? f[2] : "no answer"). This is \(current) again; \(f[1]) is skipped until a later version comes out."
        case "went-back":
            return "Back to \(current). \(f[1]) is skipped until a later version comes out."
        case "aborted":
            return "The update did not run: \(f.dropFirst().joined(separator: " "))."
        default:
            return nil
        }
    }

    /// The notice while an update waits for the VM.
    static func waitingNotice(_ why: String, version: String) -> String {
        "\(why): \(Product.name) \(version) goes in once it has shut down."
    }

    // MARK: - Check Now (the window and the menu)

    /// The last check asked for by hand in this session: the window shows it,
    /// also with weekly checks off (a check by hand always works).
    @Published private(set) var lastOutcome: Outcome?

    @discardableResult
    func checkNow(keepSkip: Bool = false) async -> Outcome {
        let o = await check(manual: true, keepSkip: keepSkip)
        lastOutcome = o
        return o
    }

    /// The line under Check Now for a check by hand (nil: the banner says it).
    static func outcomeLine(_ o: Outcome, current: String) -> String? {
        switch o {
        case .ready: return nil
        case .upToDate: return "\(Product.name) \(current) is the newest version."
        case .skipped(let v): return "\(Product.name) \(v) is skipped."
        case .needsMacOS(let v, let m): return "\(Product.name) \(v) needs macOS \(m). This Mac stays on \(current)."
        case .failed(let why): return sentence(why)
        }
    }

    /// A reason from the log ("no connection to ...") as a sentence.
    static func sentence(_ why: String) -> String {
        why.prefix(1).uppercased() + why.dropFirst() + (why.hasSuffix(".") ? "" : ".")
    }

    // MARK: - update with a VM restart (docs/adr/0033)
    //
    // The VM this launcher runs shuts down cleanly, the app updates and
    // restarts, then starts the VM again. From the window, the menu, or the
    // VM's control centre (POST /omacvm/app-update through the relay,
    // NativeControlBridge). The state file restart-vm names the VM; the new
    // app (or the old one after a rollback) starts it once, if it is fresh.
    // A VM that does not shut down in time stops the update: nothing forced
    // without a second confirm on the Mac.

    /// From the app delegate: the VM this launcher runs, and its controls.
    var runningVM: () -> (folder: URL, name: String)? = { nil }
    var powerDownVM: () -> Void = {}
    var forceStopVM: () -> Void = {}
    var startVMAgain: (URL) -> Void = { _ in }
    /// Why no restart-update can start now (a build, a disk move, a quit).
    var restartBlocker: () -> String? = { nil }

    /// A restart-update runs (from the check to the swap).
    @Published private(set) var restarting = false
    private var restartTimer: Timer?
    private var restartPolls = 0

    /// Checks (as by hand: the signed feed, the download, the Developer ID)
    /// and, when an update is ready, notes the VM to start again. The VM is
    /// not touched yet: shutDownForRestart does that. vmName: the VM that
    /// asked (the relay), which must be the one this launcher runs.
    func prepareRestart(vmName: String?) async -> RestartCheck {
        if let why = unavailableReason { return .cannot(why) }
        if restarting || swapping { return .busy("an update runs") }
        if checking { return .busy("a check for updates runs") }
        if let why = restartBlocker() { return .busy(why) }
        guard let vm = runningVM(), vmName.map({ $0 == vm.name }) ?? true else {
            return .busy("this VM does not run from this \(Product.name)")
        }
        restarting = true
        // From the VM: a skipped version (by hand, or it did not start here) stays skipped.
        let outcome = await checkNow(keepSkip: vmName != nil)
        switch outcome {
        case .ready(let v):
            guard runningVM()?.folder == vm.folder else {
                restarting = false
                return .busy("the VM stopped")
            }
            stopWaiting()   // an install waiting for the shutdown: this one takes over
            setState("restart-vm", RestartVM(folder: vm.folder.path, version: v, at: Date()).line)
            log("restart-update \(v) for \(vm.name): ready")
            return .ready(v)
        case .upToDate:
            restarting = false
            return .upToDate(currentVersion)
        case .skipped(let v):
            restarting = false
            return .cannot("OmacVM.app \(v) is skipped on this Mac (it did not start here, or was skipped by hand)")
        case .needsMacOS(let v, let m):
            restarting = false
            return .needsMacOS(v, m)
        case .failed(let why):
            restarting = false
            return .failed(why)
        }
    }

    /// The VM shuts down cleanly (power button, then the guest agent); the
    /// install follows when it has ended (vmEndedForRestart).
    func shutDownForRestart() {
        // The VM may have ended in the few seconds before this (shut down in
        // it): vmEndedForRestart took over, and its timer must keep running.
        guard restarting, runningVM() != nil else { return }
        log("restart-update: shutting the VM down")
        powerDownVM()
        restartTimer?.invalidate()
        // Test builds: OMACVM_RESTART_TIMEOUT (seconds) for the timeout path.
        let timeout = TestHooks.value("OMACVM_RESTART_TIMEOUT", bundleID: bundleID).flatMap(TimeInterval.init) ?? RestartVM.shutdownTimeout
        restartTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdownTimedOut(after: timeout) }
        }
    }

    /// Stops a restart-update before anything was swapped.
    func cancelRestart(_ why: String) {
        restartTimer?.invalidate()
        restartTimer = nil
        guard restarting else { return }
        restarting = false
        setState("restart-vm", nil)
        log("restart-update stopped: \(why)")
    }

    private func shutdownTimedOut(after timeout: TimeInterval) {
        guard restarting, runningVM() != nil else { return }
        let version = staged?.version
        cancelRestart("the VM still runs after \(Int(timeout)) s")
        // The second confirm: forcing it off loses what is not saved in the VM.
        // Test builds answer it with OMACVM_RESTART_FORCE (1: force, else OK).
        let force: Bool
        if let hook = TestHooks.value("OMACVM_RESTART_FORCE", bundleID: bundleID) {
            force = hook == "1"
        } else {
            NSApp.activate()
            force = Self.shutdownTimeoutAlert().runModal() == .alertSecondButtonReturn
        }
        guard force, let vm = runningVM(), let version else { return }
        restarting = true
        setState("restart-vm", RestartVM(folder: vm.folder.path, version: version, at: Date()).line)
        log("restart-update: the user forced the VM off")
        forceStopVM()
    }

    static func shutdownTimeoutAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "The VM did not shut down"
        alert.informativeText = "It still runs after 3 minutes, so the update stopped. Nothing was changed. Force it off only if nothing in it needs saving."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Force Off and Update")
        return alert
    }

    /// What Check for Updates… says. busy: why the app cannot be replaced
    /// right now (a VM runs from it): the update then waits for it.
    static func checkAlert(_ outcome: Outcome, current: String, busy: String?, restart: Bool = false) -> NSAlert {
        if restart, case .ready(let v) = outcome { return restartAlert(v, current: current) }
        let alert = NSAlert()
        switch outcome {
        case .ready(let v):
            alert.messageText = "\(Product.name) \(v) is ready to install"
            if let busy {
                alert.informativeText = "You have \(current). \(busy), so \(v) goes in once it has shut down. Your VMs are not changed."
                alert.addButton(withTitle: "Update After Shutdown")
            } else {
                alert.informativeText = "You have \(current). \(Product.name) restarts with the new version; your VMs are not changed. If it does not start, \(current) comes back by itself."
                alert.addButton(withTitle: "Update and Relaunch")
            }
            alert.addButton(withTitle: "Later")
        case .upToDate:
            alert.messageText = "\(Product.name) is up to date"
            alert.informativeText = "\(current) is the newest version."
        case .skipped(let v):
            alert.messageText = "\(Product.name) \(v) is skipped"
        case .needsMacOS(let v, let m):
            alert.messageText = "\(Product.name) \(v) needs macOS \(m)"
            alert.informativeText = "This Mac stays on \(current). Update macOS to get \(v)."
        case .failed(let why):
            alert.messageText = "Could not check for updates"
            // The reasons are log lines ("no connection to ..."): as a sentence.
            alert.informativeText = sentence(why)
        }
        return alert
    }

    /// The confirm before an update shuts the running VM down.
    static func restartAlert(_ version: String, current: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Update to \(Product.name) \(version)?"
        alert.informativeText = "Your VM shuts down cleanly, \(Product.name) updates and restarts, then starts the VM again. Save your work in the VM first. If the new version does not start, \(current) comes back by itself."
        alert.addButton(withTitle: "Shut Down and Update")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    /// From the window or the menu (the user confirmed): check, then shut down.
    func restartFromMac() async {
        let r = await prepareRestart(vmName: nil)
        if case .ready = r { shutDownForRestart(); return }
        log("restart-update not started: \(r.answer.text)")
        if case .busy(let why) = r { notice = Self.sentence(why) }
        if case .cannot(let why) = r { notice = why }
    }

    /// The VM ended (any status). During a restart-update: install now; the
    /// new app starts the VM. True when handled here.
    func vmEndedForRestart() -> Bool {
        guard restarting else { return false }
        restartTimer?.invalidate()
        restartTimer = nil
        log("restart-update: the VM has ended, installing")
        install(quit: true, quiet: false)
        if swapping { return true }
        // QEMU's process takes a moment to go: look each second for a minute
        // (the idle timer's 30 s after that).
        if installWhenIdle {
            restartPolls = 0
            restartTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, self.restarting, self.installWhenIdle else { t.invalidate(); return }
                    self.restartPolls += 1
                    if self.busyNow == nil { t.invalidate(); self.install(quit: true, quiet: false) }
                    else if self.restartPolls >= 60 { t.invalidate() }
                }
            }
            return true
        }
        // Nothing swapped (the notice says why): the VM comes back at once.
        let folder = state("restart-vm").flatMap(RestartVM.parse)?.folder
        cancelRestart("the install did not start")
        if let folder { startVMAgain(URL(fileURLWithPath: folder)) }
        return true
    }

    /// A VM starts from this launcher while a restart-update waits for the
    /// old QEMU to go (Start in the window): the update stops, so it never
    /// goes in at that VM's next shutdown by surprise.
    func vmStarting() {
        guard restarting else { return }
        stopWaiting()
        cancelRestart("the VM was started again before the update went in")
        notice = "The update stopped: the VM was started again. Check Now updates later."
    }

    /// At launch: the VM a restart-update shut down, to start once (only when
    /// fresh: a late or stray launch never starts a VM by surprise). After a
    /// swap (afterSwap) a copy stays as restart-vm.taken for 2 minutes: if
    /// update-swap.sh still puts the old version back (its launch check gave
    /// up just before this app answered), it moves the copy back and the old
    /// version starts the VM.
    func takeRestartVM(afterSwap: Bool = false) -> URL? {
        if !afterSwap { setState("restart-vm.taken", nil) }
        guard let text = state("restart-vm") else { return nil }
        setState("restart-vm", nil)
        if afterSwap {
            setState("restart-vm.taken", text)
            Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setState("restart-vm.taken", nil) }
            }
        }
        guard let r = RestartVM.parse(text), r.fresh(now: Date()) else {
            log("restart-vm: old or unreadable, the VM is not started")
            return nil
        }
        log("starting the VM again after the update: \(r.folder)")
        return URL(fileURLWithPath: r.folder)
    }

    // MARK: - pictures of the UI (test builds: --render-update-ui)

    private var shownPrevious: String?

    /// Puts the updater in a state to draw it; nothing is checked or saved.
    func showForRendering(staged: Staged?, notice: String?, enabled: Bool, waiting: Bool, previous: String?,
                          outcome: Outcome? = nil, checking: Bool = false) {
        self.staged = staged
        lastOutcome = outcome
        self.checking = checking
        self.notice = notice
        self.enabled = enabled
        installWhenIdle = waiting
        shownPrevious = previous
    }

    // MARK: - helpers

    var logFile: URL {
        let f = home.appendingPathComponent("update.log")
        if !FileManager.default.fileExists(atPath: f.path) {
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: f.path, contents: nil)
        }
        return f
    }

    func log(_ s: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let h = appendHandle() else { return }
        h.write(Data("\(stamp) app \(currentVersion): \(s)\n".utf8))
        try? h.close()
    }

    /// The log opened for appending (O_APPEND): the swap script and the
    /// app it starts write to it at the same time; with a plain offset one
    /// overwrote the other's line.
    private func appendHandle() -> FileHandle? {
        let fd = open(logFile.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        return fd < 0 ? nil : FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func trimLog() {
        guard let size = Files.size(logFile), size > 512 * 1024,
              let data = try? Data(contentsOf: logFile) else { return }
        try? data.suffix(128 * 1024).write(to: logFile)
    }

    /// Runs a tool; its exit status, or -1 when it does not start or
    /// overruns the timeout (then it is killed).
    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 300) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        let end = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < end { usleep(50_000) }
        if p.isRunning { p.terminate(); return -1 }
        return p.terminationStatus
    }
}
