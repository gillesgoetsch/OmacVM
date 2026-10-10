// Prints NotchArea's answer for every case, for src/tests/notch-setting.sh:
// "MODE READY FULL NOTCH|RECORD" (NOTCH: notch or none).
import Foundation

let air = NotchGeometry(left: 640.5, right: 829.5, strip: 37, width: 1470, height: 956)
for mode in NotchMode.allCases {
    for ready in [true, false] {
        for full in [true, false] {
            for notch in [true, false] {
                let s = NotchArea.start(mode: mode, fullScreen: full, notch: notch ? air : nil, guestReady: ready)
                print("\(mode.rawValue) \(ready ? 1 : 0) \(full ? 1 : 0) \(notch ? "notch" : "none")|\(s.record)")
            }
        }
    }
}
