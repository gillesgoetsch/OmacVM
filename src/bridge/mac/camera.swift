// The Mac's camera for Linux apps in the VM. Shared by OmacVM Bridge (frames
// over TCP to UTM and VMware Fusion VMs, GET /camera) and OmacVM.app (over a
// virtio port; app/app/Sources/OmacVM/camera.swift is a link to this file).
// Capture, frame size and wire format from try-omarchy
// (github.com/omacom/try-omarchy, macos/Sources/OmarchyVMHelper/NativeCameraBridge.swift),
// MIT, (c) Try Omarchy contributors.
//
// One connection per VM (a TCP socket or QEMU's chardev socket), both ways:
//   VM -> Mac  one JSON object per line: {"type": "start"} or {"type": "stop"}
//   Mac -> VM  messages: "TOCM", version 1, kind (1 status, 2 frame), 0, 0,
//              payload length and sequence (UInt32, little-endian), payload.
//              status: JSON, {"status": "idle" | "streaming" | "unavailable", ...}
//              frame: 1280x720 NV12, 1,382,400 bytes
// The camera (and its green light) is on only while a VM said start and has
// not said stop or gone away; the VM says start only while a Linux app reads
// its camera. A frame is dropped for a VM that has not taken the last one yet.
// OMACVM_CAMERA=test: a moving test picture instead of the camera (no
// permission needed; for checking the way to the VM).
// The camera is picked again at every start (pickCamera), and a start comes
// after every loss: the lid closed (the built-in camera is suspended), the
// camera unplugged, or no picture from it for 5 s. So a VM that still reads
// gets the next camera there is, or the same one once it is back.
import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation

enum CameraWire {
  static let width = 1280, height = 720, fps = 30
  static let frameBytes = width * height * 3 / 2

  static func message(kind: UInt8, sequence: UInt32, payload: Data) -> Data {
    var d = Data(capacity: 16 + payload.count)
    d.append(contentsOf: [0x54, 0x4f, 0x43, 0x4d, 1, kind, 0, 0])   // "TOCM", version, kind, reserved
    for v in [UInt32(payload.count), sequence] { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(payload)
    return d
  }

  static func status(_ fields: [String: Any]) -> Data {
    let json = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data("{}".utf8)
    return message(kind: 1, sequence: 0, payload: json)
  }
}

/// macOS's camera permission for this app: granted, not-determined, denied or restricted.
func cameraPermission() -> String {
  switch AVCaptureDevice.authorizationStatus(for: .video) {
  case .authorized: return "granted"
  case .notDetermined: return "not-determined"
  case .denied: return "denied"
  default: return "restricted"
  }
}

/// A camera macOS lists, as pickCamera sees it. usable: connected, and not
/// suspended (a MacBook's own camera with the lid closed).
struct CameraChoice: Equatable {
  let id: String, builtIn: Bool, usable: Bool
}

/// The camera the VM gets: the built-in one while it can be used, else
/// macOS's default camera, else the first one that can be used; nil: none.
func pickCamera(_ cameras: [CameraChoice], systemDefault: String?) -> String? {
  if let c = cameras.first(where: { $0.builtIn && $0.usable }) { return c.id }
  if let d = systemDefault, cameras.contains(where: { $0.id == d && $0.usable }) { return d }
  return cameras.first { $0.usable }?.id
}

/// Every video camera macOS lists now (built-in, USB and display cameras, Continuity Camera).
func cameraDevices() -> [AVCaptureDevice] {
  var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
  if #available(macOS 14.0, *) { types += [.external, .continuityCamera] } else { types.append(.externalUnknown) }
  return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
}

func cameraUsable(_ d: AVCaptureDevice) -> Bool {
  guard d.isConnected else { return false }
  if #available(macOS 14.0, *), d.isSuspended { return false }
  return true
}

/// The camera the VM gets now (pickCamera).
func cameraDevice() -> AVCaptureDevice? {
  let devices = cameraDevices()
  let choices = devices.map { CameraChoice(id: $0.uniqueID, builtIn: $0.deviceType == .builtInWideAngleCamera, usable: cameraUsable($0)) }
  guard let id = pickCamera(choices, systemDefault: AVCaptureDevice.default(for: .video)?.uniqueID) else { return nil }
  return devices.first { $0.uniqueID == id }
}

struct CameraError: Error {
  let reason: String, message: String   // reason: permission, no-camera, capture
}

/// What CameraHub needs of a camera: CameraCapture, or a stand-in in the offline test.
protocol CameraSource: AnyObject {
  var test: Bool { get }
  var onFrame: ((Data) -> Void)? { get set }
  var onFailure: ((String) -> Void)? { get set }
  /// A camera was connected (to try again at once while one is missing).
  var onCameraAdded: (() -> Void)? { get set }
  func start(_ done: @escaping (Result<String, CameraError>) -> Void)
  func stop()
}

/// One capture session (or the test picture). CameraHub starts and stops it.
/// Each start makes a new session with the camera picked then; stop ends it.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, CameraSource, @unchecked Sendable {
  private let queue = DispatchQueue(label: "omacvm.camera.session")
  private let frames = DispatchQueue(label: "omacvm.camera.frames", qos: .userInitiated)
  private var session: AVCaptureSession?
  private var observers: [NSObjectProtocol] = []
  private var suspendWatch: NSKeyValueObservation?
  private var addedWatch: NSObjectProtocol?
  private var timer: DispatchSourceTimer?
  private var reportedBadFrame = false
  let test = ProcessInfo.processInfo.environment["OMACVM_CAMERA"] == "test"
  var onFrame: ((Data) -> Void)?
  var onFailure: ((String) -> Void)?
  var onCameraAdded: (() -> Void)?

  override init() {
    super.init()
    addedWatch = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) {
      [weak self] _ in self?.onCameraAdded?()
    }
  }

  /// Starts capturing; done gets the camera's name. Asks for the permission
  /// first when macOS has not asked yet (its prompt shows now).
  func start(_ done: @escaping (Result<String, CameraError>) -> Void) {
    if test {
      queue.async { self.startTestPicture(); done(.success("test picture")) }
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      queue.async { self.startSession(done) }
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        if granted { self.queue.async { self.startSession(done) } }
        else { done(.failure(CameraError(reason: "permission", message: "camera permission not given"))) }
      }
    default:
      done(.failure(CameraError(reason: "permission", message: "camera permission denied (System Settings > Privacy & Security > Camera)")))
    }
  }

  /// Ends the session: the next start picks the camera again (the lid may
  /// have closed, a camera gone or come since).
  func stop() {
    queue.async { self.endSession() }
  }

  private func endSession() {   // on queue
    timer?.cancel(); timer = nil
    session?.stopRunning()
    session = nil
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers = []
    suspendWatch?.invalidate(); suspendWatch = nil
  }

  private func startSession(_ done: (Result<String, CameraError>) -> Void) {
    do {
      endSession()
      let s = try makeSession()
      session = s
      s.startRunning()
      guard s.isRunning else { throw CameraError(reason: "capture", message: "the camera did not start") }
      reportedBadFrame = false
      done(.success((s.inputs.first as? AVCaptureDeviceInput)?.device.localizedName ?? "camera"))
    } catch let e as CameraError {
      done(.failure(e))
    } catch {
      done(.failure(CameraError(reason: "capture", message: "\(error.localizedDescription)")))
    }
  }

  private func makeSession() throws -> AVCaptureSession {
    guard let device = cameraDevice() else { throw CameraError(reason: "no-camera", message: "this Mac has no camera") }
    let input = try AVCaptureDeviceInput(device: device)
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    // AVFoundation scales to this size when the camera has no 720p mode.
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      kCVPixelBufferWidthKey as String: CameraWire.width,
      kCVPixelBufferHeightKey as String: CameraWire.height,
    ]
    output.setSampleBufferDelegate(self, queue: frames)
    let s = AVCaptureSession()
    s.beginConfiguration()
    defer { s.commitConfiguration() }
    // The default preset gives 1080p on FaceTime HD cameras even in a 720p format.
    if s.canSetSessionPreset(.hd1280x720) { s.sessionPreset = .hd1280x720 }
    guard s.canAddInput(input), s.canAddOutput(output) else {
      throw CameraError(reason: "capture", message: "the camera cannot be used (another app holds it?)")
    }
    s.addInput(input)
    s.addOutput(output)
    // 1280x720 at 30 fps when the camera has it, set inside the configuration.
    let format = device.formats.first { f in
      let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
      return d.width == CameraWire.width && d.height == CameraWire.height
        && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(CameraWire.fps) && $0.maxFrameRate >= Double(CameraWire.fps) }
    }
    if let format, (try? device.lockForConfiguration()) != nil {
      device.activeFormat = format
      let t = CMTime(value: 1, timescale: CMTimeScale(CameraWire.fps))
      device.activeVideoMinFrameDuration = t
      device.activeVideoMaxFrameDuration = t
      device.unlockForConfiguration()
    }
    for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: s, queue: nil) { [weak self] n in
        self?.onFailure?(n.name == AVCaptureSession.runtimeErrorNotification ? "the camera reported an error" : "the camera was taken away")
      })
    }
    // Unplugged, or (a MacBook's own camera) the lid closed.
    let name = device.localizedName
    observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) {
      [weak self] _ in self?.onFailure?("\(name) is gone")
    })
    if #available(macOS 14.0, *) {
      suspendWatch = device.observe(\.isSuspended, options: [.new]) { [weak self] d, _ in
        if d.isSuspended { self?.onFailure?("\(name) is suspended (the lid closed?)") }
      }
    }
    return s
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    if let payload = nv12(pb) { onFrame?(payload) }
    else if !reportedBadFrame {
      reportedBadFrame = true
      onFailure?(String(format: "the camera gives %dx%d frames in format 0x%08x, not 1280x720 NV12",
                        CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), CVPixelBufferGetPixelFormatType(pb)))
    }
  }

  /// The frame as packed NV12: the luma rows, then the interleaved chroma rows.
  private func nv12(_ pb: CVPixelBuffer) -> Data? {
    guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
          CVPixelBufferGetWidth(pb) == CameraWire.width, CVPixelBufferGetHeight(pb) == CameraWire.height,
          CVPixelBufferGetPlaneCount(pb) == 2 else { return nil }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    var payload = Data(count: CameraWire.frameBytes)
    let ok = payload.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Bool in
      guard let base = dst.baseAddress else { return false }
      var off = 0
      for plane in 0..<2 {
        // Both planes hold `width` bytes per row (the chroma plane: width/2 pairs).
        let rows = CVPixelBufferGetHeightOfPlane(pb, plane), stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
        guard let src = CVPixelBufferGetBaseAddressOfPlane(pb, plane),
              rows == (plane == 0 ? CameraWire.height : CameraWire.height / 2), stride >= CameraWire.width,
              off + rows * CameraWire.width <= dst.count else { return false }
        for r in 0..<rows {
          memcpy(base + off, src + r * stride, CameraWire.width)
          off += CameraWire.width
        }
      }
      return off == dst.count
    }
    return ok ? payload : nil
  }

  /// Bands that move down the picture, 30 times a second.
  private func startTestPicture() {
    timer?.cancel()
    var tick = 0
    let t = DispatchSource.makeTimerSource(queue: frames)
    t.schedule(deadline: .now(), repeating: 1.0 / Double(CameraWire.fps))
    t.setEventHandler { [weak self] in
      tick += 1
      var p = Data(count: CameraWire.frameBytes)
      p.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) in
        guard let base = b.baseAddress else { return }
        for r in 0..<CameraWire.height {
          memset(base + r * CameraWire.width, Int32(16 + ((r / 4 + tick * 4) % 220)), CameraWire.width)
        }
        memset(base + CameraWire.width * CameraWire.height, 128, CameraWire.width * CameraWire.height / 2)
      }
      self?.onFrame?(p)
    }
    t.resume()
    timer = t
  }
}

/// One VM's connection: writes go through its own queue, so a slow VM never
/// holds up the camera or another VM.
final class CameraChannel: @unchecked Sendable {
  let fd: Int32, label: String
  private let out = DispatchQueue(label: "omacvm.camera.out")
  private let lock = NSLock()
  private var pending = false, closed = false

  init(fd: Int32, label: String) {
    self.fd = fd; self.label = label
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    // A VM that stops reading for 2 s is dropped (its side reconnects).
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  }

  /// Queues a message; a frame is dropped while the last one is still going out.
  func send(_ data: Data, frame: Bool = false) {
    lock.lock()
    if closed || (frame && pending) { lock.unlock(); return }
    if frame { pending = true }
    lock.unlock()
    out.async { [self] in
      let ok = data.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Bool in
        var off = 0
        while off < b.count {
          let n = Darwin.write(fd, b.baseAddress! + off, b.count - off)
          if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return false }
        }
        return true
      }
      lock.lock()
      if frame { pending = false }
      lock.unlock()
      if !ok { shutdown() }
    }
  }

  /// Ends the connection; the reading loop then sees its end.
  func shutdown() {
    lock.lock(); let was = closed; closed = true; lock.unlock()
    if !was { Darwin.shutdown(fd, SHUT_RDWR) }
  }
}

/// Every VM connection that may ask for the camera; the camera runs while at
/// least one of them wants it.
final class CameraHub: @unchecked Sendable {
  private let lock = NSLock()
  private var channels: [ObjectIdentifier: CameraChannel] = [:]
  private var wanting = Set<ObjectIdentifier>()
  private var state = "idle"   // idle, starting, streaming
  private var cameraName = ""
  private var sequence: UInt32 = 0
  private var retryDelay: Double   // seconds; doubles up to 30, back to the first with the first frame
  private let firstRetry: Double
  private var problem = ""         // the last failure, logged once
  private let capture: CameraSource
  private let log: (String) -> Void
  // Streaming with no frame for this long (a camera that stopped without a
  // word): picked and started again.
  private let frameTimeout: Double
  private var lastFrame = Date.distantPast
  private var watchdog: DispatchSourceTimer?
  let maxConnections = 8

  init(log: @escaping (String) -> Void, source: CameraSource = CameraCapture(), firstRetry: Double = 2, frameTimeout: Double = 5) {
    self.log = log
    self.capture = source
    self.firstRetry = firstRetry
    self.retryDelay = firstRetry
    self.frameTimeout = frameTimeout
    capture.onFrame = { [weak self] in self?.frame($0) }
    capture.onFailure = { [weak self] in self?.failed($0) }
    capture.onCameraAdded = { [weak self] in self?.retryNow() }
  }

  var canAttach: Bool { lock.lock(); defer { lock.unlock() }; return channels.count < maxConnections }

  /// GET /camera/status: permission, camera, how many VMs read it now.
  func status() -> [String: Any] {
    lock.lock(); let on = state == "streaming", readers = wanting.count, n = channels.count; lock.unlock()
    return ["permission": capture.test ? "test" : cameraPermission(), "camera": capture.test ? "test picture" : (cameraDevice()?.localizedName as Any? ?? NSNull()),
            "on": on, "readers": readers, "connections": n]
  }

  var summary: String {
    lock.lock(); defer { lock.unlock() }
    return state == "streaming" ? "on for \(wanting.count) VM\(wanting.count == 1 ? "" : "s")" : "off"
  }

  /// Serves one connection on its own thread; leftover = bytes already read past the request.
  func attach(fd: Int32, label: String, leftover: Data = Data()) {
    Thread.detachNewThread { self.run(fd: fd, label: label, leftover: leftover) }
  }

  /// Serves one connection until it ends, then closes it.
  func run(fd: Int32, label: String, leftover: Data = Data()) {
    let c = CameraChannel(fd: fd, label: label), id = ObjectIdentifier(c)
    lock.lock(); channels[id] = c; lock.unlock()
    c.send(CameraWire.status(["status": "idle"]))
    var line = Data(), buf = [UInt8](repeating: 0, count: 1024)
    func feed(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
      for byte in bytes {
        if byte == 0x0A {
          guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let type = o["type"] as? String, type == "start" || type == "stop" else {
            log("\(label): not a camera request, closing"); return false
          }
          want(c, type == "start")
          line.removeAll(keepingCapacity: true)
        } else if byte != 0x0D {
          guard line.count < 4096 else { return false }
          line.append(byte)
        }
      }
      return true
    }
    var going = leftover.withUnsafeBytes { feed($0.bindMemory(to: UInt8.self)) }
    while going {
      let n = Darwin.read(fd, &buf, buf.count)
      if n > 0 { going = buf.withUnsafeBufferPointer { feed(UnsafeBufferPointer(rebasing: $0[0..<n])) } }
      else if n < 0 && errno == EINTR { continue }
      else { going = false }
    }
    lock.lock()
    channels[id] = nil
    let wanted = wanting.remove(id) != nil, none = wanting.isEmpty
    lock.unlock()
    c.shutdown()
    Darwin.close(fd)
    if wanted && none { stopCapture() }
  }

  private func want(_ c: CameraChannel, _ on: Bool) {
    let id = ObjectIdentifier(c)
    lock.lock()
    let changed = on ? wanting.insert(id).inserted : wanting.remove(id) != nil
    let st = state, none = wanting.isEmpty, name = cameraName
    if changed && on && st == "idle" { state = "starting" }
    lock.unlock()
    guard changed else { return }
    if on {
      if st == "streaming" { c.send(streaming(name)) }
      else if st == "idle" { log("\(c.label) wants the camera"); startCapture() }   // starting: the status comes when it is up
    } else {
      c.send(CameraWire.status(["status": "idle"]))
      if none { stopCapture() }
    }
  }

  private func streaming(_ name: String) -> Data {
    CameraWire.status(["status": "streaming", "name": name, "width": CameraWire.width, "height": CameraWire.height,
                       "fps": CameraWire.fps, "pixelFormat": "NV12"])
  }

  private func startCapture() {   // state is "starting"
    capture.start { [self] result in
      lock.lock()
      if wanting.isEmpty {   // nobody left by the time it started
        state = "idle"; lock.unlock()
        capture.stop()
        return
      }
      let targets = wanting.compactMap { channels[$0] }
      switch result {
      case .success(let name):
        state = "streaming"; cameraName = name
        lastFrame = Date()
        let retrying = !problem.isEmpty   // "back" comes with the first frame
        lock.unlock()
        watch()
        if !retrying { log("on (\(name))") }
        targets.forEach { $0.send(streaming(name)) }
      case .failure(let e):
        state = "idle"
        let new = problem != e.message; problem = e.message
        retryLater()
        lock.unlock()
        if new { log("unavailable: \(e.message) (trying again while a VM wants it)") }
        targets.forEach { $0.send(CameraWire.status(["status": "unavailable", "reason": e.reason])) }
      }
    }
  }

  private func stopCapture() {
    lock.lock(); let was = state; state = "idle"; retryDelay = firstRetry; problem = ""; lock.unlock()
    guard was != "idle" else { return }
    capture.stop()
    log("off (no VM reads it)")
  }

  private func failed(_ message: String) {
    lock.lock()
    let was = state
    guard was == "streaming" else { lock.unlock(); return }
    state = "idle"
    let targets = wanting.compactMap { channels[$0] }
    let new = problem != message; problem = message
    retryLater()
    lock.unlock()
    capture.stop()
    if new { log("stopped: \(message) (trying again while a VM wants it)") }
    targets.forEach { $0.send(CameraWire.status(["status": "unavailable", "reason": "capture"])) }
  }

  /// Streaming: once a second, whether frames still come.
  private func watch() {
    let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    let every = min(1.0, frameTimeout / 3)
    t.schedule(deadline: .now() + every, repeating: every)
    t.setEventHandler { [weak self, weak t] in
      guard let self else { t?.cancel(); return }
      self.lock.lock()
      let streaming = self.state == "streaming", quiet = -self.lastFrame.timeIntervalSinceNow, name = self.cameraName
      self.lock.unlock()
      if !streaming { t?.cancel(); return }
      if quiet > self.frameTimeout { self.failed("no picture from \(name) for \(Int(self.frameTimeout.rounded())) s") }
    }
    lock.lock(); watchdog?.cancel(); watchdog = t; lock.unlock()
    t.resume()
  }

  /// A camera was connected: while VMs want one and none runs, try at once.
  private func retryNow() {
    lock.lock()
    let go = state == "idle" && !wanting.isEmpty
    if go { state = "starting"; retryDelay = firstRetry }
    lock.unlock()
    if go { log("a camera was connected: trying again"); startCapture() }
  }

  /// The camera failed while VMs still want it (another app took it, the
  /// permission is not given yet, the lid closed, it was unplugged): tries
  /// again after 2 s, then up to every 30 s, with the camera picked then,
  /// until it works or no VM wants it. The VMs show black meanwhile and get
  /// "streaming" when it is back. Lock held.
  private func retryLater() {
    let delay = retryDelay
    retryDelay = min(retryDelay * 2, 30)
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
      lock.lock()
      let go = state == "idle" && !wanting.isEmpty
      if go { state = "starting" }
      lock.unlock()
      if go { startCapture() }
    }
  }

  private func frame(_ payload: Data) {
    lock.lock()
    guard state == "streaming" else { lock.unlock(); return }
    lastFrame = Date()
    if retryDelay != firstRetry || !problem.isEmpty {   // it works again
      if !problem.isEmpty { log("back: \(cameraName)") }
      retryDelay = firstRetry; problem = ""
    }
    sequence &+= 1
    let seq = sequence, targets = wanting.compactMap { channels[$0] }
    lock.unlock()
    guard !targets.isEmpty else { return }
    let m = CameraWire.message(kind: 2, sequence: seq, payload: payload)
    targets.forEach { $0.send(m, frame: true) }
  }
}
