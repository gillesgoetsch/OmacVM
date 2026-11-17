// Print "hw" if this Mac's media engine decodes AV1 (M3 and newer), else "no".
// Asked at run time, the same call virgl's VideoToolbox decoder makes
// (app/runtime/patches/virgl-videotoolbox-decode.patch): Prefer VP9 on
// YouTube (feature youtube-vp9, tag no-av1 in src/features.tsv) is offered
// only where AV1 would be decoded on the CPU.
import VideoToolbox
print(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) ? "hw" : "no")
