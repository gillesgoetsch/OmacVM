// Touch ID's panel: the socket OmacVM.app asks it on, and the entry point
// QEMU calls (omacvm-cocoa-touchid-panel.patch).
import AppKit
import Darwin
import OmacVMAuth

/// Listens on a Unix socket in the app's private run folder; one connection
/// at a time, JSON lines (TouchIDPanelPrompt's comment). The socket's folder
/// must be this user's and 0700, as for QEMU's own sockets.
final class PanelServer: @unchecked Sendable {
    static let maximumLineBytes = 8192
    private let path: String
    private let controller: PanelController
    private let writeLock = NSLock()

    init(path: String, controller: PanelController) {
        self.path = path
        self.controller = controller
    }

    /// The listening socket, or nil (bad folder, cannot bind).
    func listen() -> Int32? {
        guard path.hasPrefix("/"), path.utf8.count < 100 else { return nil }
        let dir = (path as NSString).deletingLastPathComponent
        var st = stat()
        guard lstat(dir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { return nil }
        if lstat(path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == getuid() else { return nil }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { b in
            b.initializeMemory(as: UInt8.self, repeating: 0)
            b.copyBytes(from: bytes)
        }
        let len = socklen_t((MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0) + bytes.count + 1)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard ok == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 1) == 0 else { close(fd); return nil }
        return fd
    }

    func run(_ listener: Int32) {
        while true {
            let c = accept(listener, nil, nil)
            if c < 0 { if errno == EINTR { continue }; return }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            serve(c)
            DispatchQueue.main.sync { controller.cancel() }   // the app is gone: so is its panel
            close(c)
        }
    }

    private func write(_ fd: Int32, _ d: Data) {
        writeLock.lock(); defer { writeLock.unlock() }
        _ = d.withUnsafeBytes { b in Darwin.write(fd, b.baseAddress, b.count) }
    }

    private func serve(_ fd: Int32) {
        var line = Data(), chunk = [UInt8](repeating: 0, count: 4096), skipping = false
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n == 0 { return }
            if n < 0 { if errno == EINTR { continue }; return }
            var start = 0
            for i in 0..<n where chunk[i] == 0x0A {
                if !skipping { line.append(contentsOf: chunk[start..<i]); handle(line, fd) }
                line.removeAll(keepingCapacity: true)
                skipping = false
                start = i + 1
            }
            if !skipping {
                line.append(contentsOf: chunk[start..<n])
                if line.count > Self.maximumLineBytes { line.removeAll(); skipping = true }
            }
        }
    }

    private func handle(_ line: Data, _ fd: Int32) {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let op = o["op"] as? String else { return }
        switch op {
        case "show":
            guard let p = o["prompt"].flatMap(TouchIDPanelPrompt.parse) else { return write(fd, TouchIDPanelResult.error.line) }
            DispatchQueue.main.async { [self] in
                controller.show(p) { [self] r in write(fd, r.line) }
            }
        case "close":
            DispatchQueue.main.async { [self] in controller.cancel() }
        default:
            break
        }
    }
}

nonisolated(unsafe) private var started: PanelServer?

/// QEMU calls this once, on the main thread, after it finished launching.
/// Returns 0 when the panel listens on `socketPath`.
@_cdecl("omacvm_touchid_panel_start")
public func omacvm_touchid_panel_start(_ socketPath: UnsafePointer<CChar>?,
                                       _ willShow: (@convention(c) () -> Void)?,
                                       _ didClose: (@convention(c) () -> Void)?) -> Int32 {
    guard started == nil, let socketPath else { return -1 }
    let controller = PanelController()
    if let willShow { controller.willShow = { willShow() } }
    if let didClose { controller.didClose = { didClose() } }
    let server = PanelServer(path: String(cString: socketPath), controller: controller)
    guard let fd = server.listen() else { return -1 }
    started = server
    Thread.detachNewThread { server.run(fd) }
    return 0
}
