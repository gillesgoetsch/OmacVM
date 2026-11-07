// Prints NotchArea's answer for every case, for src/tests/notch-setting.sh:
// "MODE READY FULL NOTCH|RECORD" (NOTCH: notch, remembered or none, MacNotch's
// word), then "key UUID KEY" (NotchHousing.macKey) and "remembered STORED|0|1"
// for the stored values the script names on its command line.
import Foundation

let air = NotchGeometry(left: 640.5, right: 829.5, strip: 37, width: 1470, height: 956)
for mode in NotchMode.allCases {
    for ready in [true, false] {
        for full in [true, false] {
            for notch in [MacNotch.now(air), .remembered(air), .none] {
                let s = NotchArea.start(mode: mode, fullScreen: full, notch: notch, guestReady: ready)
                print("\(mode.rawValue) \(ready ? 1 : 0) \(full ? 1 : 0) \(notch.word)|\(s.record)")
            }
        }
    }
}
let args = Array(CommandLine.arguments.dropFirst())
if let uuid = args.first {
    let key = NotchHousing.macKey(hardwareID: uuid)
    print("key \(uuid) \(key)")
    for stored in args.dropFirst() {
        let v = stored.replacingOccurrences(of: "KEY", with: key)
        print("remembered \(stored)|\(NotchHousing.remembered(v, mac: key) == nil ? 0 : 1)")
    }
}
