import Darwin
import Foundation

/// The VM folder's staging folder for drops: `<VM>/drop/<id>/<name>`. Every
/// file comes as a descriptor QEMU opened (this app never opens a dropped
/// path), and is cloned (APFS, same volume: instant, copy-on-write: the
/// original is never touched) or, on another volume, copied while the Mac
/// keeps 10 GB free. Never a hard link. Folders and links are made with
/// O_NOFOLLOW from the open staging folder, never through a path again.
public final class DropStage: @unchecked Sendable {
    /// A real copy leaves at least this much free on the VM folder's volume.
    public static let keepFree: Int64 = 10 * 1024 * 1024 * 1024
    public let root: String
    private let lock = NSLock()
    private var cancelled = false
    /// Tests: pretend the clone failed (another volume), so the copy runs.
    public var forceCopy = false
    /// Tests: the free space the copy sees.
    public var freeOverride: Int64?

    public init(root: String) { self.root = root }

    /// The folder empty and new (start and stop). Whatever a last run left
    /// there goes (the VM read it then, or never will).
    @discardableResult
    public func reset() -> Bool {
        remove()
        guard mkdir(root, 0o700) == 0 || errno == EEXIST else { return false }
        var st = stat()
        return lstat(root, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid()
    }

    /// The whole folder goes (VM stop).
    public func remove() {
        var st = stat()
        guard lstat(root, &st) == 0 else { return }
        // A link where the folder was is removed itself, never followed.
        if (st.st_mode & S_IFMT) != S_IFDIR { unlink(root); return }
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Stops a copy that runs (the VM stopped).
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public struct Result: Equatable {
        public var id: String
        public var items: [DropWire.Item]
        public var cloned: Int
        public var copied: Int
        public var skipped: Int
        public var why: String?
    }

    /// Stages one drop. `files`: the names and the descriptors QEMU opened
    /// (closed here, whatever happens).
    public func stage(_ files: [(name: String, fd: Int32)], id: String = DropWire.newID()) -> Result {
        var r = Result(id: id, items: [], cloned: 0, copied: 0, skipped: 0, why: nil)
        defer { for f in files { close(f.fd) } }
        guard DropWire.idOK(id) else { r.skipped = files.count; r.why = "bad id"; return r }
        let top = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard top >= 0 else { r.skipped = files.count; r.why = "no drop folder"; return r }
        defer { close(top) }
        guard mkdirat(top, id, 0o755) == 0 else { r.skipped = files.count; r.why = "drop folder: \(String(cString: strerror(errno)))"; return r }
        let dir = openat(top, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { r.skipped = files.count; r.why = "drop folder"; return r }
        defer { close(dir) }
        var seen = Set<String>()
        for f in files.prefix(DropWire.maxItems) {
            // Two files of one name (dropped from two folders): the second gets " (2)".
            var name = f.name
            var n = 2
            while seen.contains(name) { name = Self.numbered(f.name, n); n += 1 }
            guard DropWire.nameOK(name), !isCancelled else { r.skipped += 1; continue }
            var st = stat()
            guard fstat(f.fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { r.skipped += 1; continue }
            let mode = mode_t(0o644) | (st.st_mode & 0o111)
            if !forceCopy, fclonefileat(f.fd, dir, name, UInt32(CLONE_NOOWNERCOPY)) == 0 {
                if let g = Self.openOwn(dir, name) { fchmod(g, mode); close(g) }
                r.cloned += 1
            } else if copy(from: f.fd, size: Int64(st.st_size), dir: dir, name: name, mode: mode) {
                r.copied += 1
            } else {
                r.skipped += 1
                if r.why == nil { r.why = isCancelled ? "the VM stopped" : "not enough free space for a copy (10 GB stay free)" }
                continue
            }
            seen.insert(name)
            r.items.append(DropWire.Item(name: name, bytes: Int64(st.st_size)))
        }
        r.skipped += max(0, files.count - DropWire.maxItems)
        if r.items.isEmpty { removeDrop(id) }
        return r
    }

    /// One drop's folder goes (the VM put the files in Downloads, or failed).
    public func removeDrop(_ id: String) {
        guard DropWire.idOK(id) else { return }
        let p = (root as NSString).appendingPathComponent(id)
        var st = stat()
        guard lstat(p, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) != S_IFDIR { unlink(p); return }
        try? FileManager.default.removeItem(atPath: p)
    }

    private static func openOwn(_ dir: Int32, _ name: String) -> Int32? {
        let g = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        return g >= 0 ? g : nil
    }

    static func numbered(_ name: String, _ n: Int) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty || base.isEmpty ? "\(name) (\(n))" : "\(base) (\(n)).\(ext)"
    }

    private func freeBytes(_ dir: Int32) -> Int64 {
        if let f = freeOverride { return f }
        var s = statfs()
        guard fstatfs(dir, &s) == 0 else { return 0 }
        return Int64(s.f_bavail) * Int64(s.f_bsize)
    }

    /// A real copy (another volume), 1 MB at a time, stopped when the VM stops.
    private func copy(from src: Int32, size: Int64, dir: Int32, name: String, mode: mode_t) -> Bool {
        guard freeBytes(dir) - size >= Self.keepFree else { return false }
        let dst = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard dst >= 0 else { return false }
        var ok = lseek(src, 0, SEEK_SET) == 0
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buf.deallocate() }
        while ok {
            if isCancelled { ok = false; break }
            let n = read(src, buf, 1 << 20)
            if n == 0 { break }
            if n < 0 { if errno == EINTR { continue }; ok = false; break }
            var off = 0
            while off < n {
                let w = write(dst, buf + off, n - off)
                if w < 0 { if errno == EINTR { continue }; ok = false; break }
                off += w
            }
        }
        close(dst)
        if !ok { unlinkat(dir, name, 0) }
        return ok
    }
}
