// The sound delay the app tells a VM (OmacVMAudio), without a VM:
//   cd app/app && swift run audio-tests
// Exit 0 when all pass. CI runs it on every pull request.
import Foundation
import OmacVMAudio

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}
func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.05 } ?? false }

// AirPods Pro as outlat read them on the MacBook Pro (2026-10-06); a wired
// display's speakers with the same 12.8 ms total as the Mac mini's LG.
let airpods = AudioDelay.Device(latency: 7680, safetyOffset: 0, streamLatency: 0, bufferFrames: 512, sampleRate: 48000)
let lg = AudioDelay.Device(latency: 0, safetyOffset: 102, streamLatency: 0, bufferFrames: 512, sampleRate: 48000)
expect(near(airpods.ms, 170.7), "AirPods Pro: 7680 + 512 frames at 48 kHz = 170.7 ms")
expect(near(lg.ms, 12.8), "wired: 102 + 512 frames at 48 kHz = 12.8 ms")

// Totals: QEMU's part plus the device.
expect(AudioDelay.total(deviceMs: airpods.ms) == AudioDelay.qemuMs + 171, "AirPods: QEMU + 171 ms")
expect(AudioDelay.total(deviceMs: lg.ms) == AudioDelay.qemuMs + 13, "wired: QEMU + 13 ms")
expect(AudioDelay.total(deviceMs: nil) == AudioDelay.qemuMs, "unknown device: QEMU's part alone")

// The user's correction, and the limits.
expect(AudioDelay.total(deviceMs: 10, extraMs: -40) == AudioDelay.qemuMs - 30, "a negative correction")
expect(AudioDelay.total(deviceMs: nil, extraMs: -5000) == 0, "never below 0")
expect(AudioDelay.total(deviceMs: 900, extraMs: 900) == 1000, "never above 1 s")

// What CoreAudio can get wrong.
expect(AudioDelay.Device(latency: 100, safetyOffset: 0, streamLatency: 0, bufferFrames: 512, sampleRate: 0).ms == nil, "no rate: unknown")
expect(AudioDelay.Device(latency: UInt32.max, safetyOffset: UInt32.max, streamLatency: 0, bufferFrames: 0, sampleRate: 48000).ms == nil,
       "over 1 s: unknown (no overflow)")

// Every measured run in lip-sync tolerance with QEMU's part: the sound at
// most 15 ms early and 45 ms late.
for d in AudioDelay.measuredQemuMs {
    let off = d - Double(AudioDelay.qemuMs)
    expect(off >= -15 && off <= 45, "measured \(Int(d)) ms: sound \(Int(off)) ms after the picture")
}

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
