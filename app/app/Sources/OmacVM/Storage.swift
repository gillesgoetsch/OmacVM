import CryptoKit
import Foundation

// Where VM folders live and how they move. Plain Foundation and no app types,
// so src/tests/app-storage.sh compiles this file alone and tests it on
// fixture folders.

enum StorageError: LocalizedError, Equatable {
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .failed(let detail): detail
        case .cancelled: "Cancelled."
        }
    }
}

enum Storage {
    /// The nearest folder of URL that exists (URL itself, or a parent).
    static func existingAncestor(_ url: URL) -> URL {
        sequence(first: url.standardizedFileURL) { u in
            u.path == "/" ? nil : u.deletingLastPathComponent()
        }.first { FileManager.default.fileExists(atPath: $0.path) } ?? URL(fileURLWithPath: "/")
    }

    static func device(_ url: URL) -> dev_t? {
        var st = stat()
        return stat(url.path, &st) == 0 ? st.st_dev : nil
    }

    /// The drive a folder under /Volumes needs, when that drive is not
    /// connected. A stale empty /Volumes/NAME folder (same device as /Volumes)
    /// counts as not connected: writing there would fill the Mac's own disk.
    static func missingDrive(for url: URL, volumes: URL = URL(fileURLWithPath: "/Volumes")) -> String? {
        let parts = url.standardizedFileURL.pathComponents
        let base = volumes.standardizedFileURL.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
        let name = parts[base.count]
        let mount = volumes.appendingPathComponent(name)
        guard let d = device(mount), let v = device(volumes), d != v else { return name }
        return nil
    }

    /// Both folders are on one drive (a move is then a rename).
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let x = device(existingAncestor(a)), let y = device(existingAncestor(b)) else { return false }
        return x == y
    }

    /// Free bytes on the drive of a folder, as Finder counts them.
    static func freeBytes(at url: URL) -> Int64? {
        let u = existingAncestor(url)
        if let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let n = v.volumeAvailableCapacityForImportantUsage, n > 0 {
            return n
        }
        var st = statfs()
        guard statfs(u.path, &st) == 0 else { return nil }
        return Int64(st.f_bavail) * Int64(st.f_bsize)
    }

    /// What a folder takes on its drive (a sparse disk counts what it holds).
    static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// "~/OmacVM" for folders in the home folder.
    static func short(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p == home ? "~" : p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }

    /// "23.4 GB", as Finder writes sizes.
    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Time Machine leaves the folder out (the sticky flag `tmutil addexclusion`
    /// sets). A rename keeps it; a copy to another drive does not, so
    /// FolderMover sets it again on the copy. A VM disk changes all the time
    /// and would fill the backup.
    static func excludeFromBackup(_ url: URL) {
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }

    /// Half copies (".NAME.moving") a move left in the VMs folders when the app
    /// quit or crashed during it; only called at launch, before any move.
    /// Returns what was deleted.
    @discardableResult
    static func removeStaleMoves(in roots: [URL]) -> [URL] {
        let fm = FileManager.default
        var removed: [URL] = []
        for root in roots where missingDrive(for: root) == nil {
            for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            where name.count > ".moving".count + 1 && name.hasPrefix(".") && name.hasSuffix(".moving") {
                let u = root.appendingPathComponent(name)
                var st = stat()
                guard lstat(u.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
                if (try? fm.removeItem(at: u)) != nil { removed.append(u) }
            }
        }
        return removed
    }

    /// This user's processes, with their full command lines.
    static func processLines() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-x", "-ww", "-U", String(getuid()), "-o", "args="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The folders a process uses: QEMU (its disk on the command line, commas
    /// doubled), a build or `omacvm apply` (the folder as an argument).
    static func busyFolders(_ folders: [URL], lines: [String] = processLines()) -> [URL] {
        folders.filter { f in
            let p = f.standardizedFileURL.path
            let qemu = p.replacingOccurrences(of: ",", with: ",,") + "/disk.img,"
            return lines.contains { $0.contains(qemu) || $0.contains(p + "/") || $0.hasSuffix(" " + p) }
        }
    }

    /// Something downloads into or builds from the downloads folder now.
    static func downloadsInUse(_ caches: URL, lines: [String] = processLines()) -> Bool {
        let marks = [caches.standardizedFileURL.path, "create-vm.sh", "build-live.sh", "make-image.sh",
                     "prebuilt-vm.sh", "omacvm build"]
        return lines.contains { l in marks.contains { l.contains($0) } }
    }

    /// Deletes what is in the folder (the folder stays).
    static func clear(_ folder: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return }
        for item in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            try fm.removeItem(at: item)
        }
    }

    // MARK: Downloads

    /// What builds download into a downloads folder: try-omarchy's live system
    /// and prebuilt VMs. Only these are counted and removed: the Mac's
    /// ~/Library/Caches/omacvm also holds the omacvm command's work
    /// (build-live, make-image.sh's prebuilt-out).
    static let downloadItems = ["live", "prebuilt"]

    /// Where builds of VMs in a VMs folder keep their downloads: the Mac's
    /// ~/Library/Caches/omacvm when the folder is on the home folder's drive,
    /// else ROOT/.downloads, so VMs on another drive leave the Mac's disk
    /// alone. vm-common.sh (downloads_dir) has the same rule.
    static func downloadsFolder(vmsRoot: URL, home: URL) -> URL {
        let root = vmsRoot.standardizedFileURL
        if missingDrive(for: root) == nil && sameVolume(root, home) {
            return home.appendingPathComponent("Library/Caches/omacvm")
        }
        return root.appendingPathComponent(".downloads")
    }

    /// Every downloads folder of these VMs folders, the Mac's own always
    /// (older versions used only that one), then OLD ones of folders the app
    /// left (dropDownloads); each once, the first root's first.
    static func downloadsFolders(vmsRoots: [URL], home: URL, old: [URL] = []) -> [URL] {
        var seen = Set<String>(), out: [URL] = []
        let all = vmsRoots.map { downloadsFolder(vmsRoot: $0, home: home) } + [home.appendingPathComponent("Library/Caches/omacvm")] + old
        for f in all where seen.insert(f.standardizedFileURL.path).inserted { out.append(f.standardizedFileURL) }
        return out
    }

    /// What the downloads in a folder take on its drive.
    static func downloadsSize(_ folder: URL) -> Int64 {
        downloadItems.reduce(0) { $0 + allocatedSize(of: folder.appendingPathComponent($1)) }
    }

    /// Removes the downloads in a folder, nothing else. Refused when the
    /// folder is a link or holds a VM (it would not be a downloads folder).
    static func clearDownloads(_ folder: URL) throws {
        let fm = FileManager.default
        var st = stat()
        guard lstat(folder.path, &st) == 0 else { return }
        guard st.st_mode & S_IFMT == S_IFDIR else {
            throw StorageError.failed("\(folder.path) is not a folder: left alone.")
        }
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        if names.contains(where: { fm.fileExists(atPath: folder.appendingPathComponent($0).appendingPathComponent("vm.env").path) }) {
            throw StorageError.failed("\(folder.path) holds a VM: left alone.")
        }
        for name in downloadItems {
            let u = folder.appendingPathComponent(name)
            if lstat(u.path, &st) == 0 { try fm.removeItem(at: u) }
        }
    }

    /// The downloads of a VMs folder the app no longer uses: renamed to
    /// NEWFOLDER when that is on the same drive, not there yet and no build
    /// uses them. Else they stay where they are and the folder comes back,
    /// for Paths.oldDownloads: Storage counts and removes them there, and the
    /// next build takes the live system from there (vm-common.sh live_reuse).
    static func dropDownloads(ofRoot root: URL, to newFolder: URL, lines: [String]) -> URL? {
        let old = root.standardizedFileURL.appendingPathComponent(".downloads")
        let fm = FileManager.default
        guard old.path != newFolder.standardizedFileURL.path else { return nil }
        if missingDrive(for: root) != nil { return old }
        guard fm.fileExists(atPath: old.path) else { return nil }
        if newFolder.lastPathComponent == ".downloads", !fm.fileExists(atPath: newFolder.path), sameVolume(old, newFolder),
           !downloadsInUse(old, lines: lines),
           (try? fm.createDirectory(at: newFolder.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
           (try? fm.moveItem(at: old, to: newFolder)) != nil {
            return nil
        }
        return old
    }

    /// Old downloads folders still worth listing: on a drive not connected,
    /// or still there.
    static func oldDownloadsKept(_ old: [URL]) -> [URL] {
        old.filter { missingDrive(for: $0) != nil || FileManager.default.fileExists(atPath: $0.path) }
    }

    /// An old downloads folder once its downloads are gone: removed when
    /// nothing else is in it.
    static func removeIfEmpty(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(".DS_Store"))
        rmdir(folder.path)
    }
}

/// Moves a VM folder into another folder. On one drive that is a rename. To
/// another drive: a copy that keeps the disk sparse, read back and compared,
/// and only then the old folder is deleted. Until the last step the old
/// folder is untouched, so a failure or a cancel loses nothing.
final class FolderMover: @unchecked Sendable {
    /// Bytes done and in all; the phase is "Copying" or "Checking".
    var progress: (_ phase: String, _ done: Int64, _ total: Int64) -> Void = { _, _, _ in }
    private let lock = NSLock()
    private var stop = false

    func cancel() { lock.lock(); stop = true; lock.unlock() }
    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stop }

    /// Returns the folder in its new place.
    func move(_ folder: URL, into root: URL) throws -> URL {
        let fm = FileManager.default
        let source = folder.standardizedFileURL
        let target = root.standardizedFileURL.appendingPathComponent(source.lastPathComponent)
        guard source.deletingLastPathComponent().path != root.standardizedFileURL.path else { return source }
        // A copy would go through the link and then delete only the link.
        if let dest = try? fm.destinationOfSymbolicLink(atPath: source.path) {
            throw StorageError.failed("\(source.lastPathComponent) is a link to \(dest), not a folder: move that folder in Finder instead.")
        }
        guard !fm.fileExists(atPath: target.path) else {
            throw StorageError.failed("\(target.path) already exists.")
        }
        if let drive = Storage.missingDrive(for: root) {
            throw StorageError.failed("\(drive) is not connected.")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if Storage.sameVolume(source, root) {
            do {
                try fm.moveItem(at: source, to: target)
                return target
            } catch {
                throw StorageError.failed("Could not move \(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let before = try stamps(source)
        let files = try plan(source)
        let total = files.reduce(Int64(0)) { $0 + $1.data }
        // Mac OS Extended has no sparse files: a disk takes its full size there.
        let sparse = (try? root.resourceValues(forKeys: [.volumeSupportsSparseFilesKey]))?.volumeSupportsSparseFiles ?? false
        let need = sparse ? total : files.reduce(Int64(0)) { $0 + $1.size }
        if let free = Storage.freeBytes(at: root), free < need + 32 << 20 {   // a little room for the file system
            throw StorageError.failed("\(Storage.format(need)) to copy, \(Storage.format(free)) free there.")
        }
        let temp = root.appendingPathComponent(".\(source.lastPathComponent).moving")
        try? fm.removeItem(at: temp)
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: false)
            var done: Int64 = 0
            var sums: [String: Data] = [:]
            for f in files {
                let to = temp.appendingPathComponent(f.relative)
                switch f.kind {
                case .directory:
                    try fm.createDirectory(at: to, withIntermediateDirectories: true)
                case .link(let dest):
                    try fm.createSymbolicLink(atPath: to.path, withDestinationPath: dest)
                case .file:
                    sums[f.relative] = try copy(source.appendingPathComponent(f.relative), to, ranges: f.ranges,
                                                 done: &done, total: total)
                }
            }
            done = 0
            for f in files where f.kind == .file {
                let got = try digest(temp.appendingPathComponent(f.relative), ranges: f.ranges,
                                     done: &done, total: total)
                guard got == sums[f.relative] else {
                    throw StorageError.failed("The copy of \(f.relative) differs from the original: nothing moved.")
                }
            }
            // Folders last: writing into them changed their dates.
            for f in files.reversed() {
                let from = source.appendingPathComponent(f.relative)
                let to = temp.appendingPathComponent(f.relative)
                if case .link = f.kind { continue }   // setAttributes would follow it
                copyAttributes(from, to)
            }
            copyAttributes(source, temp)
            if Storage.isExcludedFromBackup(source) { Storage.excludeFromBackup(temp) }
            try fm.moveItem(at: temp, to: target)
        } catch {
            try? fm.removeItem(at: temp)
            if let e = error as? StorageError { throw e }
            throw StorageError.failed("Could not copy \(source.lastPathComponent): \(error.localizedDescription)")
        }
        // Something wrote into the folder while it was copied (`omacvm apply`,
        // say): the copy misses that, so the original stays.
        let after = (try? stamps(source)) ?? [:]
        if let changed = Set(before.keys).union(after.keys).sorted().first(where: { before[$0] != after[$0] }) {
            try? fm.removeItem(at: target)
            throw StorageError.failed("\(changed) in \(source.lastPathComponent) changed during the move: nothing moved. Try again.")
        }
        do {
            try fm.removeItem(at: source)
        } catch {
            throw StorageError.failed("Copied to \(target.path), but the old folder is still at \(source.path): \(error.localizedDescription)")
        }
        return target
    }

    enum Kind: Equatable {
        case directory
        case file
        case link(String)
    }

    struct Item {
        var relative: String
        var kind: Kind
        var ranges: [Range<Int64>] = []
        var size: Int64 = 0
        var data: Int64 { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
    }

    /// Every item in the folder with what tells a change: type, and for a file
    /// its size and modification time (to the nanosecond), for a link where it
    /// points.
    private func stamps(_ folder: URL) throws -> [String: String] {
        guard let e = FileManager.default.enumerator(atPath: folder.path) else {
            throw StorageError.failed("Cannot read \(folder.path).")
        }
        var out: [String: String] = [:]
        for case let rel as String in e {
            let path = folder.appendingPathComponent(rel).path
            var st = stat()
            guard lstat(path, &st) == 0 else { out[rel] = "gone"; continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: out[rel] = "dir"
            case S_IFREG: out[rel] = "file \(st.st_size) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
            case S_IFLNK: out[rel] = "link " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "")
            default: out[rel] = "other \(st.st_mode & S_IFMT)"
            }
        }
        return out
    }

    /// Everything in the folder, parents before children; each file with the
    /// parts that hold data (holes of a sparse file are skipped).
    private func plan(_ folder: URL) throws -> [Item] {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: folder.path) else {
            throw StorageError.failed("Cannot read \(folder.path).")
        }
        var items: [Item] = []
        for case let rel as String in e {
            let url = folder.appendingPathComponent(rel)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            switch attrs[.type] as? FileAttributeType {
            case .typeDirectory?: items.append(Item(relative: rel, kind: .directory))
            case .typeSymbolicLink?:
                items.append(Item(relative: rel, kind: .link(try fm.destinationOfSymbolicLink(atPath: url.path))))
            case .typeRegular?:
                items.append(Item(relative: rel, kind: .file, ranges: try dataRanges(url),
                                  size: (attrs[.size] as? NSNumber)?.int64Value ?? 0))
            default: continue   // sockets and the like: QEMU keeps them elsewhere
            }
        }
        return items
    }

    /// The parts of a file that hold data (SEEK_DATA / SEEK_HOLE).
    private func dataRanges(_ url: URL) throws -> [Range<Int64>] {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw StorageError.failed("Cannot read \(url.path).") }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        let size = Int64(st.st_size)
        var ranges: [Range<Int64>] = []
        var pos: Int64 = 0
        while pos < size {
            let start = lseek(fd, off_t(pos), SEEK_DATA)
            if start < 0 { break }   // ENXIO: only a hole is left
            var end = lseek(fd, start, SEEK_HOLE)
            if end < 0 || end > size { end = off_t(size) }
            if end > start { ranges.append(Int64(start)..<Int64(end)) }
            pos = Int64(end)
        }
        if ranges.isEmpty && size > 0 && lseek(fd, 0, SEEK_DATA) < 0 && errno != ENXIO {
            return [0..<size]   // no hole support: all of it
        }
        return ranges
    }

    private static let chunk = 8 << 20

    /// Copies the data parts; returns their SHA-256. Chunks of zeros are not
    /// written, so the copy stays sparse even from a drive without holes.
    private func copy(_ from: URL, _ to: URL, ranges: [Range<Int64>], done: inout Int64, total: Int64) throws -> Data {
        let src = open(from.path, O_RDONLY)
        guard src >= 0 else { throw StorageError.failed("Cannot read \(from.path).") }
        defer { close(src) }
        let dst = open(to.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard dst >= 0 else { throw StorageError.failed("Cannot write \(to.path).") }
        defer { close(dst) }
        var st = stat()
        fstat(src, &st)
        guard ftruncate(dst, st.st_size) == 0 else { throw StorageError.failed("Cannot write \(to.path).") }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: Self.chunk)
        for r in ranges {
            var off = r.lowerBound
            while off < r.upperBound {
                if cancelled { throw StorageError.cancelled }
                let want = Int(min(Int64(Self.chunk), r.upperBound - off))
                let n = buffer.withUnsafeMutableBytes { pread(src, $0.baseAddress, want, off_t(off)) }
                guard n > 0 else { throw StorageError.failed("Cannot read \(from.path).") }
                let zero = buffer.withUnsafeBytes { Self.isZero($0, n) }
                if !zero {
                    var written = 0
                    while written < n {
                        let w = buffer.withUnsafeBytes { pwrite(dst, $0.baseAddress! + written, n - written, off_t(off) + off_t(written)) }
                        guard w > 0 else { throw StorageError.failed("Cannot write \(to.path) (drive full?).") }
                        written += w
                    }
                }
                buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                off += Int64(n)
                done += Int64(n)
                progress("Copying", done, total)
            }
        }
        // On the drive, not just in macOS's cache: the original goes next.
        guard fcntl(dst, F_FULLFSYNC) == 0 || fsync(dst) == 0 else {
            throw StorageError.failed("Cannot write \(to.path).")
        }
        return Data(hash.finalize())
    }

    /// SHA-256 of the same parts of the copy, read past macOS's cache.
    private func digest(_ url: URL, ranges: [Range<Int64>], done: inout Int64, total: Int64) throws -> Data {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw StorageError.failed("Cannot read \(url.path).") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: Self.chunk)
        for r in ranges {
            var off = r.lowerBound
            while off < r.upperBound {
                if cancelled { throw StorageError.cancelled }
                let want = Int(min(Int64(Self.chunk), r.upperBound - off))
                let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(off)) }
                guard n > 0 else { throw StorageError.failed("Cannot read \(url.path).") }
                buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                off += Int64(n)
                done += Int64(n)
                progress("Checking", done, total)
            }
        }
        return Data(hash.finalize())
    }

    private static func isZero(_ p: UnsafeRawBufferPointer, _ n: Int) -> Bool {
        let words = n / 8
        let w = p.baseAddress!.assumingMemoryBound(to: UInt64.self)
        for i in 0..<words where w[i] != 0 { return false }
        for i in (words * 8)..<n where p[i] != 0 { return false }
        return true
    }

    private func copyAttributes(_ from: URL, _ to: URL) {
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: from.path) else { return }
        var keep: [FileAttributeKey: Any] = [:]
        if let p = a[.posixPermissions] { keep[.posixPermissions] = p }
        if let d = a[.modificationDate] { keep[.modificationDate] = d }
        try? fm.setAttributes(keep, ofItemAtPath: to.path)
    }
}

/// OmacVM.app from /Applications into the user's own Applications folder: one
/// rename (both are on the Mac's data volume), so the signature stays as it is.
enum AppMover {
    static func move(_ app: URL, into folder: URL) throws -> URL {
        let fm = FileManager.default
        let target = folder.appendingPathComponent(app.lastPathComponent)
        guard !fm.fileExists(atPath: target.path) else {
            throw StorageError.failed("\(target.path) already exists.")
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard Storage.sameVolume(app, folder) else {
            throw StorageError.failed("\(folder.path) is on another drive.")
        }
        do {
            try fm.moveItem(at: app, to: target)
        } catch {
            throw StorageError.failed("Could not move the app: \(error.localizedDescription)")
        }
        return target
    }
}
