// avcap: records the Mac's screen and the Mac's sound output together with
// ScreenCaptureKit (one clock for both) and writes what an A/V sync check
// needs: per video frame the mean brightness of the centre of the screen,
// per millisecond of sound the loudest sample.
// Usage: avcap SECONDS OUT.csv [displayID] (default: the main display)
// Lines: V,<pts s>,<luma 0-255>   A,<pts s>,<peak 0-1>   I,<key>,<value>
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3, let secs = Double(args[1]) else {
    FileHandle.standardError.write("usage: avcap SECONDS OUT.csv [display-index]\n".data(using: .utf8)!)
    exit(2)
}
let outPath = args[2]
let displayArg = args.count > 3 ? UInt32(args[3]) : nil
FileManager.default.createFile(atPath: outPath, contents: nil)
let out = FileHandle(forWritingAtPath: outPath)!
let lock = NSLock()
var buf = ""
func emit(_ s: String) {
    lock.lock(); buf += s + "\n"
    if buf.utf8.count > 65536 { out.write(buf.data(using: .utf8)!); buf = "" }
    lock.unlock()
}
func flush() { lock.lock(); out.write(buf.data(using: .utf8)!); buf = ""; lock.unlock() }

final class Sink: NSObject, SCStreamOutput, SCStreamDelegate {
    var frames = 0, idle = 0, audioBufs = 0
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        emit("I,error,\(error.localizedDescription)"); flush(); exit(1)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        switch type {
        case .screen:
            if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let raw = atts.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete {
                idle += 1; return
            }
            guard let px = CMSampleBufferGetImageBuffer(sb) else { return }
            CVPixelBufferLockBaseAddress(px, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
            let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
            let bpr = CVPixelBufferGetBytesPerRow(px)
            guard let base = CVPixelBufferGetBaseAddress(px)?.assumingMemoryBound(to: UInt8.self) else { return }
            var sum = 0, n = 0
            // centre half of the screen, BGRA
            for y in stride(from: h / 4, to: 3 * h / 4, by: 2) {
                let row = base + y * bpr
                for x in stride(from: w / 4, to: 3 * w / 4, by: 2) {
                    let p = row + x * 4
                    sum += (Int(p[0]) + 2 * Int(p[1]) + Int(p[2])) / 4; n += 1
                }
            }
            frames += 1
            emit(String(format: "V,%.6f,%.1f", pts, Double(sum) / Double(max(n, 1))))
        case .audio:
            audioBufs += 1
            guard let fd = CMSampleBufferGetFormatDescription(sb),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return }
            let rate = asbd.mSampleRate
            var need = 0
            _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &need,
                bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                flags: 0, blockBufferOut: nil)
            let raw = UnsafeMutableRawPointer.allocate(byteCount: max(need, MemoryLayout<AudioBufferList>.size), alignment: 16)
            defer { raw.deallocate() }
            let ablp = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
            var block: CMBlockBuffer?
            let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil,
                bufferListOut: ablp, bufferListSize: max(need, MemoryLayout<AudioBufferList>.size), blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
            let list = UnsafeMutableAudioBufferListPointer(ablp)
            guard st == noErr, list.count > 0, let data = list[0].mData else {
                if audioBufs == 1 { emit("I,audio_error,\(st) need \(need)") }
                return
            }
            if audioBufs == 1 { emit("I,audio_format,\(rate) Hz, \(list.count) buffers, flags \(asbd.mFormatFlags), bits \(asbd.mBitsPerChannel), ch/frame \(asbd.mChannelsPerFrame)") }
            // first channel only; interleaved data is stepped by its channel count
            let stepCh = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ? 1 : Int(max(1, asbd.mChannelsPerFrame))
            let count = Int(list[0].mDataByteSize) / 4 / stepCh
            let f = data.assumingMemoryBound(to: Float.self)
            let blk = max(1, Int(rate / 1000))
            var i = 0
            while i < count {
                var peak: Float = 0
                for j in i..<min(i + blk, count) { peak = max(peak, abs(f[j * stepCh])) }
                emit(String(format: "A,%.6f,%.5f", pts + Double(i) / rate, peak))
                i += blk
            }
        default: break
        }
    }
}

let sink = Sink()
let q = DispatchQueue(label: "avcap", qos: .userInteractive)
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        for x in content.displays { emit("I,display_seen,\(x.displayID) \(x.width)x\(x.height)") }
        let want = displayArg ?? CGMainDisplayID()
        guard let d = content.displays.first(where: { $0.displayID == want }) else { emit("I,error,no display \(want)"); flush(); exit(1) }
        let filter = SCContentFilter(display: d, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = 256; cfg.height = 144
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 8
        cfg.showsCursor = false
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true
        emit("I,display,\(d.displayID) \(d.width)x\(d.height)")
        emit("I,start_uptime,\(ProcessInfo.processInfo.systemUptime)")
        let stream = SCStream(filter: filter, configuration: cfg, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: q)
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: q)
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
        try await stream.stopCapture()
        emit("I,frames,\(sink.frames)"); emit("I,idle,\(sink.idle)"); emit("I,audio_buffers,\(sink.audioBufs)")
        flush(); exit(0)
    } catch {
        emit("I,error,\(error)"); flush(); exit(1)
    }
}
dispatchMain()
