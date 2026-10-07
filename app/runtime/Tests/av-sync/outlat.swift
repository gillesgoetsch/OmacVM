// outlat: the output latency CoreAudio reports for the default output device (what a native player adds to
// its A/V sync and what QEMU's sound path never tells the VM). Read only.
import CoreAudio
import Foundation
func get<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ v: inout T) -> OSStatus {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
}
var dev = AudioObjectID(0)
_ = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, &dev)
var name: CFString = "" as CFString
_ = get(dev, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &name)
let out = kAudioDevicePropertyScopeOutput
var rate = Float64(0), lat = UInt32(0), safety = UInt32(0), bufsz = UInt32(0), transport = UInt32(0)
_ = get(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate)
_ = get(dev, kAudioDevicePropertyLatency, out, &lat)
_ = get(dev, kAudioDevicePropertySafetyOffset, out, &safety)
_ = get(dev, kAudioDevicePropertyBufferFrameSize, out, &bufsz)
_ = get(dev, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)
var streamsSize = UInt32(0)
var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: out, mElement: kAudioObjectPropertyElementMain)
AudioObjectGetPropertyDataSize(dev, &sa, 0, nil, &streamsSize)
var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / 4)
AudioObjectGetPropertyData(dev, &sa, 0, nil, &streamsSize, &streams)
var slat = UInt32(0)
if let s = streams.first { _ = get(s, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, &slat) }
let tt = String(bytes: withUnsafeBytes(of: transport.bigEndian) { Array($0) }, encoding: .ascii) ?? "?"
let total = Double(lat + safety + slat + bufsz) / rate * 1000
print(String(format: "device '%@' transport %@ rate %.0f: latency %u + safety %u + stream %u + buffer %u frames = %.1f ms",
             name as String, tt, rate, lat, safety, slat, bufsz, total))
