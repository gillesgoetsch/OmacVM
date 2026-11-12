import Foundation
import OmacVMFeatures

/// #350: the hidden shareKeyboard setting -> QEMU's OMACVM_KEYS_LAST. The
/// values go into a throwaway domain's registration defaults (memory only):
/// nothing is written, never the app's own domain.
func shareKeyboardTests() {
    guard let d = UserDefaults(suiteName: "org.omacvm.test.share-keyboard.app.\(getpid())") else {
        expect(false, "share keyboard: a throwaway defaults domain")
        return
    }
    var env = ["HOME": "/Users/a"]
    expect(!ShareKeyboard.isOn(d), "share keyboard: off when not set")
    ShareKeyboard.apply(ShareKeyboard.isOn(d), to: &env)
    expect(env["OMACVM_KEYS_LAST"] == nil && env["HOME"] == "/Users/a", "share keyboard off: no OMACVM_KEYS_LAST for QEMU")
    d.register(defaults: ["shareKeyboard": true])
    ShareKeyboard.apply(ShareKeyboard.isOn(d), to: &env)
    expect(env["OMACVM_KEYS_LAST"] == "1", "share keyboard on (defaults write ... -bool true): OMACVM_KEYS_LAST=1")
    d.register(defaults: ["shareKeyboard": false])
    env["OMACVM_KEYS_LAST"] = "1"   // the app itself started with it
    ShareKeyboard.apply(ShareKeyboard.isOn(d), to: &env)
    expect(env["OMACVM_KEYS_LAST"] == nil, "share keyboard off again: not passed on from the app's own environment")
    expect(ShareKeyboard.key == "shareKeyboard" && ShareKeyboard.variable == "OMACVM_KEYS_LAST",
           "share keyboard: the key the helpers read, the variable QEMU's patch reads")
}

/// #784: an Apple ISO keyboard -> QEMU's TRYOMARCHY_KEYBOARD=iso (its swap patch's switch).
func isoKeyboardTests() {
    var env = ["HOME": "/Users/a"]
    ISOKeyboard.apply(true, to: &env)
    expect(env["TRYOMARCHY_KEYBOARD"] == "iso" && env["HOME"] == "/Users/a", "ISO keyboard: TRYOMARCHY_KEYBOARD=iso for QEMU")
    ISOKeyboard.apply(false, to: &env)
    expect(env["TRYOMARCHY_KEYBOARD"] == nil, "ANSI or JIS keyboard: none, also not passed on from the app's own environment")
    expect(ISOKeyboard.variable == "TRYOMARCHY_KEYBOARD", "ISO keyboard: the variable qemu-cocoa-iso-section-grave-swap.patch reads")
    let patch = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../runtime/patches/qemu-cocoa-iso-section-grave-swap.patch").standardized
    let text = (try? String(contentsOf: patch, encoding: .utf8)) ?? ""
    expect(text.contains("getenv(\"TRYOMARCHY_KEYBOARD\")") && text.contains("strcmp(geometry, \"iso\")"),
           "ISO keyboard: the patch swaps on exactly that variable and value (\(patch.lastPathComponent))")
    print("info ISO keyboard on this Mac: \(ISOKeyboard.isISO)")
}
