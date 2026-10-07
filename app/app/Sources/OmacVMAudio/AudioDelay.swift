import Foundation

/// How late the Mac plays a VM's sound after the VM's sound card took it
/// (av-sync, 3.0.2).
///
/// Players in the VM (Chromium, Firefox, mpv) hold the picture back by the
/// sound delay PipeWire reports. That covers the VM's own buffers only. After
/// the card's DMA position come QEMU's buffers and the Mac's output device,
/// and nothing told the VM about them: the sound came late against the
/// picture (110-150 ms with wired sound, about 170 ms more with AirPods).
/// The app now tells the VM this delay (AudioLatencyWatch in the app,
/// omacvm-audio-latency in the VM: PipeWire's latency offset on the card's
/// output port), at the start and whenever the Mac's output changes.
public enum AudioDelay {
    /// QEMU's part in ms, from the guest's DMA position to macOS's mixer: the
    /// HDA codec's buffer, QEMU's ring (out.buffer-count=8 x 512 frames at
    /// 44.1 kHz) and SDL's AudioQueue. Its fill moves from run to run: the
    /// Mac mini measured 106-151 ms (median 136) with a flash-and-beep clip in
    /// Chromium, H.264 and VP9, hardware and software decode, OpenGL and
    /// Vulkan, 3.0.0 and audioClassic (app/runtime/Tests/av-sync,
    /// measured). 115 puts every one of those runs within lip-sync tolerance
    /// (sound at most 15 ms early, 45 ms late): -9 ... +36 ms.
    public static let qemuMs = 115

    /// The QEMU delays measured on the Mac mini (2026-10-06, ms after the
    /// picture without the fix, minus the device), for the tests.
    public static let measuredQemuMs: [Double] = [106, 112, 114, 125, 126, 136, 138, 143, 145, 147, 151]

    /// What CoreAudio says about the Mac's output device, in frames.
    public struct Device: Equatable, Sendable {
        public var latency: UInt32
        public var safetyOffset: UInt32
        public var streamLatency: UInt32
        public var bufferFrames: UInt32
        public var sampleRate: Double

        public init(latency: UInt32, safetyOffset: UInt32, streamLatency: UInt32,
                    bufferFrames: UInt32, sampleRate: Double) {
            self.latency = latency
            self.safetyOffset = safetyOffset
            self.streamLatency = streamLatency
            self.bufferFrames = bufferFrames
            self.sampleRate = sampleRate
        }

        /// The device's delay in ms (what a Mac app adds to its own A/V
        /// sync): nil when CoreAudio gave no usable rate or a value that
        /// cannot be right (over 1 s).
        public var ms: Double? {
            guard sampleRate >= 8000, sampleRate <= 768_000 else { return nil }
            let frames = Double(latency) + Double(safetyOffset) + Double(streamLatency) + Double(bufferFrames)
            let ms = frames / sampleRate * 1000
            return ms <= 1000 ? ms : nil
        }
    }

    /// The delay the VM is told, in whole ms: QEMU's part, the device's
    /// (none when unknown) and the user's correction (audioDelayExtraMs),
    /// kept within 0 ... 1000 ms.
    public static func total(deviceMs: Double?, extraMs: Int = 0) -> Int {
        let ms = Double(qemuMs) + (deviceMs ?? 0) + Double(extraMs)
        return Int(min(max(ms, 0), 1000).rounded())
    }
}
